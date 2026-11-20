//
//  XrayCoreBridge.swift
//  VOIDCORE VPN
//
//  Typed bridge to the gomobile-generated Xray.xcframework. The iOS build
//  workflow builds the framework before compiling Runner and PacketTunnel.
//

import Foundation
#if canImport(Xray)
import Xray
#endif

final class XrayCoreBridge {
    static let shared = XrayCoreBridge()
    private init() {}

    let isLinked: Bool = XrayCoreProbe.isFrameworkLinked()

    func initEnv(assetDir: String) {
        #if canImport(Xray)
        XrayInitEnv(assetDir)
        #endif
    }

    var version: String {
        #if canImport(Xray)
        return XrayVersion()
        #else
        return ""
        #endif
    }

    func startEchGateway() -> String {
        #if canImport(Xray)
        return XrayStartEchGateway()
        #else
        return XrayError.notLinked.localizedDescription
        #endif
    }

    func checkDNS(_ requestJSON: String) -> String {
        #if canImport(Xray)
        return XrayCheckDNSJSON(requestJSON)
        #else
        return "{\"ok\":false}"
        #endif
    }
}

/// Owns a gomobile-generated Xray Controller in the PacketTunnel process.
final class XrayRuntimeController {
    #if canImport(Xray)
    private var handle: XrayController?
    #endif

    init() {
        #if canImport(Xray)
        handle = XrayNewController()
        #endif
    }

    deinit {
        try? stop()
    }

    var isRunning: Bool {
        #if canImport(Xray)
        return handle?.isRunning() ?? false
        #else
        return false
        #endif
    }

    func start(config: String, tunFd: Int32) throws {
        #if canImport(Xray)
        guard let handle = handle else { throw XrayError.notLinked }
        try handle.start(config, tunFd: tunFd)
        #else
        throw XrayError.notLinked
        #endif
    }

    func stop() throws {
        #if canImport(Xray)
        guard let handle = handle else { return }
        try handle.stop()
        #endif
    }

    func outboundTraffic() -> String {
        #if canImport(Xray)
        return handle?.outboundTraffic() ?? ""
        #else
        return ""
        #endif
    }

    func measureDelay(url: String) -> Int64 {
        #if canImport(Xray)
        guard let handle = handle else { return -1 }
        return (try? handle.measureDelay(url)) ?? -1
        #else
        return -1
        #endif
    }
}

enum XrayError: LocalizedError {
    case notLinked

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "The Xray-core framework is not linked into this build. Run scripts/build_xray_ios.sh on a Mac and rebuild."
        }
    }
}
