//
//  SharedContainer.swift
//  VOIDCORE VPN
//
//  Thin wrapper around the App Group container that the Runner and the Packet
//  Tunnel Extension use to exchange the start configuration, the live state
//  snapshot, and the Xray log tail. Both targets link this file.
//

import Foundation

/// Shared files written to the App Group container.
enum SharedFile: String {
    /// The pending `VpnConfig` written by the Runner right before starting the tunnel.
    case pendingConfig = "pending_config.json"
    /// The latest `VpnStateEvent` written by the extension whenever the state changes.
    case state = "state.json"
    /// Xray core's log tail, truncated to ~256 KiB.
    case xrayLog = "xray.log"
    /// A JSON map of log file sizes ({"xray": 1234}) for the log page header.
    case logSizes = "log_sizes.json"
    /// The current traffic counters snapshot.
    case traffic = "traffic.json"
    /// The MITM CA certificate (PEM) when the user has imported one.
    case mitmCert = "mitm_ca.crt"
    /// The MITM CA private key (PEM).
    case mitmKey = "mitm_ca.key"
}

enum SharedContainer {
    /// The App Group identifier baked into both targets' entitlements.
    static let groupIdentifier: String = {
        // The build variable $(CUSTOM_APP_GROUP) is substituted into the
        // entitlements at link time. We don't have a direct runtime read of
        // the entitlement's value, so we use a fixed default that matches
        // ios/Flutter/Runner.xcconfig. Override by setting APP_GROUP_IDENTIFIER
        // in the main bundle's Info.plist before launch (the GitHub Actions
        // workflow does this through the xcconfig).
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String,
           !identifier.isEmpty,
           !identifier.contains("$(") {
            return identifier
        }
        return "group.com.bpb.voidcore"
    }()

    /// URL of the shared App Group container. Created on demand.
    static var url: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(groupIdentifier, isDirectory: true)
    }

    /// Returns the URL for one of the shared files, creating the parent directory if needed.
    static func url(for file: SharedFile) -> URL {
        let dir = url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(file.rawValue)
    }

    /// Atomically writes `data` to the shared file. Safe to call from any thread.
    static func write(_ data: Data, to file: SharedFile) {
        let target = url(for: file)
        let tmp = target.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data)
        _ = try? FileManager.default.replaceItemAt(target, withItemAt: tmp)
    }

    /// Reads the shared file as `Data`, or nil when missing/empty.
    static func read(_ file: SharedFile) -> Data? {
        let target = url(for: file)
        return FileManager.default.contents(atPath: target.path)
    }

    /// Reads and decodes a `Codable` value, or nil on any failure.
    static func read<T: Decodable>(_ file: SharedFile, as type: T.Type) -> T? {
        guard let data = read(file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Writes a `Codable` value as pretty-printed JSON.
    static func write<T: Encodable>(_ value: T, to file: SharedFile) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(data, to: file)
    }

    /// Deletes a shared file if present.
    static func remove(_ file: SharedFile) {
        try? FileManager.default.removeItem(at: url(for: file))
    }
}
