import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/app_state.dart';

class ConnectionHistoryPage extends StatelessWidget {
  const ConnectionHistoryPage({super.key});

  String _date(Object? value) {
    final parsed = DateTime.tryParse('$value')?.toLocal();
    if (parsed == null) return 'Unknown date';
    final two = (int n) => n.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)}  ${two(parsed.hour)}:${two(parsed.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final history = state.connectionHistory;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection history'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: history.isEmpty ? null : () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear connection history?'),
                  content: const Text('All saved connection history on this device will be deleted.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
                  ],
                ),
              );
              if (confirmed == true) await state.clearConnectionHistory();
            },
            icon: const Icon(Symbols.delete_sweep_rounded),
          ),
        ],
      ),
      body: history.isEmpty
          ? Center(child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Symbols.history_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('No connection history', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text('Your recent connection sessions will appear here.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: history.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = history[index];
                final success = entry['success'] == true;
                final color = success ? theme.colorScheme.primary : theme.colorScheme.error;
                final latency = entry['latencyMs'];
                final duration = (entry['durationSeconds'] as num?)?.toInt() ?? 0;
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withValues(alpha: .12),
                      child: Icon(success ? Symbols.check_rounded : Symbols.error_outline_rounded, color: color),
                    ),
                    title: Text('${entry['mode'] ?? 'Connection'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text([
                        _date(entry['startedAt']),
                        success ? 'Duration: ${duration}s' : (entry['reason'] ?? 'Connection failed').toString(),
                        if (latency is num) 'Latency: ${latency.toInt()} ms',
                      ].join(' · ')),
                    ),
                    trailing: Icon(success ? Symbols.check_circle_rounded : Symbols.cancel_rounded, color: color),
                  ),
                );
              },
            ),
    );
  }
}
