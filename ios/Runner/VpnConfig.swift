//
//  VpnConfig.swift
//  VOIDCORE VPN
//
//  Shared model that travels between the Flutter app (Runner) and the Packet
//  Tunnel Extension through the shared App Group container. Both targets link
//  this file so the wire format stays in sync without a duplicate definition.
//

import Foundation

/// Mirror of the arguments `MainActivity.kt` accepts on the Android side. The
/// Flutter `VpnChannel.start` call JSON-encodes these into a single blob that
/// the extension reads from the shared App Group container at start time.
struct VpnConfig: Codable {
    /// Xray JSON configuration document. Required.
    var config: String
    /// Human-friendly connection name shown in the system VPN status UI.
    var remark: String
    /// "off" | "whitelist" | "blacklist". iOS only supports "off" for the system
    /// tunnel; per-app routing is honored inside the extension by matching the
    /// tunneled process against `apps` when `perAppMode != "off"`.
    var perAppMode: String
    /// List of bundle identifiers included/excluded by `perAppMode`.
    var apps: [String]
    /// Tunnel MTU. Must fit within NEPacketTunnelNetworkSettings limits.
    var mtu: Int
    /// When true the local HTTP proxy is announced to the system via
    /// NEPacketTunnelNetworkSettings.proxySettings. Used by the WARP/MASQUE
    /// chain to feed an explicit HTTP proxy.
    var appendHttpProxy: Bool
    /// "proxyOnly": route only the addresses named in the Xray config, leaving
    /// the default route alone. The extension flips includeAllNetworks accordingly.
    var proxyOnly: Bool
    /// Optional exit node ("psiphon" / "tor"). iOS does not bundle the Psiphon
    /// or Tor binaries; when set, the extension reports an unsupported error.
    var exit: String?
    /// True when the exit connects by itself (not via Xray's psiphon-in/tor-in).
    var exitDirect: Bool
    /// The exit's preferred region label.
    var exitRegion: String
    /// Tor bridge type ("direct" / "obfs4" / "snowflake" / "custom").
    var torBridge: String?
    /// Custom Tor bridge lines, one per entry.
    var torCustomBridges: [String]
    /// Psiphon config document (JSON) the app generated.
    var psiphonConfig: String?
    /// Reserved for the Xray browser dialer; iOS does not implement this.
    var browserDialer: Bool
    /// When true the extension performs an HTTP 204 probe through the tunnel
    /// before reporting the "connected" state, mirroring Android's behavior.
    var verifyConnection: Bool

    init(
        config: String,
        remark: String = "VOIDCORE",
        perAppMode: String = "off",
        apps: [String] = [],
        mtu: Int = 1500,
        appendHttpProxy: Bool = false,
        proxyOnly: Bool = false,
        exit: String? = nil,
        exitDirect: Bool = false,
        exitRegion: String = "",
        torBridge: String? = nil,
        torCustomBridges: [String] = [],
        psiphonConfig: String? = nil,
        browserDialer: Bool = false,
        verifyConnection: Bool = false
    ) {
        self.config = config
        self.remark = remark
        self.perAppMode = perAppMode
        self.apps = apps
        self.mtu = mtu
        self.appendHttpProxy = appendHttpProxy
        self.proxyOnly = proxyOnly
        self.exit = exit
        self.exitDirect = exitDirect
        self.exitRegion = exitRegion
        self.torBridge = torBridge
        self.torCustomBridges = torCustomBridges
        self.psiphonConfig = psiphonConfig
        self.browserDialer = browserDialer
        self.verifyConnection = verifyConnection
    }
}

/// Connection state as the extension reports it back to the Flutter UI.
/// Matches the Android `CoreManager.State` names the Dart side already parses.
enum VpnStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// Snapshot pushed from the extension to the Runner through the shared
/// `state.json` file. The Runner polls it (a file-watching GCD source would
/// also work) and republishes each change on the `bpb/state` EventChannel.
struct VpnStateEvent: Codable {
    var state: VpnStatus
    var error: String?
    /// Milliseconds since epoch, 0 when not connected.
    var connectedAt: Int64
    /// Optional human-readable detail (Tor bootstrap %, reconnecting…).
    var detail: String?

    init(state: VpnStatus, error: String? = nil, connectedAt: Int64 = 0, detail: String? = nil) {
        self.state = state
        self.error = error
        self.connectedAt = connectedAt
        self.detail = detail
    }
}
