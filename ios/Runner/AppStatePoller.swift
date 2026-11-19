//
//  AppStatePoller.swift
//  VOIDCORE VPN (Runner)
//
//  Watches the shared `state.json` file the Packet Tunnel Extension writes
//  whenever the VPN status changes, and republishes each change on a callback.
//  Equivalent to Android's `CoreManager.Listener` mechanism.
//

import Foundation

final class AppStatePoller {

    /// Called on the main thread whenever the shared state changes.
    var onChange: ((VpnStateEvent) -> Void)?

    private var lastSnapshot: VpnStateEvent?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.bpb.voidcore.poller", qos: .utility)

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads the latest state file and notifies when it differs from the last snapshot.
    private func tick() {
        guard let event: VpnStateEvent = SharedContainer.read(.state, as: VpnStateEvent.self) else { return }
        guard event.state != lastSnapshot?.state
            || event.error != lastSnapshot?.error
            || event.detail != lastSnapshot?.detail
            || event.connectedAt != lastSnapshot?.connectedAt else { return }
        lastSnapshot = event
        DispatchQueue.main.async { [weak self] in self?.onChange?(event) }
    }

    /// Returns the current snapshot synchronously (for the initial EventChannel push).
    var current: VpnStateEvent {
        SharedContainer.read(.state, as: VpnStateEvent.self) ?? VpnStateEvent(state: .disconnected)
    }
}
