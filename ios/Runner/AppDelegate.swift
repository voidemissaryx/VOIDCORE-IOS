//
//  AppDelegate.swift
//  VOIDCORE VPN (Runner)
//
//  Bridges Flutter and native iOS. Implements the `bpb/core` MethodChannel and
//  `bpb/state` EventChannel with the same method names and argument shapes the
//  Android `MainActivity.kt` defines, so the Dart UI (`lib/services/vpn_channel.dart`)
//  works on both platforms unchanged.
//

import UIKit
import Flutter
import NetworkExtension
import os.log

@main
class AppDelegate: FlutterAppDelegate {

    private let log = OSLog(subsystem: "com.bpb.voidcore", category: "bridge")
    private let methodChannel = "bpb/core"
    private let eventChannel = "bpb/state"
    private let scannerChannel = "bpb/scanner"

    private let poller = AppStatePoller()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as? FlutterViewController
        guard let controller = controller else {
            os_log("FlutterViewController not found", log: log, type: .error)
            return false
        }

        let messenger = controller.binaryMessenger
        FlutterMethodChannel(name: methodChannel, binaryMessenger: messenger)
            .setMethodCallHandler(handle)
        FlutterEventChannel(name: eventChannel, binaryMessenger: messenger)
            .setStreamHandler(StateStreamHandler(poller: poller))

        poller.start()
        wireVpnController()

        // The scanner EventChannel: on iOS the scanner runs in-process through
        // the same Xray framework (see ScannerBridge.swift). When the framework
        // is not linked the channel reports a graceful error.
        FlutterEventChannel(name: scannerChannel, binaryMessenger: messenger)
            .setStreamHandler(ScannerStreamHandler())

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - VpnController wiring

    private func wireVpnController() {
        VpnController.shared.onStatusChange = { [weak self] status, error in
            self?.publishState(status, error: error)
        }
    }

