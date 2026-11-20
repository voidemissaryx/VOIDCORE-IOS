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
import Darwin

final class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Constants

    private static let tunIPv4 = "10.10.14.1"
    private static let tunIPv6 = "fd66:b9b:10:14::1"
    private static let tunDNS = "10.10.14.2"
    /// The local SOCKS/HTTP proxy port Xray listens on for proxy-only mode.
    private static let localProxyPort: UInt16 = 10808

    // MARK: - State

    private let log = OSLog(subsystem: "com.bpb.voidcore", category: "tunnel")
    private let controller = XrayRuntimeController()
    private var packetSocketFD: Int32 = -1
    private var packetReadSource: DispatchSourceRead?
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
            proxy.httpServer = NEProxyServer(address: "127.0.0.1", port: Int(PacketTunnelProvider.localProxyPort))
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
        guard !controller.isRunning else {
            completionHandler(nil)
            return
        }
        guard XrayCoreBridge.shared.isLinked else {
            let error = XrayError.notLinked
            publishState(.disconnected, error: error.localizedDescription, detail: nil)
            completionHandler(error)
            return
        }

        XrayCoreBridge.shared.initEnv(assetDir: SharedContainer.url.path)

        do {
            if config.proxyOnly {
                // Proxy-only mode has no TUN inbound. The Go bridge leaves
                // xray.tun.fd unset when tunFd is zero.
                try controller.start(config: config.config, tunFd: 0)
            } else {
                // NetworkExtension owns the utun and exposes packetFlow rather
                // than its fd. A datagram socketpair preserves packet boundaries
                // and the 4-byte utun family header expected by Xray on Darwin.
                var descriptors: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
                    let code = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                        NSLocalizedDescriptionKey: "Could not create the iOS packet bridge: \(String(cString: strerror(code)))"
                    ])
                }

                var socketBuffer: Int32 = 1_048_576
                for fd in descriptors {
                    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &socketBuffer, socklen_t(MemoryLayout<Int32>.size))
                    _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &socketBuffer, socklen_t(MemoryLayout<Int32>.size))
                }

                let flags = fcntl(descriptors[0], F_GETFL, 0)
                if flags < 0 || fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) < 0 {
                    let code = errno
                    Darwin.close(descriptors[0])
                    Darwin.close(descriptors[1])
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                        NSLocalizedDescriptionKey: "Could not configure the iOS packet bridge: \(String(cString: strerror(code)))"
                    ])
                }

                do {
                    // Xray's Darwin TUN duplicates descriptors[1] before use.
                    try controller.start(config: config.config, tunFd: descriptors[1])
                    Darwin.close(descriptors[1])
                    packetSocketFD = descriptors[0]
                    startPacketPump()
                } catch {
                    Darwin.close(descriptors[0])
                    Darwin.close(descriptors[1])
                    throw error
                }
            }
        } catch {
            os_log("Xray start failed: %{public}@", log: log, type: .error, error.localizedDescription)
            publishState(.disconnected, error: error.localizedDescription, detail: nil)
            completionHandler(error)
            return
        }

        if config.verifyConnection {
            verifyConnection { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.publishState(.connected, error: nil, detail: nil)
                    self.startTrafficTimer()
                    completionHandler(nil)
                } else {
                    let message = "Connection verification failed: the tunnel came up but the HTTP probe timed out."
                    self.publishState(.disconnected, error: message, detail: nil)
                    self.stopXray()
                    completionHandler(NSError(domain: "VoidCore", code: 4, userInfo: [NSLocalizedDescriptionKey: message]))
                }
            }
        } else {
            publishState(.connected, error: nil, detail: nil)
            startTrafficTimer()
            completionHandler(nil)
        }
    }

    private func stopXray() {
        trafficTimer?.cancel()
        trafficTimer = nil

        if let source = packetReadSource {
            packetReadSource = nil
            packetSocketFD = -1
            source.cancel()
        } else if packetSocketFD >= 0 {
            Darwin.close(packetSocketFD)
            packetSocketFD = -1
        }

        do {
            try controller.stop()
        } catch {
            os_log("Xray stop error: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Packet pump

    /// Bridges NetworkExtension's packetFlow to Xray's Darwin TUN socket.
    private func startPacketPump() {
        guard packetSocketFD >= 0 else { return }
        let fd = packetSocketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workQueue)
        source.setEventHandler { [weak self] in
            guard let self = self, !self.stopRequested else { return }
            self.drainXrayPackets(from: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        packetReadSource = source
        source.resume()
        readPacketFlow()
    }

    /// Reads framed packets from Xray. Darwin's utun header is four bytes,
    /// with the address family in the final byte.
    private func drainXrayPackets(from fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_540)
        while !stopRequested {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return recv(fd, base, rawBuffer.count, 0)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                os_log("Packet bridge read failed: %{public}d", log: log, type: .error, errno)
                return
            }
            if count == 0 { return }
            guard count > 4 else { continue }
            let family = Int32(buffer[3])
            guard family == AF_INET || family == AF_INET6 else { continue }
            let packet = Data(buffer[4..<count])
            if !packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)]) {
                os_log("NetworkExtension rejected an Xray packet", log: log, type: .error)
            }
        }
    }

    /// Reads the next batch from NetworkExtension and forwards each packet to
    /// Xray with the Darwin utun address-family header.
    private func readPacketFlow() {
        guard !stopRequested, packetSocketFD >= 0 else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            self.workQueue.async {
                guard !self.stopRequested, self.packetSocketFD >= 0 else { return }
                let fd = self.packetSocketFD
                for (index, packet) in packets.enumerated() {
                    guard let first = packet.first else { continue }
                    let version = first >> 4
                    let requested = index < protocols.count ? protocols[index].int32Value : 0
                    let family: Int32
                    if requested == AF_INET6 || version == 6 {
                        family = AF_INET6
                    } else if requested == AF_INET || version == 4 {
                        family = AF_INET
                    } else {
                        continue
                    }

                    var frame = Data([0, 0, 0, UInt8(family)])
                    frame.append(packet)
                    let sent = frame.withUnsafeBytes { rawBuffer -> Int in
                        guard let base = rawBuffer.baseAddress else { return -1 }
                        return send(fd, base, rawBuffer.count, 0)
                    }
                    if sent != frame.count {
                        let code = errno
                        os_log("Packet bridge write failed: %{public}@", log: self.log, type: .error,
                               String(cString: strerror(code)))
                    }
                }
                self.readPacketFlow()
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
