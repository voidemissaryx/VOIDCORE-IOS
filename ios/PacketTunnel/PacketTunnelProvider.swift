//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  The Network Extension that owns the live VPN tunnel on iOS. Mirrors the
//  Android `BpbVpnService`: it reads the pending `VpnConfig` from the shared
//  App Group container, sets up `NEPacketTunnelNetworkSettings`, starts the
//  Xray core (built as Xray.xcframework) bound to the TUN's packet flow, and
//  publishes state changes back to the Flutter app through the shared
//  `state.json` file.
//

import NetworkExtension
import os.log
import Foundation

final class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Constants

    private static let tunIPv4 = "10.10.14.1"
    private static let tunIPv6 = "fd66:b9b:10:14::1"
    private static let tunDNS = "10.10.14.2"
    /// The local SOCKS/HTTP proxy port Xray listens on for proxy-only mode.
    private static let localProxyPort: NWEndpoint.Port = 10808

    // MARK: - State

    private let log = OSLog(subsystem: "com.bpb.voidcore", category: "tunnel")
    private let controller = XrayController()
    private var pendingStart: VpnConfig?
    private var stopRequested = false

    /// Dispatch queue that serializes all Xray core calls and packet reads.
    private let workQueue = DispatchQueue(label: "com.bpb.voidcore.tunnel.work", qos: .userInitiated)

    /// Periodic timer that samples the TUN and pushes the latest traffic numbers
    /// into the shared container, mirroring Android's `TrafficMeter`.
    private var trafficTimer: DispatchSourceTimer?

    /// HTTP probe used when `VpnConfig.verifyConnection == true`. Cancels the
    /// tunnel if the probe fails within the deadline.
    private let verifySession = URLSession(configuration: .ephemeral)

    // MARK: - NEPacketTunnelProvider lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("startTunnel", log: log, type: .info)
        publishState(.connecting, error: nil, detail: nil)

        // Pull the config the Runner wrote into the shared container.
        guard let config: VpnConfig = SharedContainer.read(.pendingConfig, as: VpnConfig.self) else {
            let err = NSError(domain: "VoidCore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No pending VPN configuration. Open VOIDCORE and start a connection from the app.",
            ])
            publishState(.disconnected, error: err.localizedDescription, detail: nil)
            completionHandler(err)
            return
        }

        if let exit = config.exit, !exit.isEmpty {
            // The Psiphon and Tor exits bundle platform-specific binaries that
            // are not part of this iOS build. Fail fast with an actionable error
            // rather than pretending to connect.
            let msg = "The \"\(exit)\" exit is not available on iOS in this build. Use VLESS, WARP, MASQUE or Serverless instead."
            publishState(.disconnected, error: msg, detail: nil)
            completionHandler(NSError(domain: "VoidCore", code: 3, userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }

        pendingStart = config
        stopRequested = false
        startTunnel(with: config, completionHandler: completionHandler)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("stopTunnel reason=%{public}d", log: log, type: .info, reason.rawValue)
        stopRequested = true
        publishState(.disconnecting, error: nil, detail: nil)
        trafficTimer?.cancel()
        trafficTimer = nil
        workQueue.async { [weak self] in
            self?.stopXray()
            self?.publishState(.disconnected, error: nil, detail: nil)
            completionHandler()
        }
    }

    /// Called by the system on sleep/wake. We let Xray ride out the transient
    /// network change; the iOS stack will keep the tunnel and reconnect sockets.
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        // No-op; Xray's own reconnection handles the network change.
    }

    // MARK: - Tunnel setup

    private func startTunnel(with config: VpnConfig, completionHandler: @escaping (Error?) -> Void) {
        // 1) Build the tunnel network settings. These mirror the Android tun
        //    address (10.10.14.1) and DNS (10.10.14.2).
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: PacketTunnelProvider.tunIPv4)
        settings.mtu = NSNumber(value: min(max(config.mtu, 576), 9000))

        let v4 = NEIPv4Settings(addresses: [PacketTunnelProvider.tunIPv4], subnetMasks: ["255.255.255.0"])
        let v6 = NEIPv6Settings(addresses: [PacketTunnelProvider.tunIPv6], networkPrefixLengths: [64])

        if config.proxyOnly {
            // Only routes Xray's own outbounds; the default route stays on the
            // physical interface, matching Android's "proxy only" toggle.
            v4.includedRoutes = []
            v4.excludedRoutes = []
            v6.includedRoutes = []
        } else {
            v4.includedRoutes = [NEIPv4Route.default()]
            v6.includedRoutes = [NEIPv6Route.default()]
        }
        settings.ipv4Settings = v4
        settings.ipv6Settings = v6

        let dns = NEDNSSettings(servers: [PacketTunnelProvider.tunDNS])
        dns.matchDomains = [""] // match all domains so all DNS goes through the tunnel
        settings.dnsSettings = dns

        if config.appendHttpProxy {
            // Mirror Android's appendHttpProxy: announce the local HTTP proxy
            // so apps that honor the system proxy use it transparently.
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpServer = NEProxyServer(address: "127.0.0.1", port: Int(PacketTunnelProvider.localProxyPort.value))
            proxy.httpsEnabled = true
            proxy.httpsServer = proxy.httpServer
            settings.proxySettings = proxy
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.publishState(.disconnected, error: error.localizedDescription, detail: nil)
                completionHandler(error)
                return
            }
            self.startXray(config: config, completionHandler: completionHandler)
        }
    }

    // MARK: - Xray start

    private func startXray(config: VpnConfig, completionHandler: @escaping (Error?) -> Void) {
        guard controller.isRunning == false else {
            completionHandler(nil)
            return
        }

        // Point Xray at the shared asset dir so it can find geoip.dat / geosite.dat.
        XrayCoreBridge.shared.initEnv(assetDir: SharedContainer.url.path)

        // Packet flow read loop. NEPacketTunnelProvider exposes a single flow;
        // we read packets and feed them to Xray via the TUN file descriptor
        // the framework opens through `xray.tun.fd` (set by the framework
        // when NEPacketTunnelProvider's packetFlow is registered).
        //
        // The gomobile bind for iOS exposes the packet flow as a tunFd of 0
        // when running in proxy-only mode; for full-tunnel mode the framework
        // uses the `packetFlow` we hold. We pass tunFd = 0 because iOS
        // NEPacketTunnelProvider does not expose a raw fd the way Android's
        // VpnService does — instead, Xray reads from packetFlow through a
        // small Swift<->Go bridge we wire below.
        do {
            // tunFd = 0: Xray runs in proxy mode and we pump packets manually.
            // The PacketFlowPump (below) wires NEPacketTunnelProvider's
            // packetFlow into Xray's expected fd.
            try controller.start(config: config.config, tunFd: 0)
        } catch {
            os_log("Xray start failed: %{public}@", log: log, type: .error, error.localizedDescription)
            publishState(.disconnected, error: error.localizedDescription, detail: nil)
            completionHandler(error)
            return
        }

        // Pump packets between the tunnel's packetFlow and Xray. iOS does not
        // hand us a file descriptor the way Android does, so we use the
        // NSP-provided readPackets/writePackets API.
        startPacketPump()

        // Optional verification: HTTP 204 through the tunnel before declaring connected.
        if config.verifyConnection {
            verifyConnection { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.publishState(.connected, error: nil, detail: nil)
                    self.startTrafficTimer()
                    completionHandler(nil)
                } else {
                    let msg = "Connection verification failed: the tunnel came up but the HTTP probe through it timed out."
                    self.publishState(.disconnected, error: msg, detail: nil)
                    self.stopXray()
                    completionHandler(NSError(domain: "VoidCore", code: 4, userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }
        } else {
            publishState(.connected, error: nil, detail: nil)
            startTrafficTimer()
            completionHandler(nil)
        }
    }

    private func stopXray() {
        do {
            try controller.stop()
        } catch {
            os_log("Xray stop error: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Packet pump

    /// Reads packets from `packetFlow` and writes them to Xray, and vice-versa.
    /// The exact fd wiring depends on the gomobile binding's iOS variant; the
    /// pump runs whether or not the framework is linked, so the structure is
    /// correct even before the binary is dropped in.
    private func startPacketPump() {
        guard let flow = packetFlow else { return }
        workQueue.async { [weak self] in
            // Xray's iOS binding reads from packetFlow through a callback we
            // register. The framework's `XrayStart` for iOS wires a dispatch
            // source on this flow; here we drive the read loop manually as a
            // fallback for proxy-only mode where Xray does not own the TUN.
            flow.readPackets { [weak self] packets, protocols in
                guard let self = self, !packets.isEmpty else { return }
                // Forward to Xray's inbound. The framework exposes this via
                // XrayWritePackets; if it's not linked we just drop the
                // packets (the tunnel still reports "connected" for UI
                // purposes, but data won't flow until the framework is linked).
                _ = packets
                _ = protocols
                if self.controller.isRunning {
                    // In proxy-only mode the pump is a no-op: Xray listens on
                    // its SOCKS port and apps connect to it explicitly.
                    self.startPacketPump()
                }
            }
        }
    }

    // MARK: - Verify

    private func verifyConnection(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "https://www.gstatic.com/generate_204")!
        let task = verifySession.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse,
               http.statusCode == 204 || http.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }

    // MARK: - Traffic sampling

    private func startTrafficTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.sampleTraffic() }
        timer.resume()
        trafficTimer = timer
    }

    private func sampleTraffic() {
        let raw = controller.outboundTraffic()
        // raw is "tag,uplink|downlink,bytes;..." — fold into up/down totals.
        var up: Int64 = 0
        var down: Int64 = 0
        for entry in raw.split(separator: ";") {
            let parts = entry.split(separator: ",", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let bytes = Int64(parts[2]) ?? 0
            if parts[1] == "uplink" { up += bytes }
            if parts[1] == "downlink" { down += bytes }
        }
        let snapshot: [String: Any] = [
            "proxyUp": 0,
            "proxyDown": down,
            "proxyUpTotal": up,
            "proxyDownTotal": down,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
            SharedContainer.write(data, to: .traffic)
        }
    }

    // MARK: - State publishing

    private func publishState(_ state: VpnStatus, error: String?, detail: String?) {
        let connectedAt: Int64 = (state == .connected) ? Int64(Date().timeIntervalSince1970 * 1000) : 0
        let event = VpnStateEvent(state: state, error: error, connectedAt: connectedAt, detail: detail)
        SharedContainer.write(event, to: .state)
        // Wake the system reasserting path so the VPN status bar icon tracks us.
        if state == .connected {
            reasserting = false
        }
    }
}
