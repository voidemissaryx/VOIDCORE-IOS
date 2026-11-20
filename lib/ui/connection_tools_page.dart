import 'package:flutter/material.dart';

import '../services/xray_config.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';

class ConnectionToolsPage extends StatefulWidget {
  const ConnectionToolsPage({super.key});

  @override
  State<ConnectionToolsPage> createState() => _ConnectionToolsPageState();
}

class _ConnectionToolsPageState extends State<ConnectionToolsPage> {
  AppState? _state;
  final List<({ConnectionMode mode, int latency})> _results = [];
  bool _testing = false;
  bool _cancel = false;
  String _progress = 'Ready';
  ConnectionMode? _testingMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context);
    if (_state != next) {
      _state?.removeListener(_onStateChanged);
      _state = next;
      _state!.addListener(_onStateChanged);
    }
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<bool> _waitUntilSettled({Duration timeout = const Duration(seconds: 28)}) async {
    final state = _state!;
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      if (_cancel) return false;
      if (state.isConnected) return true;
      if (state.status == VpnStatus.disconnected) return false;
      await Future.delayed(const Duration(milliseconds: 350));
    }
    return false;
  }

  Future<void> _disconnectAndWait() async {
    final state = _state!;
    if (state.status != VpnStatus.disconnected) {
      await state.disconnect();
      final until = DateTime.now().add(const Duration(seconds: 8));
      while (state.status != VpnStatus.disconnected && DateTime.now().isBefore(until)) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
      if (state.status != VpnStatus.disconnected) {
        throw StateError('The previous connection did not stop cleanly.');
      }
    }
  }

  Future<void> _smartConnect() async {
    final state = _state!;
    if (_testing || state.isBusy) return;
    final originalMode = state.mode;
    final wasConnected = state.isConnected;
    setState(() {
      _testing = true;
      _cancel = false;
      _results.clear();
      _progress = 'Preparing connection tests…';
    });
    try {
      await _disconnectAndWait();
      final candidates = List<ConnectionMode>.of(state.availableModes);
      for (final mode in candidates) {
        if (_cancel) break;
        setState(() {
          _testingMode = mode;
          _progress = 'Testing ${mode.label}…';
        });
        state.setMode(mode);
        await state.connect();
        final connected = await _waitUntilSettled();
        if (connected) {
          // Allow the tunnel to stabilize before measuring in-tunnel latency.
          await Future.delayed(const Duration(seconds: 2));
          var latency = -1;
          try {
            latency = await VpnChannel.measureDelay();
          } catch (_) {
            // A candidate without a valid in-tunnel latency is not ranked.
          }
          if (latency >= 0) {
            setState(() => _results.add((mode: mode, latency: latency)));
          }
        }
        await _disconnectAndWait();
      }

      if (_cancel) {
        state.setMode(originalMode);
        if (wasConnected) await state.connect();
        setState(() => _progress = 'Test cancelled');
        return;
      }
      if (_results.isEmpty) {
        state.setMode(originalMode);
        if (wasConnected) await state.connect();
        setState(() => _progress = 'No connection passed the latency test');
        return;
      }
      _results.sort((a, b) => a.latency.compareTo(b.latency));
      final best = _results.first;
      state.setMode(best.mode);
      setState(() => _progress = 'Best measured latency: ${best.mode.label} · ${best.latency} ms');
      await state.connect();
    } catch (e) {
      state.setMode(originalMode);
      if (wasConnected && state.status == VpnStatus.disconnected) {
        await state.connect();
      }
      setState(() => _progress = 'Smart Connect failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _testingMode = null;
        });
      }
    }
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear connection history?'),
        content: const Text('This removes the locally saved connection history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      _state?.clearConnectionHistory();
    }
  }

  @override
  void dispose() {
    _state?.removeListener(_onStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state ?? AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Connection & History')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('Smart Connect', style: theme.textTheme.titleLarge),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tests connection methods already available in this installation and selects the one with the lowest successful in-tunnel latency. Each candidate is connected and disconnected during the test.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  if (_testing) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(_progress),
                    if (_testingMode != null) Text('Current: ${_testingMode!.label}'),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () {
                          _cancel = true;
                          _progress = 'Cancelling after current test…';
                          setState(() {});
                        },
                        icon: const Icon(Icons.cancel),
                        label: const Text('Cancel'),
                      ),
                    ),
                  ] else ...[
                    Text(_progress, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: state.isBusy ? null : _smartConnect,
                        icon: const Icon(Icons.bolt),
                        label: const Text('Find best connection'),
                      ),
                    ),
                  ],
                  if (_results.isNotEmpty) ...[
                    const Divider(height: 24),
                    Text('Measured results', style: theme.textTheme.titleMedium),
                    for (final result in _results)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          result == _results.first ? Icons.check_circle : Icons.network_ping,
                          color: result == _results.first ? theme.colorScheme.primary : null,
                        ),
                        title: Text(result.mode.label),
                        trailing: Text('${result.latency} ms'),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Connection history', style: theme.textTheme.titleLarge)),
                      IconButton(
                        tooltip: 'Clear history',
                        onPressed: state.connectionHistory.isEmpty ? null : _clearHistory,
                        icon: const Icon(Icons.delete_sweep),
                      ),
                    ],
                  ),
                  if (state.connectionHistory.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('No saved connection sessions yet.'),
                    )
                  else
                    for (final item in state.connectionHistory)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(item['success'] == true ? Icons.check_circle : Icons.error),
                        title: Text('${item['mode'] ?? 'Connection'}'),
                        subtitle: Text(
                          item['success'] == true
                              ? '${item['time'] ?? ''} · ${item['duration'] ?? 0}s'
                              : '${item['time'] ?? ''} · ${item['failure'] ?? 'Connection failed'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(item['latency'] == null ? '—' : '${item['latency']} ms'),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Latency is used as the ranking signal; this test does not claim to measure maximum download throughput. Connection history stores session metadata only, not configuration secrets.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
