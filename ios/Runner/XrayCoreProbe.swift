//
//  XrayCoreProbe.swift
//  VOIDCORE VPN
//
//  Dynamic resolution layer for the Xray-core framework symbols.
//
//  The gomobile-built `Xray.xcframework` exposes a small set of C functions
//  (declared in `Xray.h`). Rather than hard-linking them — which would make
//  the Runner fail to build whenever the framework is missing during local
//  development — this file dlsym's each entry point at first use and returns
//  safe defaults when a symbol is absent.
//
//  When the framework IS linked, calls go straight through to the Go runtime.
//  When it is NOT linked, every method returns a sensible "unavailable" value
//  and `isFrameworkLinked()` returns false, so the rest of the app can degrade
//  gracefully (the tunnel provider will report an actionable error message
//  instead of crashing on a missing symbol).
//

import Foundation
import ObjectiveC
import os.log

/// Typealiases for the C entry points the framework exports. These match the
/// declarations in `Xray.h` produced by `gomobile bind -target=ios -prefix=Xray`.
private typealias XrayVersionFn = @convention(c) () -> UnsafePointer<CChar>?
private typealias XrayInitEnvFn = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias XrayStartEchGatewayFn = @convention(c) () -> UnsafePointer<CChar>?
private typealias XrayCheckDNSFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias XrayNewControllerFn = @convention(c) () -> OpaquePointer?
private typealias XrayStartFn = @convention(c) (OpaquePointer, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<NSError?>?) -> Void

private typealias XrayStopFn = @convention(c) (OpaquePointer, UnsafeMutablePointer<NSError?>?) -> Void
private typealias XrayIsRunningFn = @convention(c) (OpaquePointer) -> Bool
private typealias XrayOutboundTrafficFn = @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
private typealias XrayMeasureDelayFn = @convention(c) (UnsafePointer<CChar>?, OpaquePointer) -> Int64

enum XrayCoreProbe {
    private static let log = OSLog(subsystem: "com.bpb.voidcore", category: "xray-probe")
    private static let frameworkName = "Xray"

    /// Once-only handle for the loaded framework image, if any.
    private static let imageHandle: UnsafeMutableRawPointer? = {
        // gomobile produces a dylib named `Xray.framework/Xray`. dlopen loads
        // it lazily; if absent, we get nil and every method degrades.
        let candidates = [
            "@rpath/\(frameworkName).framework/\(frameworkName)",
            "/System/Library/Frameworks/\(frameworkName).framework/\(frameworkName)",
        ]
        for path in candidates {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                return handle
            }
        }
        return nil
    }()

    /// True when the Xray framework image was loaded successfully.
    static func isFrameworkLinked() -> Bool {
        return imageHandle != nil
    }

    // MARK: - Symbol resolution

    private static func resolve<T>(_ name: String) -> T? {
        guard let image = imageHandle else { return nil }
        guard let raw = dlsym(image, name) else {
            os_log("Missing Xray symbol: %{public}@", log: log, type: .error, name)
            return nil
        }
        return unsafeBitCast(raw, to: T.self)
    }

    private static func cString(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer = pointer else { return "" }
        return String(cString: pointer)
    }

    // MARK: - Public API

    static func version() -> String {
        guard let fn: XrayVersionFn = resolve("XrayVersion") else { return "" }
        return cString(fn())
    }

    static func initEnv(_ dir: String) {
        guard let fn: XrayInitEnvFn = resolve("XrayInitEnv") else { return }
        dir.withCString { fn($0) }
    }

    static func startEchGateway() -> String {
        guard let fn: XrayStartEchGatewayFn = resolve("XrayStartEchGateway") else {
            return "Xray framework is not linked into this build."
        }
        return cString(fn())
    }

    static func checkDNS(_ requestJSON: String) -> String {
        guard let fn: XrayCheckDNSFn = resolve("XrayCheckDNSJSON") else {
            return "{\"ok\":false}"
        }
        return cString(requestJSON.withCString { fn($0) })
    }

    static func newController() -> OpaquePointer? {
        guard let fn: XrayNewControllerFn = resolve("XrayNewController") else { return nil }
        return fn()
    }

    static func start(_ handle: OpaquePointer, config: String, tunFd: Int32, error: inout NSError?) {
        guard let fn: XrayStartFn = resolve("XrayStart") else {
            error = NSError(domain: "Xray", code: 1, userInfo: [NSLocalizedDescriptionKey: XrayError.notLinked.errorDescription ?? ""])
            return
        }
        config.withCString { cfgPtr in
            fn(handle, cfgPtr, tunFd, withUnsafeMutablePointer(to: &error) { $0 })
        }
    }

    static func stop(_ handle: OpaquePointer, error: inout NSError?) {
        guard let fn: XrayStopFn = resolve("XrayStop") else { return }
        fn(handle, withUnsafeMutablePointer(to: &error) { $0 })
    }

    static func isRunning(_ handle: OpaquePointer) -> Bool {
        guard let fn: XrayIsRunningFn = resolve("XrayIsRunning") else { return false }
        return fn(handle)
    }

    static func outboundTraffic(_ handle: OpaquePointer) -> String {
        guard let fn: XrayOutboundTrafficFn = resolve("XrayOutboundTraffic") else { return "" }
        return cString(fn(handle))
    }

    static func measureDelay(_ url: String, _ handle: OpaquePointer) -> Int64 {
        guard let fn: XrayMeasureDelayFn = resolve("XrayMeasureDelay") else { return -1 }
        return url.withCString { fn($0, handle) }
    }
}
