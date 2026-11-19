import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'dns_server_dialog.dart';
import 'prefs.dart';
import 'theme.dart';

/// DNS mode page: select and manage DNS servers by type (UDP, TCP, DoH, DoQ).
class DnsPage extends StatefulWidget {
  const DnsPage({super.key});

  @override
  State<DnsPage> createState() => _DnsPageState();
}

class _DnsPageState extends State<DnsPage> {
  List<Map<String, dynamic>> _dnsServers = [];
  late String _selectedType;
  late TextEditingController _testUrlController;
  late List<CustomDnsServer> _customServers;
  late List<SelectedDnsServer> _configuredServers;
  final Map<String, bool> _selectedServers = {};
  final Map<String, String?> _testResults = {};
  bool _isLoading = true;

  List<String> get _configuredAddresses =>
      _configuredServers.expand((server) => server.addresses).toList();

  @override
  void initState() {
    super.initState();
    _loadDnsServers();
    final state = AppScope.read(context);
    final dnsSettings = state.profile.serverless.dnsSettings;
    _selectedType = dnsSettings.dnsType;
    _testUrlController = TextEditingController(text: dnsSettings.testUrl);
    _customServers = List.from(dnsSettings.customServers);
    _configuredServers = List.from(dnsSettings.servers);
    final selectedCustomServers = _customServers
        .where(
          (server) =>
              _configuredAddresses.contains(server.server) ||
              _customServerAddresses(server).any(_configuredAddresses.contains),
        )
        .toList();
    final selectedCustomType = selectedCustomServers
        .map(_customProtocol)
        .whereType<String>()
        .firstOrNull;
    if (selectedCustomType != null && selectedCustomType != _selectedType) {
      _selectedType = selectedCustomType;
      for (final server in selectedCustomServers) {
        if (_customProtocol(server) == selectedCustomType) {
          _selectedServers[server.server] = true;
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _saveCustomServers();
      });
    }
    if (_configuredServers.isNotEmpty) _restoreSavedSelections();
    if (_configuredServers.isEmpty &&
        _selectedType == 'doh' &&
        _selectDefaultPrivateServers()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _saveCustomServers();
      });
    }
  }

  @override
  void dispose() {
    _testUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadDnsServers() async {
    try {
      final jsonString = await rootBundle.loadString('assets/dns/servers.json');
      final data = (jsonDecode(jsonString) as List)
          .cast<Map<String, dynamic>>();
      setState(() {
        _dnsServers = data;
        _isLoading = false;
        _restoreSavedSelections();
      });
      if (_configuredServers.isNotEmpty) _saveCustomServers();
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load DNS servers: $e')),
        );
      }
    }
  }

  void _saveDnsType(String type) {
    setState(() {
      _selectedType = type;
      _selectedServers.clear();
      if (type == 'doh') _selectDefaultPrivateServers();
    });
    _saveCustomServers();
  }

  Future<Map<String, dynamic>> _dnsTestRequest(
    String address, {
    required String defaultType,
    String? serverHost,
    String? serverPath,
    List<String> ips = const [],
    List<String> bootstraps = const [],
  }) async {
    final uri = Uri.tryParse(address);
    final type = switch (uri?.scheme.toLowerCase()) {
      'tcp' => 'tcp',
      'https' => 'doh',
      'quic' => 'doq',
      _ => defaultType,
    };
    var host =
        serverHost ?? (uri?.host.isNotEmpty == true ? uri!.host : address);
    final usesResolverIps = type == 'tcp' || type == 'udp';
    var targets = (usesResolverIps ? ips : bootstraps).toList();
    final addressIp = InternetAddress.tryParse(host);
    if (type == 'udp' && targets.isEmpty && addressIp != null) {
      targets = [addressIp.address];
    } else if (!usesResolverIps &&
        targets.isEmpty &&
        host.isNotEmpty &&
        addressIp == null) {
      // Resolve the DNS server itself locally as bootstrap data. The Go module's reported
      // latency still measures the lookup of its validation endpoint through that server.
      try {
        targets = (await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 3))).map((ip) => ip.address).toList();
      } catch (_) {
        // Let the module perform its normal local host resolution fallback.
      }
    }
    return {
      'type': type,
      'ips': targets,
      'endpoint': _testUrlController.text.trim().isEmpty
          ? ServerlessDnsSettings.defaultTestUrl
          : _testUrlController.text.trim(),
      if (type == 'doh' || type == 'doq') 'host': host,
      if ((type == 'doh' || type == 'doq') &&
          (serverPath ?? uri?.path ?? '').isNotEmpty)
        'path': serverPath ?? uri!.path,
      'timeout_ms': 5000,
    };
  }

  Future<void> _testDnsServer(
    String key,
    String address, {
    required String type,
    List<String> ips = const [],
    List<String> bootstraps = const [],
    String? serverHost,
    String? serverPath,
  }) async {
    void finish(String result) {
      if (!mounted) return;
      setState(() => _testResults[key] = result);
    }

    setState(() => _testResults[key] = 'Testing...');
    try {
      final request = await _dnsTestRequest(
        address,
        defaultType: type,
        serverHost: serverHost,
        serverPath: serverPath,
        ips: ips,
        bootstraps: bootstraps,
      );
      final result = await VpnChannel.checkDns(request);
      finish(
        result.ok && result.latency != null
            ? '${result.latency!.toStringAsFixed(1)} ms'
            : 'Failed',
      );
    } on UnsupportedError {
      finish('Android only');
    } catch (_) {
      finish('Failed');
    }
  }

  String _address(Map<String, dynamic> server) {
    final host = server['host'] as String? ?? '';
    return switch (_selectedType) {
      'udp' => host,
      'tcp' => _tcpServerAddress(host),
      'doh' => 'https://$host${server['path'] ?? '/dns-query'}',
      'doq' => 'quic://$host',
      _ => host,
    };
  }

  String _tcpServerAddress(String ip) {
    final parsed = InternetAddress.tryParse(ip);
    final host = parsed?.type == InternetAddressType.IPv6
        ? '[${parsed!.address}]'
        : parsed?.address ?? ip;
    return 'tcp://$host';
  }

  List<String> _publicServerAddresses(Map<String, dynamic> server) {
    final ips = (server['ips'] as List? ?? const []).cast<String>();
    return switch (_selectedType) {
      'udp' => ips,
      'tcp' => ips.map(_tcpServerAddress).toList(),
      'doh' || 'doq' => [_address(server)],
      _ => const [],
    };
  }

  List<String> _customServerAddresses(CustomDnsServer server) {
    final endpoint = parseCustomDnsAddress(server.server);
    if (endpoint == null) return const [];
    return switch (endpoint.dnsType) {
      'udp' => [endpoint.host],
      'tcp' => [_tcpServerAddress(endpoint.host)],
      'doh' || 'doq' => [server.server],
      _ => const [],
    };
  }

  void _restoreSavedSelections() {
    if (_configuredServers.isEmpty) return;
    final configuredAddresses = _configuredAddresses;
    _selectedServers.clear();

    for (final server in _privateServers()) {
      final address = server['address']!;
      if (configuredAddresses.contains(address)) {
        _selectedServers[address] = true;
      }
    }

    for (final server in _dnsServers.where(
      (server) => server[_selectedType] == true,
    )) {
      final address = _address(server);
      final expected = _publicServerAddresses(server);
      final legacyAddress = switch (_selectedType) {
        'tcp' => 'tcp://${server['host']}:53',
        'doq' => 'quic://${server['host']}:853',
        _ => address,
      };
      if (configuredAddresses.contains(address) ||
          configuredAddresses.contains(legacyAddress) ||
          (expected.isNotEmpty &&
              expected.every(configuredAddresses.contains))) {
        _selectedServers[address] = true;
      }
    }

    for (final server in _customServers) {
      final addresses = _customServerAddresses(server);
      if (configuredAddresses.contains(server.server) ||
          (addresses.isNotEmpty &&
              addresses.every(configuredAddresses.contains))) {
        _selectedServers[server.server] = true;
      }
    }
  }

  List<SelectedDnsServer> _selectedDnsConfiguration() {
    final rows = <SelectedDnsServer>[];

    for (final server in _privateServers()) {
      if (_selectedServers[server['address']] == true) {
        rows.add(SelectedDnsServer(addresses: [server['address']!]));
      }
    }
    for (final server in _dnsServers.where(
      (server) => server[_selectedType] == true,
    )) {
      if (_selectedServers[_address(server)] != true) continue;
      final bootstraps = _selectedType == 'doh' || _selectedType == 'doq'
          ? (server['bootstraps'] as List? ?? const []).cast<String>()
          : const <String>[];
      final addresses = _publicServerAddresses(server);
      if (addresses.isNotEmpty) {
        rows.add(
          SelectedDnsServer(
            addresses: addresses.toSet().toList(),
            bootstraps: bootstraps,
          ),
        );
      }
    }
    for (final server in _customServers.where(
      (server) => _customProtocol(server) == _selectedType,
    )) {
      if (_selectedServers[server.server] != true) continue;
      final bootstraps = _selectedType == 'doh' || _selectedType == 'doq'
          ? server.bootstrapIps
          : const <String>[];
      final addresses = _customServerAddresses(server);
      if (addresses.isNotEmpty) {
        rows.add(
          SelectedDnsServer(
            addresses: addresses.toSet().toList(),
            bootstraps: bootstraps,
          ),
        );
      }
    }

    final byAddress = <String, SelectedDnsServer>{};
    for (final server in rows) {
      final key = server.addresses.join('\u0000');
      final previous = byAddress[key];
      if (previous == null ||
          (previous.bootstraps.isEmpty && server.bootstraps.isNotEmpty)) {
        byAddress[key] = server;
      }
    }
    return byAddress.values.toList();
  }

  String _publicServerKey(Map<String, dynamic> server) =>
      'public:${server['name']}:${server['host']}:${server['path'] ?? ''}';

  String _customServerKey(CustomDnsServer server) =>
      'custom:${server.name}:${server.server}';

  String _publicInfoAddress(Map<String, dynamic> server) {
    if (_selectedType == 'udp' || _selectedType == 'tcp') {
      return (server['ips'] as List? ?? const []).join('\n');
    }
    return _address(server);
  }

  String _customInfoAddress(CustomDnsServer server) {
    if (_selectedType == 'udp' || _selectedType == 'tcp') {
      return parseCustomDnsAddress(server.server)?.host ?? 'No IP configured';
    }
    return server.server;
  }

  String? _customProtocol(CustomDnsServer server) {
    return parseCustomDnsAddress(server.server)?.dnsType;
  }

  Future<void> _testCustomDnsServer(CustomDnsServer server) async {
    final endpoint = parseCustomDnsAddress(server.server);
    if (endpoint == null) return;
    final usesResolverIps =
        endpoint.dnsType == 'tcp' || endpoint.dnsType == 'udp';
    await _testDnsServer(
      _customServerKey(server),
      server.server,
      type: endpoint.dnsType,
      ips: usesResolverIps ? [endpoint.host] : const [],
      bootstraps: server.bootstrapIps,
      serverHost: endpoint.host,
      serverPath: endpoint.path.isEmpty ? null : endpoint.path,
    );
  }

  List<Map<String, dynamic>> _privateServers() {
    final state = AppScope.read(context);
    final worker = state.worker;
    final uuid = state.workerUuid;
    if (worker == null || uuid == null || _selectedType != 'doh') return [];
    final domains = <(String, String)>[
      (worker.type.label, worker.host),
      if (worker.customDomain != null)
        ('Worker · Custom domain', worker.customDomain!),
      for (final d in state.deployments.where(
        (d) =>
            d.account.id == worker.accountId &&
            d.deployment.type != worker.type,
      ))
        (d.deployment.type.label, d.deployment.host),
    ];
    return [
      for (final (name, domain) in domains)
        {
          'name': name,
          'desc': 'Malware',
          'host': domain,
          'ips': <String>[],
          'address': 'https://$domain/$uuid',
        },
    ];
  }

  bool _selectDefaultPrivateServers() {
    if (AppScope.read(context).profile.serverless.dnsSettings.fakeSniServers) {
      return false;
    }
    final servers = _privateServers();
    for (final server in servers) {
      _selectedServers[server['address']!] = true;
    }
    return servers.isNotEmpty;
  }

  void _showAddress(String name, String address) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(name),
      content: SelectableText(address),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  void _addCustomServer() async {
    final result = await showDialog<CustomDnsServer>(
      context: context,
      builder: (_) => const AddDnsServerDialog(),
    );

    if (result != null) {
      final type = _customProtocol(result);
      setState(() {
        if (type != null && type != _selectedType) {
          _selectedType = type;
          _selectedServers.clear();
          if (type == 'doh') _selectDefaultPrivateServers();
        }
        _customServers.add(result);
        _selectedServers[result.server] = true;
      });
      _saveCustomServers();
    }
  }

  void _deleteCustomServer(int index) {
    setState(() {
      final removed = _customServers.removeAt(index);
      _selectedServers.remove(removed.server);
    });
    _saveCustomServers();
  }

  void _saveCustomServers() {
    final state = AppScope.read(context);
    final currentDnsSettings = state.profile.serverless.dnsSettings;
    final newSettings = ServerlessDnsSettings(
      dnsType: _selectedType,
      testUrl: _testUrlController.text,
      fakeSniServers: currentDnsSettings.fakeSniServers,
      customServers: _customServers,
      servers: _selectedDnsConfiguration(),
    );
    final newServerless = ServerlessSettings(
      fragments: state.profile.serverless.fragments,
      udpNoises: state.profile.serverless.udpNoises,
      udpNoiseReset: state.profile.serverless.udpNoiseReset,
      dnsSettings: newSettings,
    );
    state.write('serverless', newServerless.toJson());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visibleCustomServers = _customServers
        .where((server) => _customProtocol(server) == _selectedType)
        .toList();
    final privateServers = _privateServers();

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('DNS Servers')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('DNS Servers')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addCustomServer,
        child: const Icon(Symbols.add_rounded),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          const SectionHeader('Settings'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            shape: roundedShape(
              kHeroRadius,
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.75),
                width: 0.75,
              ),
            ),
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _selectedType,
                    decoration: const InputDecoration(labelText: 'Protocol'),
                    items: const [
                      DropdownMenuItem(value: 'udp', child: Text('UDP DNS')),
                      DropdownMenuItem(value: 'tcp', child: Text('TCP DNS')),
                      DropdownMenuItem(value: 'doh', child: Text('DoH · DNS over HTTPS ')),
                      DropdownMenuItem(value: 'doq', child: Text('DoQ · DNS over QUIC')),
                    ],
                    onChanged: (value) {
                      if (value != null) _saveDnsType(value);
                    },
                  ),
                  TextField(
                    controller: _testUrlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'Test URL'),
                    onChanged: (_) => _saveCustomServers(),
                  ),
                ],
              ),
            ),
          ),
          if (privateServers.isNotEmpty) ...[
            const SizedBox(height: 16),
            const SectionHeader('Private Servers'),
            SettingsCard(
              children: [
                for (final server in privateServers)
                  _DnsServerTile(
                    name: server['name']!,
                    desc: server['desc']!,
                    address: server['address']!,
                    isSelected: _selectedServers[server['address']] ?? false,
                    onToggle: (value) {
                      setState(() {
                        if (value) {
                          _selectedServers[server['address']!] = true;
                        } else {
                          _selectedServers.remove(server['address']);
                        }
                      });
                      _saveCustomServers();
                    },
                    onTest: () => _testDnsServer(
                      server['address']!,
                      server['address']!,
                      type: 'doh',
                    ),
                    onInfo: () =>
                        _showAddress(server['name']!, server['address']!),
                    testResult: _testResults[server['address']],
                  ),
              ],
            ),
          ],
          const SectionHeader('Public Servers'),
          SettingsCard(
            children: [
              for (final server in _dnsServers.where(
                (s) => s[_selectedType] == true,
              ))
                _DnsServerTile(
                  name: server['name'] ?? 'Unknown',
                  address: _address(server),
                  desc: server['desc'] ?? '',
                  onInfo: () => _showAddress(
                    server['name'] ?? 'DNS server',
                    _publicInfoAddress(server),
                  ),
                  onToggle: (value) {
                    setState(() {
                      if (value) {
                        _selectedServers[_address(server)] = true;
                      } else {
                        _selectedServers.remove(_address(server));
                      }
                    });
                    _saveCustomServers();
                  },
                  isSelected: _selectedServers[_address(server)] ?? false,
                  testResult: _testResults[_publicServerKey(server)],
                  onTest: () => _testDnsServer(
                    _publicServerKey(server),
                    _address(server),
                    type: _selectedType,
                    ips: (server['ips'] as List? ?? const []).cast<String>(),
                    bootstraps: (server['bootstraps'] as List? ?? const [])
                        .cast<String>(),
                    serverHost: server['host'] as String?,
                    serverPath: server['path'] as String?,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (visibleCustomServers.isNotEmpty) ...[
            const SectionHeader('Custom Servers'),
            SettingsCard(
              children: [
                for (final server in visibleCustomServers)
                  _CustomDnsServerTile(
                    name: server.name,
                    address: server.server,
                    infoAddress: _customInfoAddress(server),
                    onToggle: (value) {
                      setState(() {
                        if (value) {
                          _selectedServers[server.server] = true;
                        } else {
                          _selectedServers.remove(server.server);
                        }
                      });
                      _saveCustomServers();
                    },
                    isSelected: _selectedServers[server.server] ?? false,
                    testResult: _testResults[_customServerKey(server)],
                    onTest: () => _testCustomDnsServer(server),
                    onDelete: () =>
                        _deleteCustomServer(_customServers.indexOf(server)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DnsServerTile extends StatelessWidget {
  final String name;
  final String address;
  final String desc;
  final bool isSelected;
  final String? testResult;
  final Function(bool) onToggle;
  final VoidCallback onTest;
  final VoidCallback onInfo;

  const _DnsServerTile({
    required this.name,
    required this.address,
    required this.desc,
    required this.isSelected,
    required this.onToggle,
    required this.onTest,
    required this.onInfo,
    this.testResult,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
      minLeadingWidth: 32,
      horizontalTitleGap: 8,
      leading: Checkbox(
        value: isSelected,
        onChanged: (value) {
          if (value != null) onToggle(value);
        },
      ),
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(desc, style: const TextStyle(fontSize: 12)),
          if (testResult != null)
            Text(testResult!, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Symbols.info_rounded),
            onPressed: onInfo,
            tooltip: 'Show address',
          ),
          IconButton(
            icon: const Icon(Symbols.bolt_rounded),
            onPressed: onTest,
            tooltip: 'Test DNS server',
          ),
        ],
      ),
    );
  }
}

class _CustomDnsServerTile extends StatelessWidget {
  final String name;
  final String address;
  final String infoAddress;
  final bool isSelected;
  final String? testResult;
  final Function(bool) onToggle;
  final VoidCallback onTest;
  final VoidCallback onDelete;

  const _CustomDnsServerTile({
    required this.name,
    required this.address,
    required this.infoAddress,
    required this.isSelected,
    required this.onToggle,
    required this.onTest,
    required this.onDelete,
    this.testResult,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
      minLeadingWidth: 32,
      // horizontalTitleGap: 8,
      leading: Checkbox(
        value: isSelected,
        onChanged: (value) {
          if (value != null) onToggle(value);
        },
      ),
      title: Text(name),
      subtitle: testResult == null
          ? null
          : Text(testResult!, style: Theme.of(context).textTheme.labelSmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Symbols.delete_rounded),
            onPressed: onDelete,
          ),
          IconButton(
            tooltip: 'Show address',
            icon: const Icon(Symbols.info_rounded),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(name),
                content: SelectableText(infoAddress),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: testResult == null
                ? 'Test DNS server'
                : 'Test DNS server · $testResult',
            icon: testResult == 'Testing...'
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.bolt_rounded),
            onPressed: testResult == 'Testing...' ? null : onTest,
          ),
        ],
      ),
    );
  }
}
