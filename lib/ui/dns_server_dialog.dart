import 'package:flutter/material.dart';

import '../models/settings.dart';
import 'prefs.dart';
import 'theme.dart';

/// Dialog to add a custom DNS server with name, server address, and optional bootstrap IPs.
class AddDnsServerDialog extends StatefulWidget {
  const AddDnsServerDialog({super.key});

  @override
  State<AddDnsServerDialog> createState() => _AddDnsServerDialogState();
}

class _AddDnsServerDialogState extends State<AddDnsServerDialog> {
  final _nameController = TextEditingController();
  final _serverController = TextEditingController();
  final _bootstrapController = TextEditingController();
  String? _nameError;
  String? _serverError;
  String? _bootstrapError;

  @override
  void dispose() {
    _nameController.dispose();
    _serverController.dispose();
    _bootstrapController.dispose();
    super.dispose();
  }

  bool _validate() {
    final nameError = _nameController.text.trim().isEmpty
        ? 'Name is required'
        : null;
    final server = _serverController.text.trim();
    final serverError = server.isEmpty
        ? 'Server address is required'
        : validateCustomDnsAddress(server);
    String? bootstrapError;

    if (_bootstrapController.text.trim().isNotEmpty) {
      final bootstraps = _bootstrapController.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      for (final bootstrap in bootstraps) {
        if (!isIp(bootstrap)) {
          bootstrapError = 'Invalid IP address: $bootstrap';
          break;
        }
      }
    }

    setState(() {
      _nameError = nameError;
      _serverError = serverError;
      _bootstrapError = bootstrapError;
    });
    return nameError == null && serverError == null && bootstrapError == null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Custom Server'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. My DNS',
                errorText: _nameError,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kInputRadius),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _serverController,
              decoration: InputDecoration(
                labelText: 'Server',
                hintText: 'e.g., 8.8.8.8 or https://dns.google/dns-query',
                errorText: _serverError,
                helperText:
                    'IP (UDP), tcp://IP, https://host/path, or quic://host',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kInputRadius),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _bootstrapController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Bootstrap IPs (Optional)',
                hintText: '8.8.8.8\n8.8.4.4',
                errorText: _bootstrapError,
                helperText: 'One IP per line',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kInputRadius),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_validate()) {
              final bootstraps = _bootstrapController.text
                  .split('\n')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList();
              
              final server = CustomDnsServer(
                _nameController.text.trim(),
                _serverController.text.trim(),
                bootstraps,
              );
              
              Navigator.of(context).pop(server);
            }
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
