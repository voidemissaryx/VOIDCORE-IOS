//
//  XrayCoreBridge.swift
//  VOIDCORE VPN
//
//  Bridge to the Xray-core Go library built by `scripts/build_xray_ios.sh`
//  (gomobile bind -target=ios) and packaged as `Xray.xcframework`.
//
//  The framework exposes the same Go symbols the Android `xray.aar` does:
//    - XrayNewController() -> *Controller
//    - (*Controller) Start(config: String, tunFd: Int32) throws
//    - (*Controller) Stop() throws
//    - (*Controller) IsRunning() -> Bool
//    - (*Controller) MeasureDelay(url: String) -> Int64
//    - (*Controller) OutboundTraffic() -> String
//    - XrayVersion() -> String
//    - XrayInitEnv(dir: String)
//    - XrayStartEchGateway() -> String
//    - XrayCheckDNS(json: String) -> String
//    - XrayNewScannerBridge() -> *ScannerBridge
//
//  The bridging header (Xray.h) declares these as C functions wrapping the Go
//  objects; Swift imports them through the module map. When the framework is
//  not yet linked (e.g. local unsigned builds without the binary), every call
//  reports a `notLinked` error instead of crashing, so the rest of the app
//  still builds and runs for UI testing.
//

import Foundation
import os.log

/// Wraps the Xray-core native library. Thread-safe: every method takes the
/// same serial queue the Controller uses internally.
final class XrayCoreBridge {
    static let shared = XrayCoreBridge()

    private let queue = DispatchQueue(label: "com.bpb.voidcore.xray", qos: .userInitiated)
    private let log = OSLog(subsystem: "com.bpb.voidcore", category: "xray")

    /// Whether the `Xray.xcframework` was linked into this binary.
    /// Determined once at launch by probing the dyld image list.
    let isLinked: Bool = {
        // The framework's bundle identifier, when present, appears in the
        // loaded images. We check for the symbol exported by the module map.
        return XrayCoreProbe.isFrameworkLinked()
    }()

    private init() {}

    // MARK: - Environment

    /// Points Xray at `dir` for its geo files (geoip.dat, geosite.dat) and
    /// certificate lookups, mirroring `xray.InitEnv`.
    func initEnv(assetDir: String) {
        guard isLinked else {
            os_log("Xray framework not linked; skipping InitEnv", log: log, type: .error)
            return
        }
        queue.sync { XrayCoreProbe.initEnv(assetDir) }
    }

    /// Xray-core version string, or "unavailable" when the framework is missing.
    var version: String {
        guard isLinked else { return "" }
        return queue.sync { XrayCoreProbe.version() }
    }

    // MARK: - Controller

    /// Starts the local ECH gateway used for Cloudflare API calls when the
    /// direct path is blocked. Returns an error string, "" on success.
    func startEchGateway() -> String {
        guard isLinked else { return "Xray framework is not linked into this build." }
        return queue.sync { XrayCoreProbe.startEchGateway() }
    }

    /// Runs a DNS test through the Go networking module. `requestJSON` is the
    /// serialized `networking.DNSRequest`. Returns the JSON result.
    func checkDNS(_ requestJSON: String) -> String {
        guard isLinked else { return "{\"ok\":false}" }
        return queue.sync { XrayCoreProbe.checkDNS(requestJSON) }
    }

    /// Measures the GET latency through the running tunnel.
    /// Returns -1 when the framework is missing or the core is not running.
    func measureDelay(url: String, controller: OpaquePointer?) -> Int64 {
        guard isLinked, let controller = controller else { return -1 }
        return queue.sync { XrayCoreProbe.measureDelay(url, controller) }
    }
}

// MARK: - Controller handle

/// Lightweight wrapper around the Go `*Controller` pointer. The Go side is
/// reference-counted; this class owns one controller and stops it on deinit.
final class XrayController {
    private let bridge = XrayCoreBridge.shared
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.bpb.voidcore.controller")

    init() {
        if bridge.isLinked {
            handle = XrayCoreProbe.newController()
        }
    }

    deinit {
        try? stop()
    }

    var isRunning: Bool {
        guard let handle = handle else { return false }
        return queue.sync { XrayCoreProbe.isRunning(handle) }
    }

    /// Starts an instance from the JSON config, with the TUN device `tunFd`.
    /// `tunFd == 0` means proxy-only mode.
    func start(config: String, tunFd: Int32) throws {
        guard let handle = handle else {
            throw XrayError.notLinked
        }
        var error: NSError?
        queue.sync {
            XrayCoreProbe.start(handle, config: config, tunFd: tunFd, error: &error)
        }
        if let error = error { throw error }
    }

    func stop() throws {
        guard let handle = handle else { return }
        var error: NSError?
        queue.sync {
            XrayCoreProbe.stop(handle, error: &error)
        }
        if let error = error { throw error }
    }

    /// "tag,uplink|downlink,bytes;" for each counter above 0.
    func outboundTraffic() -> String {
        guard let handle = handle else { return "" }
        return queue.sync { XrayCoreProbe.outboundTraffic(handle) }
    }

    func measureDelay(url: String) -> Int64 {
        guard let handle = handle else { return -1 }
        return queue.sync { XrayCoreProbe.measureDelay(url, handle) }
    }
}

enum XrayError: LocalizedError {
    case notLinked

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "The Xray-core framework is not linked into this build. Run scripts/build_xray_ios.sh on a Mac and add Xray.xcframework to the project."
        }
    }
}