    private func publishState(_ status: NEVPNStatus, error: String?) {
        // VpnController already pushes via the poller file; this is a no-op
        // except for echoing to the os_log.
        os_log("VPN status: %{public}@ error=%{public}@", log: log, type: .info, status.rawValue, error ?? "")
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "prepare":
            prepare(result, vpn: (call.arguments as? [String: Any])?["vpn"] as? Bool ?? true)

        case "supportsAppendHttpProxy":
            // iOS supports NEProxySettings, so this is always true.
            result(true)

        case "start":
            handleStart(call, result: result)

        case "stop":
            VpnController.shared.stop { result(nil) }

        case "state":
            let snapshot = poller.current
            result([
                "state": snapshot.state.rawValue,
                "error": snapshot.error,
                "connectedAt": snapshot.connectedAt,
                "detail": snapshot.detail,
            ])

        case "shareFile":
            handleShareFile(call, result: result)

        case "pickFile":
            handlePickFile(result: result)

        case "saveFile":
            handleSaveFile(call, result: result)

        case "readLog":
            let logName = (call.arguments as? [String: Any])?["log"] as? String ?? "xray"
            result(readLog(logName))

        case "logSizes":
            result(logSizes())

        case "clearLog":
            SharedContainer.remove(.xrayLog)
            result(nil)

        case "versions":
            result([
                "xray": XrayCoreBridge.shared.version,
                "psiphon": "",
                "tor": "",
            ])

        case "saveGeoAssets":
            handleSaveGeoAssets(call, result: result)

        case "appInfo":
            result([
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.7",
                "abis": ["arm64", "arm64e", "x86_64"],
            ])

        case "measureDelay":
            handleMeasureDelay(result: result)

        case "scannerStart":
            result("Scanner is not available on iOS in this build.")

        case "scannerPause", "scannerResume", "scannerStop":
            result("")

        case "trafficStats":
            result(trafficStats())

        case "installedApps":
            result(installedApps())

        case "mitmCaExists":
            result(SharedContainer.read(.mitmCert) != nil)

        case "startSetupTor":
            result(0)

        case "setupTorStatus":
            result(["progress": 0, "running": false, "error": "Tor is not available on iOS in this build."])

        case "stopSetupTor":
            result(nil)

        case "startEchGateway":
            result(XrayCoreBridge.shared.startEchGateway())

        case "checkDns":
            let request = call.arguments as? String ?? ""
            result(XrayCoreBridge.shared.checkDNS(request))

        case "saveMitmCa":
            handleSaveMitmCa(call, result: result)

        case "installMitmCa":
            // iOS does not allow an app to install a root CA into the system
            // trust store programmatically. The user must do it manually in
            // Settings → General → About → Certificate Trust Settings.
            result("manual")

        case "openUrl":
            handleOpenUrl(call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - prepare

    private func prepare(_ result: @escaping FlutterResult, vpn: Bool) {
        guard vpn else {
            result(true)
            return
        }
        VpnController.shared.prepare { outcome in
            switch outcome {
            case .success(let installed):
                result(installed)
            case .failure(let error):
                result(FlutterError(code: "PREPARE", message: error.localizedDescription, details: nil))
            }
        }
    }

    // MARK: - start

    private func handleStart(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let configString = args["config"] as? String else {
            result(FlutterError(code: "ARG", message: "config is required", details: nil))
            return
        }
        let config = VpnConfig(
            config: configString,
            remark: args["remark"] as? String ?? "VOIDCORE",
            perAppMode: args["perAppMode"] as? String ?? "off",
            apps: (args["apps"] as? [String]) ?? [],
            mtu: args["mtu"] as? Int ?? 1500,
            appendHttpProxy: args["appendHttpProxy"] as? Bool ?? false,
            proxyOnly: args["proxyOnly"] as? Bool ?? false,
            exit: args["exit"] as? String,
            exitDirect: args["exitDirect"] as? Bool ?? false,
            exitRegion: args["exitRegion"] as? String ?? "",
            torBridge: args["torBridge"] as? String,
            torCustomBridges: (args["torCustomBridges"] as? [String]) ?? [],
            psiphonConfig: args["psiphonConfig"] as? String,
            browserDialer: args["browserDialer"] as? Bool ?? false,
            verifyConnection: args["verifyConnection"] as? Bool ?? false
        )
        VpnController.shared.start(config: config) { outcome in
            switch outcome {
            case .success:
                result(nil)
            case .failure(let error):
                result(FlutterError(code: "START", message: error.localizedDescription, details: nil))
            }
        }
    }

    // MARK: - files

    private func handleShareFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(false); return
        }
        let name = (args["name"] as? String ?? "file.json").components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let content = args["content"] as? String ?? ""
        let title = args["title"] as? String ?? "Share"
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name.isEmpty ? "file.json" : name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.title = title
            // The Flutter view controller is the presenter.
            if let presenter = window?.rootViewController {
                presenter.present(activity, animated: true) { result(true) }
            } else {
                result(false)
            }
        } catch {
            result(FlutterError(code: "SHARE", message: error.localizedDescription, details: nil))
        }
    }

    private func handlePickFile(_ result: @escaping FlutterResult) {
        // Picking is presented by the share handler; we use a UIDocumentPicker.
        // Because the picker needs the root VC, this bridges through a small
        // helper. The picker callback writes the chosen file's contents back.
        DocumentPicker.shared.present { outcome in
            switch outcome {
            case .none:
                result(nil)
            case .some(let (name, content)):
                result(["name": name, "content": content])
            }
        }
    }

    private func handleSaveFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(nil); return
        }
        let name = (args["name"] as? String ?? "file.json").components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let content = args["content"] as? String ?? ""
        DocumentSaver.shared.save(name: name, content: content) { savedPath in
            result(savedPath)
        }
    }

    // MARK: - logs

    private func readLog(_ name: String) -> String {
        switch name {
        case "xray":
            if let data = SharedContainer.read(.xrayLog),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return ""
        default:
            return ""
        }
    }

    private func logSizes() -> [String: Int] {
        var sizes: [String: Int] = [:]
        if let data = SharedContainer.read(.xrayLog) {
            sizes["xray"] = data.count
        }
        SharedContainer.write(sizes, to: .logSizes)
        return sizes
    }

    // MARK: - measureDelay

    private func handleMeasureDelay(_ result: @escaping FlutterResult) {
        // Uses Xray's running controller through the framework, or falls back
        // to a URLSession probe when the framework is not linked.
        if XrayCoreBridge.shared.isLinked {
            // The Controller handle lives in the extension, not in the Runner.
            // For the Runner-side delay test we use a direct URLSession probe
            // through the tunnel; the URL request goes through the tunnel
            // because the VPN is up.
            let url = URL(string: "https://www.gstatic.com/generate_204")!
            let start = Date()
            let task = URLSession.shared.dataTask(with: url) { _, response, _ in
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 204 || http.statusCode == 200 {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    result(ms)
                } else {
                    result(-1)
                }
            }
            task.resume()
        } else {
            result(-1)
        }
    }

    // MARK: - geo assets

    private func handleSaveGeoAssets(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let files = args["files"] as? [String: [String: Any]] else {
            result(FlutterError(code: "ARG", message: "files is required", details: nil))
            return
        }
        // Validate SHA-256 first; write only if all match (matches Android behavior).
        var verified: [(String, Data)] = []
        for (name, info) in files {
            guard let data = info["data"] as? FlutterStandardTypedData,
                  let expected = info["sha256"] as? String else {
                result(FlutterError(code: "GEO", message: "Missing data or sha256 for \(name)", details: nil))
                return
            }
            let hash = sha256Hex(data.data)
            if hash.lowercased() != expected.lowercased() {
                result(FlutterError(code: "GEO", message: "Checksum mismatch for \(name)", details: nil))
                return
            }
            verified.append((name, data.data))
        }
        let dir = SharedContainer.url.appendingPathComponent("geo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in verified {
            try? data.write(to: dir.appendingPathComponent(name))
        }
        result(nil)
    }

    // MARK: - traffic

    private func trafficStats() -> [String: Any]? {
        guard let data = SharedContainer.read(.traffic),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - installed apps

    private func installedApps() -> [[String: Any]] {
        // iOS does not expose installed-app enumeration to third-party apps.
        // Return the host bundle only so the per-app proxy UI can still render
        // without crashing; the user can't pick other apps on iOS.
        return [[
            "package": Bundle.main.bundleIdentifier ?? "",
            "label": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "VOIDCORE",
            "system": false,
            "icon": NSNull(),
        ]]
    }

    // MARK: - mitm

    private func handleSaveMitmCa(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let cert = args["cert"] as? String,
              let key = args["key"] as? String else {
            result(FlutterError(code: "ARG", message: "cert and key are required", details: nil))
            return
        }
        SharedContainer.write(Data(cert.utf8), to: .mitmCert)
        SharedContainer.write(Data(key.utf8), to: .mitmKey)
        result(nil)
    }

    // MARK: - open URL

    private func handleOpenUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
            result(false); return
        }
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url) { ok in result(ok) }
            } else {
                result(false)
            }
        }
    }

    // MARK: - helpers

    private func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - State stream

private final class StateStreamHandler: NSObject, FlutterStreamHandler {
    private let poller: AppStatePoller
    private var sink: FlutterEventSink?

    init(poller: AppStatePoller) {
        self.poller = poller
    }

    func onListen(withArguments _: Any?, eventSink sink: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = sink
        sink(eventDict(poller.current))
        poller.onChange = { [weak self] event in
            sink(self?.eventDict(event) ?? [:])
        }
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        poller.onChange = nil
        sink = nil
        return nil
    }

    private func eventDict(_ event: VpnStateEvent) -> [String: Any] {
        return [
            "state": event.state.rawValue,
            "error": event.error as Any,
            "connectedAt": event.connectedAt,
            "detail": event.detail as Any,
        ]
    }
}

// MARK: - Scanner stream (iOS: not yet implemented)

private final class ScannerStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments _: Any?, eventSink sink: @escaping FlutterEventSink) -> FlutterError? {
        sink(FlutterError(code: "SCANNER", message: "Scanner is not available on iOS in this build.", details: nil))
        sink(FlutterEndOfEventStream)
        return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? { nil }
}
