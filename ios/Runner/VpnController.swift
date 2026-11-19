//
//  VpnController.swift
//  VOIDCORE VPN (Runner)
//
//  Owns the NETunnelProviderManager that installs the VPN configuration into
//  the system and starts/stops the Packet Tunnel Extension. Mirrors the role
//  Android's `CoreManager` + `BpbVpnService` companion object play.
//

import Foundation
import NetworkExtension
import os.log

final class VpnController {

    static let shared = VpnController()

    // MARK: - Types

    enum VpnError: LocalizedError {
        case managerLoadFailed(Error)
        case managerSaveFailed(Error)
        case notInstalled
        case startFailed(Error)

        var errorDescription: String? {
            switch self {
            case .managerLoadFailed(let e): return "Could not load VPN configuration: \(e.localizedDescription)"
            case .managerSaveFailed(let e): return "Could not save VPN configuration: \(e.localizedDescription)"
            case .notInstalled: return "The VPN configuration was not installed. Grant VPN permission in Settings."
            case .startFailed(let e): return "Could not start the VPN: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - State

    private let log = OSLog(subsystem: "com.bpb.voidcore", category: "controller")
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private(set) var lastStatus: NEVPNStatus = .invalid
    private(set) var lastError: String?

    /// Called on the main thread whenever the system reports a status change.
    var onStatusChange: ((NEVPNStatus, String?) -> Void)?

    private init() {
        observeStatus()
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Observation

    private func observeStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard
                let connection = notification.object as? NETunnelProviderSession,
                let session = self?.manager?.connection as? NETunnelProviderSession,
                connection === session
            else { return }
            self?.lastStatus = session.status
            self?.onStatusChange?(session.status, self?.lastError)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadManager { _ in }
        }
    }

    // MARK: - Prepare / install

    /// Loads the existing NETunnelProviderManager (creating one if needed) and
    /// installs the VPN configuration so the system can start the tunnel. The
    /// user is prompted for VPN permission the first time this is called.
    /// `completion(true)` when the configuration is installed and ready.
    func prepare(completion: @escaping (Result<Bool, Error>) -> Void) {
        reloadManager { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(VpnError.managerLoadFailed(error)))
            case .success:
                self?.installIfMissing(completion: completion)
            }
        }
    }

    private func reloadManager(_ completion: @escaping (Result<Void, Error>) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            self?.manager = manager
            completion(.success(()))
        }
    }

    private func installIfMissing(completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let manager = manager else {
            completion(.failure(VpnError.notInstalled))
            return
        }
        // Install a tunnel config if one isn't already there. The provider
        // identifier matches the PacketTunnel extension's bundle id.
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Bundle.main.object(forInfoDictionaryKey: "PACKET_TUNNEL_IDENTIFIER") as? String
            ?? "com.bpb.voidcore.PacketTunnel"
        proto.serverAddress = "VOIDCORE"
        proto.disconnectOnSleep = false
        proto.providerConfiguration = [
            "appGroup": SharedContainer.groupIdentifier,
        ]

        let needsInstall: Bool
        if let existing = manager.protocolConfiguration as? NETunnelProviderProtocol,
           existing.providerBundleIdentifier == proto.providerBundleIdentifier {
            needsInstall = false
        } else {
            manager.protocolConfiguration = proto
            manager.localizedDescription = "VOIDCORE VPN"
            manager.isEnabled = true
            needsInstall = true
        }

        if needsInstall {
            manager.saveToPreferences { [weak self] saveError in
                if let saveError = saveError {
                    completion(.failure(VpnError.managerSaveFailed(saveError)))
                    return
                }
                // Load again so the manager has its assigned uuid.
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        completion(.failure(VpnError.managerLoadFailed(loadError)))
                        return
                    }
                    self?.manager = manager
                    completion(.success(true))
                }
            }
        } else {
            completion(.success(true))
        }
    }

    // MARK: - Start / Stop

    /// Writes `config` to the shared container so the extension picks it up at
    /// start, then starts the tunnel.
    func start(config: VpnConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        SharedContainer.write(config, to: .pendingConfig)
        prepare { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self?.startSession(completion: completion)
            }
        }
    }

    private func startSession(completion: @escaping (Result<Void, Error>) -> Void) {
        guard
            let manager = manager,
            let session = manager.connection as? NETunnelProviderSession
        else {
            completion(.failure(VpnError.notInstalled))
            return
        }
        do {
            try session.startTunnel(options: nil)
            completion(.success(()))
        } catch {
            completion(.failure(VpnError.startFailed(error)))
        }
    }

    /// Stops the running tunnel, if any.
    func stop(completion: @escaping () -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion()
            return
        }
        session.stopTunnel()
        completion()
    }

    // MARK: - Status

    /// Current status translated to the Dart-side enum name.
    var dartStatus: String {
        switch lastStatus {
        case .connected: return "connected"
        case .connecting, .reasserting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected, .invalid: return "disconnected"
        @unknown default: return "disconnected"
        }
    }
}
