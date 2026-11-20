import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cf_account.dart';
import '../models/settings.dart';
import '../models/theme_color.dart';
import '../services/cloudflare_api.dart';
import '../services/chain_proxy.dart';
import '../services/geo_assets.dart';
import '../services/local_proxy.dart';
import '../services/masque.dart';
import '../services/mitm_ca.dart';
import '../services/cloudflare_client.dart';
import '../services/my_ip.dart';
import '../services/net_errors.dart';
import '../services/tor_bridges.dart';
import '../services/updates.dart';
import '../services/vpn_channel.dart';
import '../services/warp.dart';
import '../services/xray_config.dart';

/// The app's state. Settings live in three stores (see models/settings.dart): the profile,
/// [device] (this phone only) and secrets (the Cloudflare accounts with their tokens, UUIDs
/// and deployments, encrypted). Each deployment has its own VLESS settings.
class AppState extends ChangeNotifier {
  static const _kProfile = 'profile';
  static const _kDevice = 'device';
  static const _kSecretAccounts = 'cloudflareAccounts';
  static const _kConnectionHistory = 'voidcore.connectionHistory';

  late SharedPreferences _prefs;
  final _secrets = const FlutterSecureStorage();

  /// The stored profile, without the VLESS part (that's each deployment's).
  Profile _stored = const Profile();
  Profile? _profile;

  /// How configs are built: the stored profile with the selected deployment's VLESS settings.
  Profile get profile => _profile ??= _stored.updated('vless', vless.toJson());

  DeviceSettings device = const DeviceSettings();

  /// Cloudflare accounts saved on this device, each with the deployments this install made in
  /// it (secret: tokens and UUIDs).
  List<SavedCfAccount> cfAccounts = [];

  /// Recent connection attempts; contains metadata only, never configuration payloads.
  List<Map<String, dynamic>> connectionHistory = [];
  List<ChainProxy> v2rayConfigs = [];
  List<Map<String, String>> v2raySubscriptions = [];
  AppMode v2rayAppMode = AppMode.vpn;
  PerAppMode v2rayPerAppMode = PerAppMode.off;
  List<String> v2rayPerAppApps = [];
  int v2rayMtu = 1500;
  bool v2rayNeedsReconnect = false;
  bool smartConnecting = false;
  bool v2raySmartConnecting = false;
  bool v2rayConnecting = false;
  bool v2rayDisconnecting = false;
  String? v2rayError;
  String? activeV2rayId;
  String? selectedV2rayId;
  bool _smartV2rayConnecting = false;
  String? smartConnectionStatus;
  String? v2raySmartConnectionStatus;
  bool _cancelSmartConnection = false;
  bool _cancelV2raySmartConnection = false;
  DateTime? _sessionStartedAt;
  String? _sessionMode;
  int? _sessionPing;
  DateTime? _connectStartedAt;
  String? _connectMode;

  /// Every deployment of the accounts in use: those with both Workers and Pages deployed.
  List<({SavedCfAccount account, Deployment deployment})> get deployments => [
    for (final a in cfAccounts.where((a) => a.isComplete))
      for (final d in a.deployments) (account: a, deployment: d),
  ];

  /// How [DeviceSettings.deployment] names a deployment.
  static String deploymentKey(SavedCfAccount a, Deployment d) =>
      '${a.id}/${d.type.name}';

  /// The deployment Worker mode connects to and Settings → VLESS edits (the first by default).
  ({SavedCfAccount account, Deployment deployment})? get selected {
    final all = deployments;
    return all
            .where(
              (e) =>
                  deploymentKey(e.account, e.deployment) == device.deployment,
            )
            .firstOrNull ??
        all.firstOrNull;
  }

  void selectDeployment(SavedCfAccount a, Deployment d) =>
      write('device.deployment', deploymentKey(a, d));

  /// Uses [a], with the same deployment type as now when it has one.
  void selectAccount(SavedCfAccount a) => selectDeployment(
    a,
    a.deployment(selected?.deployment.type ?? WorkerType.workers) ??
        a.deployments.first,
  );

  /// The selected deployment's VLESS settings.
  VlessSettings get vless =>
      selected?.deployment.vless ?? const VlessSettings();

  /// The selected deployment, as configs use it.
  ActiveWorker? get worker {
    final s = selected;
    if (s == null) return null;
    final d = s.deployment;
    return ActiveWorker(
      accountId: s.account.id,
      name: d.name,
      type: d.type,
      host: d.host,
      customDomain: d.customDomain,
    );
  }

  /// The selected deployment's VLESS UUID.
  String? get workerUuid => selected?.account.uuid;

  /// Default private DoH endpoints used before the DNS settings page has saved selections.
  List<String> get defaultPrivateDnsServers {
    if (profile.serverless.dnsSettings.fakeSniServers) return const [];
    final current = selected;
    final id = workerUuid;
    if (current == null || id == null) return const [];
    final customDomain = worker?.customDomain;
    return {
      for (final entry in deployments.where(
        (entry) => entry.account.id == current.account.id,
      ))
        'https://${entry.deployment.host}/$id',
      if (customDomain != null) 'https://$customDomain/$id',
    }.toList();
  }

  /// App theme colour and light/dark mode. Separate notifiers so only the theme rebuilds.
  final themeColor = ValueNotifier(ThemeColor.purple);
  final themeMode = ValueNotifier(ThemeMode.system);

  VpnStatus status = VpnStatus.disconnected;
  String? error;
  DateTime? connectedAt;

  /// Settings changed while connected; reconnect to apply them.
  bool needsReconnect = false;

  /// What the Psiphon / Tor exit is doing (progress while connecting, or reconnecting).
  String? exitDetail;

  /// The setup wizard is installing or showing its last page: keep it on screen even
  /// though a worker now exists.
  bool setupInProgress = false;

  /// Whether the app still needs the setup wizard: never finished (installs from before the
  /// flag count as finished when they have a deployment), or showing its last page.
  bool get needsSetup =>
      (!device.setupDone && deployments.isEmpty) || setupInProgress;

  /// Marks the wizard finished and leaves it.
  void finishSetup() {
    setupInProgress = false;
    write('device.setupDone', true);
  }

  void setSetupInProgress(bool value) {
    if (setupInProgress == value) return;
    setupInProgress = value;
    notifyListeners();
  }

  int upSpeed = 0;
  int downSpeed = 0;

  /// Bytes sent/received since the current connection started.
  int totalUp = 0;
  int totalDown = 0;
  int? pingMs;
  bool pinging = false;

  /// Exit IPs seen by Cloudflare-hosted and other sites (while connected).
  MyIps? myIps;
  bool loadingIps = false;

  /// This phone's address on Wi-Fi / hotspot / USB tethering (null on mobile data only).
  String? lanIp;

  /// Workers requests in the last 24 hours for the active worker's account.
  ({int total, int worker})? usage;
  bool loadingUsage = false;
  String? usageError;

  StreamSubscription<VpnStateEvent>? _stateSub;
  Timer? _trafficTimer;
  Timer? _lanTimer;

  bool get isConnected => status == VpnStatus.connected;
  bool get isBusy =>
      status == VpnStatus.connecting || status == VpnStatus.disconnecting;

  // region connection type

  /// The connection types that can be used: Worker with an account that has both deployments,
  /// WARP / MASQUE once registered; Psiphon, Tor and Serverless always.
  List<ConnectionMode> get availableModes => [
    for (final m in const [
      ConnectionMode.worker,
      ConnectionMode.masque,
      ConnectionMode.warp,
      ConnectionMode.psiphon,
      ConnectionMode.tor,
      ConnectionMode.serverless,
    ])
      if (switch (m) {
        ConnectionMode.worker => deployments.isNotEmpty,
        ConnectionMode.warp => profile.warp.account != null,
        ConnectionMode.masque => profile.masque.account != null,
        _ => true,
      })
        m,
  ];

  /// The chosen type, or the first available one when it can't be used (yet).
  ConnectionMode get mode {
    final chosen =
        ConnectionMode.values.asNameMap()[device.connectionType] ??
        ConnectionMode.worker;
    final available = availableModes;
    return available.contains(chosen) ? chosen : available.first;
  }

  /// Types with a Mode row on the home page: Worker's and WARP's variant, Serverless's mode or
  /// Tor's bridge.
  bool get hasModeOption =>
      mode.hasVariants ||
      mode == ConnectionMode.masque ||
      mode == ConnectionMode.serverless ||
      mode == ConnectionMode.tor;

  /// The current type's variant (Worker and WARP; [ConnectionVariant.normal] for the others).
  ConnectionVariant get variant {
    final name = switch (mode) {
      ConnectionMode.worker => device.workerVariant,
      ConnectionMode.warp => device.warpVariant,
      _ => null,
    };
    return ConnectionVariant.values.asNameMap()[name] ??
        ConnectionVariant.normal;
  }

  /// Proxy mode: only the local SOCKS/HTTP proxy, no VPN.
  bool get proxyMode => device.appMode == AppMode.proxy;

  void setMode(ConnectionMode value) =>
      write('device.connection.type', value.name);

  /// Switches the current type's (Worker / WARP) variant.
  void setVariant(ConnectionVariant value) {
    if (!mode.hasVariants) return;
    write('device.connection.${mode.name}Variant', value.name);
  }

  MasqueVariant get masqueVariant => XrayConfigBuilder.masqueVariantOf(device);

  void setMasqueVariant(MasqueVariant value) =>
      write('device.connection.masqueVariant', value.name);

  ServerlessMode get serverlessMode =>
      XrayConfigBuilder.serverlessModeOf(device);

  void setServerlessMode(ServerlessMode value) =>
      write('device.connection.serverlessMode', value.name);

  /// Domain Fronting's CA files (bpb-cert.crt / .key) are on this device.
  Future<bool> hasMitmCa() => VpnChannel.mitmCaExists();

  /// Creates Domain Fronting's CA on first use, then opens Android's CA install. Returns where
  /// bpb-cert.crt was saved (Android 11+), or null.
  Future<String?> installMitmCa() async {
    if (!await VpnChannel.mitmCaExists()) {
      await VpnChannel.saveMitmCa(await Isolate.run(MitmCa.generate));
    }
    return VpnChannel.installMitmCa();
  }

  void setAppMode(AppMode value) => write('device.appMode', value.name);

  /// The exit node in use with the current type (chosen per type; Serverless has no chain proxy).
  ExitNode get exitNode =>
      XrayConfigBuilder.exitFor(mode, device, profile.chains);

  void setExitNode(ExitNode value) =>
      write('device.exit.nodes.${mode.name}', value.name);

  /// Selects the workspace profile independently from the currently active VPN engine.
  void selectV2ray(ChainProxy config) {
    selectedV2rayId = config.id;
    _prefs.setString('voidcore.v2ray.selected', config.id);
    notifyListeners();
  }

  void updateV2raySettings({
    AppMode? appMode,
    PerAppMode? perAppMode,
    List<String>? apps,
    int? mtu,
  }) {
    if (appMode != null) v2rayAppMode = appMode;
    if (perAppMode != null) v2rayPerAppMode = perAppMode;
    if (apps != null) v2rayPerAppApps = List.of(apps);
    if (mtu != null) v2rayMtu = mtu.clamp(576, 9000).toInt();
    _prefs.setString('voidcore.v2ray.settings', jsonEncode({
      'appMode': v2rayAppMode.name,
      'perAppMode': v2rayPerAppMode.name,
      'apps': v2rayPerAppApps,
      'mtu': v2rayMtu,
    }));
    if (activeV2rayId != null && status != VpnStatus.disconnected) {
      v2rayNeedsReconnect = true;
    }
    notifyListeners();
  }

  void _saveV2raySubscriptions() {
    _prefs.setString('voidcore.v2ray.subscriptions', jsonEncode(v2raySubscriptions));
  }

  void addV2raySubscription({required String id, required String name, required String url}) {
    v2raySubscriptions = [...v2raySubscriptions, {'id': id, 'name': name, 'url': url}];
    _saveV2raySubscriptions();
    notifyListeners();
  }

  void updateV2raySubscription({required String id, required String name, required String url}) {
    v2raySubscriptions = [
      for (final item in v2raySubscriptions)
        if (item['id'] == id) {'id': id, 'name': name, 'url': url} else item,
    ];
    _saveV2raySubscriptions();
    notifyListeners();
  }

  void deleteV2raySubscription(String id) {
    v2raySubscriptions = v2raySubscriptions.where((item) => item['id'] != id).toList();
    final category = 'subscription:$id';
    final removed = v2rayConfigs.where((config) => config.category == category).toList();
    for (final config in removed) {
      if (activeV2rayId == config.id) unawaited(disconnect());
      if (selectedV2rayId == config.id) selectedV2rayId = null;
    }
    v2rayConfigs = v2rayConfigs.where((config) => config.category != category).toList();
    if (selectedV2rayId == null) {
      if (v2rayConfigs.isNotEmpty) {
        selectedV2rayId = v2rayConfigs.first.id;
        _prefs.setString('voidcore.v2ray.selected', selectedV2rayId!);
      } else {
        _prefs.remove('voidcore.v2ray.selected');
      }
    }
    _saveV2rayConfigs();
    _saveV2raySubscriptions();
    notifyListeners();
  }

  void replaceV2raySubscriptionConfigs(String id, List<ChainProxy> configs) {
    final category = 'subscription:$id';
    final previous = v2rayConfigs.where((config) => config.category == category).toList();
    if (previous.any((config) => config.id == activeV2rayId)) {
      unawaited(disconnect());
      activeV2rayId = null;
    }
    final previousIds = previous.map((config) => config.id).toSet();
    v2rayConfigs = v2rayConfigs.where((config) => config.category != category).toList();
    final existingLinks = v2rayConfigs.map((config) => config.link).toSet();
    for (final config in configs) {
      if (existingLinks.add(config.link)) {
        v2rayConfigs.add(config.copyWith(category: category));
      }
    }
    if (selectedV2rayId == null || previousIds.contains(selectedV2rayId)) {
      selectedV2rayId = v2rayConfigs.where((config) => config.category == category).firstOrNull?.id
          ?? v2rayConfigs.firstOrNull?.id;
      if (selectedV2rayId == null) {
        _prefs.remove('voidcore.v2ray.selected');
      } else {
        _prefs.setString('voidcore.v2ray.selected', selectedV2rayId!);
      }
    }
    _saveV2rayConfigs();
    notifyListeners();
  }

  void _saveV2rayConfigs() {
    _prefs.setString(
      'voidcore.v2ray.configs',
      jsonEncode(v2rayConfigs.map((c) => c.toJson()).toList()),
    );
  }

  /// Adds V2Ray workspace entries to their own store.
  void addV2rayConfigs(List<ChainProxy> configs) {
    final existing = v2rayConfigs.map((c) => c.link).toSet();
    for (final config in configs) {
      if (existing.add(config.link)) v2rayConfigs.add(config);
    }
    if (selectedV2rayId == null && v2rayConfigs.isNotEmpty) {
      selectedV2rayId = v2rayConfigs.first.id;
      _prefs.setString('voidcore.v2ray.selected', selectedV2rayId!);
    }
    _saveV2rayConfigs();
    notifyListeners();
  }

  void updateV2rayConfig(ChainProxy updated) {
    v2rayConfigs = [
      for (final config in v2rayConfigs)
        if (config.id == updated.id) updated else config,
    ];
    _saveV2rayConfigs();
    notifyListeners();
  }

  void duplicateV2rayConfig(ChainProxy config) {
    v2rayConfigs.add(ChainProxy(
      id: newChainId(),
      name: '${config.name} (copy)',
      link: config.link,
      category: config.category,
    ));
    _saveV2rayConfigs();
    notifyListeners();
  }

  void deleteV2rayConfig(ChainProxy config) {
    if (selectedV2rayId == config.id) {
      selectedV2rayId = null;
      _prefs.remove('voidcore.v2ray.selected');
    }
    if (activeV2rayId == config.id) unawaited(disconnect());
    v2rayConfigs = v2rayConfigs.where((c) => c.id != config.id).toList();
    _saveV2rayConfigs();
    notifyListeners();
  }

  /// [region]: an exitRegions code, or empty for the fastest (any region).
  void setExitRegion(String region) => write('device.exit.region', region);

  /// Tor type: a torBridges name.
  void setTorBridge(String bridge) =>
      write('device.connection.torBridge', bridge);

  void setThemeColor(ThemeColor value) =>
      write('device.theme.color', value.name);

  void setThemeMode(ThemeMode value) => write('device.theme.mode', value.name);

  // endregion

  // region configs

  XrayConfigBuilder get builder => XrayConfigBuilder(
    profile,
    device,
    worker: worker,
    uuid: workerUuid,
    defaultPrivateDnsServers: defaultPrivateDnsServers,
  );

  /// Builds the config used for both display and connection startup.
  Future<XrayBuild> buildConfig() => builder.build(mode, variant: variant);

  // endregion

  // region init

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _stored = Profile.fromJson(_decodeMap(_prefs.getString(_kProfile)))
        .updated('vless', null);
    device = DeviceSettings.fromJson(_decodeMap(_prefs.getString(_kDevice)));
    selectedV2rayId = _prefs.getString('voidcore.v2ray.selected');
    v2raySubscriptions = _decodeList(_prefs.getString('voidcore.v2ray.subscriptions'))
        .whereType<Map>()
        .map((item) => {
          'id': '${item['id'] ?? ''}',
          'name': '${item['name'] ?? ''}',
          'url': '${item['url'] ?? ''}',
        })
        .where((item) => item['id']!.isNotEmpty && item['url']!.isNotEmpty)
        .toList();
    final savedV2rayConfigs = _prefs.getString('voidcore.v2ray.configs');
    v2rayConfigs = savedV2rayConfigs == null
        ? List<ChainProxy>.of(_stored.chains)
        : _decodeList(savedV2rayConfigs)
            .whereType<Map>()
            .map(ChainProxy.parse)
            .whereType<ChainProxy>()
            .toList();
    if (savedV2rayConfigs == null && v2rayConfigs.isNotEmpty) {
      _saveV2rayConfigs();
    }
    if (selectedV2rayId != null && !v2rayConfigs.any((c) => c.id == selectedV2rayId)) {
      selectedV2rayId = null;
      await _prefs.remove('voidcore.v2ray.selected');
    }
    if (selectedV2rayId == null && v2rayConfigs.isNotEmpty) {
      selectedV2rayId = v2rayConfigs.first.id;
      await _prefs.setString('voidcore.v2ray.selected', selectedV2rayId!);
    }
    final v2raySettings = _decodeMap(_prefs.getString('voidcore.v2ray.settings'));
    v2rayAppMode = AppMode.values.asNameMap()[v2raySettings['appMode']] ?? AppMode.vpn;
    v2rayPerAppMode = PerAppMode.values.asNameMap()[v2raySettings['perAppMode']] ?? PerAppMode.off;
    v2rayPerAppApps = (v2raySettings['apps'] as List? ?? const []).map((e) => '$e').toList();
    v2rayMtu = (v2raySettings['mtu'] as num?)?.toInt() ?? 1500;
    connectionHistory = (_decodeList(_prefs.getString(_kConnectionHistory)))
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (_prefs.containsKey('configOverrides')) {
      await _prefs.remove('configOverrides');
    }

    try {
      final accounts = await _secrets.read(key: _kSecretAccounts);
      if (accounts != null) {
        cfAccounts = (jsonDecode(accounts) as List)
            .whereType<Map>()
            .map((e) => SavedCfAccount.fromJson(Map<String, dynamic>.from(e)))
            .whereType<SavedCfAccount>()
            .toList();
      }
    } catch (_) {
      // Unreadable secrets (e.g. restored from another device): set up again.
    }
    _applyDeviceSideEffects();

    _stateSub = VpnChannel.states.listen(_onVpnState);
    CloudflareClient.tunnelPort = () => isConnected ? LocalProxy.port : null;
    notifyListeners();
    _redeployDue();
    unawaited(refreshUsage());
    unawaited(refreshLanIp());
    _lanTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => refreshLanIp(),
    );
  }

  static List<dynamic> _decodeList(String? raw) {
    if (raw == null) return [];
    try {
      final value = jsonDecode(raw);
      return value is List ? value : [];
    } catch (_) {
      return [];
    }
  }

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null) return {};
    try {
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _trafficTimer?.cancel();
    _lanTimer?.cancel();
    super.dispose();
  }

  // endregion

  // region reading and writing settings

  /// A setting by path: "device.…" reads [device], anything else [profile]
  /// (e.g. "vless.ech.enabled", the selected deployment's).
  Object? read(String path) => path.startsWith('device.')
      ? readPath(device.toJson(), path.substring(7))
      : readPath(profile.toJson(), path);

  String readString(String path) => '${read(path) ?? ''}';

  bool readBool(String path) => read(path) == true;

  int readInt(String path) => (read(path) as num?)?.toInt() ?? 0;

  List<String> readList(String path) =>
      (read(path) as List? ?? const []).map((e) => '$e').toList();

  /// Sets a setting by path (see [read]). Empty strings mean "not set".
  void write(String path, Object? value) {
    if (value is String && value.trim().isEmpty) value = null;
    if (path.startsWith('device.')) {
      _setDevice(
        device.updated(path.substring(7), value),
        reconnect: !path.startsWith('device.theme.'),
      );
    } else if (path.startsWith('vless.')) {
      _setVless(
        VlessSettings.parse(
          writePath(vless.toJson(), path.substring(6), value),
        ),
      );
    } else {
      _setProfile(profile.updated(path, value));
    }
  }

  /// Stores [value]; its VLESS part goes to the selected deployment.
  void _setProfile(Profile value) {
    _stored = value.updated('vless', null);
    _profile = null;
    _prefs.setString(_kProfile, jsonEncode(_stored.toSparseJson()));
    _markChangedWhileConnected();
    if (jsonEncode(value.vless.toJson()) != jsonEncode(vless.toJson())) {
      _setVless(value.vless);
    }
    notifyListeners();
  }

  /// Saves the selected deployment's VLESS settings. A new proxy IPs list or fallback website
  /// (its ENV) is deployed right away.
  void _setVless(VlessSettings value) {
    final s = selected;
    if (s == null) return;
    final old = s.deployment.vless;
    final envChanged =
        jsonEncode(old.proxyIps) != jsonEncode(value.proxyIps) ||
        old.fallbackUrl != value.fallbackUrl;
    _putDeployment(
      s.account,
      s.deployment.copyWith(vless: value, pending: envChanged ? true : null),
    );
    _markChangedWhileConnected();
    notifyListeners();
    if (envChanged) unawaited(redeploy(s.account, s.deployment.type));
  }

  void _setDevice(DeviceSettings value, {bool reconnect = true}) {
    device = value;
    _profile = null;
    _prefs.setString(_kDevice, jsonEncode(device.toSparseJson()));
    _applyDeviceSideEffects();
    if (reconnect) _markChangedWhileConnected();
    notifyListeners();
  }

  void _applyDeviceSideEffects() {
    LocalProxy.credentials = device.lanAuth;
    themeColor.value =
        ThemeColor.values.asNameMap()[device.themeColor] ?? ThemeColor.purple;
    themeMode.value =
        ThemeMode.values.asNameMap()[device.themeMode] ?? ThemeMode.system;
  }

  /// Defaults everywhere except the private parts and the configured clean IPs and endpoints.
  void resetSettings() {
    final current = profile;
    _setProfile(
      current
          .keepingPrivate(const Profile())
          .updated('vless.cleanIps', current.vless.cleanIps)
          .updated('warp.endpoints', current.warp.endpoints)
          .updated('masque.endpoints', current.masque.endpoints),
    );
  }

  void _markChangedWhileConnected() {
    if (status != VpnStatus.disconnected) needsReconnect = true;
  }

  // endregion

  // region settings file

  static const _settingsFileFormat = 'bpb-settings';

  /// A settings file to share: the profile (VLESS: the selected deployment's) without the
  /// private parts.
  String exportSettingsFile() => const JsonEncoder.withIndent('  ').convert({
    'format': _settingsFileFormat,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'profile': profile.toExportJson(),
  });

  /// Applies a file from [exportSettingsFile] (its VLESS settings to the selected deployment);
  /// the private parts and device settings stay. Throws [FormatException] if [text] isn't a
  /// settings file.
  void importSettingsFile(String text) {
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      throw const FormatException("This file isn't valid JSON.");
    }
    if (data is! Map ||
        data['format'] != _settingsFileFormat ||
        data['profile'] is! Map) {
      throw const FormatException("This isn't a BPB settings file.");
    }
    final imported = Profile.fromJson(
      Map<String, dynamic>.from(data['profile'] as Map),
    );
    _setProfile(profile.keepingPrivate(imported));
  }

  /// Persists a short, non-sensitive connection history entry.
  void _saveHistory({
    required String mode,
    required DateTime startedAt,
    required bool success,
    int? latencyMs,
    String? reason,
  }) {
    connectionHistory = [
      {
        'mode': mode,
        'startedAt': startedAt.toIso8601String(),
        'durationSeconds': DateTime.now().difference(startedAt).inSeconds.clamp(0, 1 << 31),
        'success': success,
        if (latencyMs != null && latencyMs >= 0) 'latencyMs': latencyMs,
        if (reason != null) 'reason': reason,
      },
      ...connectionHistory,
    ].take(50).toList();
    unawaited(_prefs.setString(_kConnectionHistory, jsonEncode(connectionHistory)));
    notifyListeners();
  }

  Future<void> clearConnectionHistory() async {
    connectionHistory = [];
    await _prefs.remove(_kConnectionHistory);
    notifyListeners();
  }

  void cancelSmartConnect() {
    _cancelSmartConnection = true;
    smartConnectionStatus = 'Cancelling…';
    notifyListeners();
  }

  void cancelV2raySmartConnect() {
    _cancelV2raySmartConnection = true;
    v2raySmartConnectionStatus = 'Cancelling…';
    notifyListeners();
  }

  Future<bool> _waitForConnection({Duration timeout = const Duration(seconds: 25)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_cancelSmartConnection || _cancelV2raySmartConnection) return false;
      if (isConnected) return true;
      if (status == VpnStatus.disconnected && error != null) return false;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return isConnected;
  }

  Future<int?> _measureDownloadKbps() async {
    final client = proxiedClient(LocalProxy.port, connectTimeout: const Duration(seconds: 8));
    final stopwatch = Stopwatch()..start();
    try {
      final response = await client
          .get(Uri.parse('https://speed.cloudflare.com/__down?bytes=500000'))
          .timeout(const Duration(seconds: 12));
      stopwatch.stop();
      if (response.statusCode != 200 || response.bodyBytes.isEmpty || stopwatch.elapsedMilliseconds == 0) {
        return null;
      }
      return (response.bodyBytes.length * 8 / stopwatch.elapsedMilliseconds).round();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _waitUntilDisconnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (status != VpnStatus.disconnected && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Tests only connection modes configured in this installation, then reconnects using
  /// the lowest measured tunnel latency. Each candidate is tested through the real VPN engine.
  Future<ConnectionMode?> smartConnect() async {
    if (smartConnecting || v2raySmartConnecting || isBusy) return null;
    smartConnecting = true;
    _cancelSmartConnection = false;
    smartConnectionStatus = 'Preparing connection tests…';
    error = null;
    notifyListeners();

    final candidates = List<ConnectionMode>.of(availableModes);
    final results = <({ConnectionMode mode, int ping, int? kbps})>[];
    final originalMode = mode;
    final wasInitiallyConnected = isConnected;
    try {
      if (isConnected) {
        await disconnect();
        await _waitUntilDisconnected();
      }

      for (final candidate in candidates) {
        if (_cancelSmartConnection) break;
        smartConnectionStatus = 'Testing ${candidate.label}…';
        setMode(candidate);
        error = null;
        notifyListeners();

        await connect();
        final connected = await _waitForConnection();
        if (connected && !_cancelSmartConnection) {
          final samples = <int>[];
          for (var i = 0; i < 3 && !_cancelSmartConnection; i++) {
            final sample = await VpnChannel.measureDelay();
            if (sample >= 0) samples.add(sample);
            if (i < 2) await Future.delayed(const Duration(milliseconds: 250));
          }
          samples.sort();
          final measured = samples.isEmpty ? null : samples[samples.length ~/ 2];
          final kbps = await _measureDownloadKbps();
          if (measured != null) {
            _sessionPing = measured;
            pingMs = measured;
            results.add((mode: candidate, ping: measured, kbps: kbps));
          }
          await disconnect();
          await _waitUntilDisconnected();
        } else if (status != VpnStatus.disconnected) {
          // A timed-out candidate may still be in its connecting state. Stop it before
          // moving to the next candidate so tests never overlap.
          await disconnect();
          await _waitUntilDisconnected();
        }
      }

      if (_cancelSmartConnection) {
        setMode(originalMode);
        smartConnectionStatus = 'Auto Connect cancelled';
        if (wasInitiallyConnected && !isConnected) await connect();
        return null;
      }

      if (results.isEmpty) {
        setMode(originalMode);
        smartConnectionStatus = 'No connection passed the latency test';
        error = 'Smart Connect could not find a working connection.';
        if (wasInitiallyConnected && !isConnected) await connect();
        return null;
      }

      final hasSpeedMeasurements = results.any((r) => r.kbps != null);
      results.sort((a, b) {
        if (hasSpeedMeasurements) {
          final speedA = a.kbps ?? -1;
          final speedB = b.kbps ?? -1;
          final bySpeed = speedB.compareTo(speedA);
          if (bySpeed != 0) return bySpeed;
        }
        return a.ping.compareTo(b.ping);
      });
      final best = results.first;
      setMode(best.mode);
      smartConnectionStatus = hasSpeedMeasurements
          ? 'Best measured: ${best.mode.label} · ${best.kbps} kbps · ${best.ping} ms'
          : 'Lowest measured latency: ${best.mode.label} · ${best.ping} ms';
      error = null;
      await connect();
      final reconnected = await _waitForConnection();
      if (!reconnected) {
        smartConnectionStatus = 'Best measured: ${best.mode.label}, but the final reconnect failed';
        return null;
      }
      return best.mode;
    } finally {
      smartConnecting = false;
      _cancelSmartConnection = false;
      notifyListeners();
    }
  }

  // endregion

  // region VPN

  void _onVpnState(VpnStateEvent event) {
    final previousStatus = status;
    final wasConnected = status == VpnStatus.connected;
    final sameSession = connectedAt != null && connectedAt == event.connectedAt;
    status = event.status;
    if (v2rayConnecting || v2rayDisconnecting || v2raySmartConnecting || activeV2rayId != null) {
      v2rayError = event.error;
    } else {
      error = event.error;
    }
    connectedAt = event.connectedAt;

    if (event.status == VpnStatus.connected && !wasConnected) {
      _sessionStartedAt = event.connectedAt ?? _connectStartedAt ?? DateTime.now();
      _sessionMode = _connectMode ?? mode.label;
      _sessionPing = null;
      _connectStartedAt = null;
      _connectMode = null;
    } else if (event.status == VpnStatus.disconnected &&
        previousStatus != VpnStatus.disconnected) {
      if (_sessionStartedAt != null) {
        _saveHistory(
          mode: _sessionMode ?? mode.label,
          startedAt: _sessionStartedAt!,
          success: true,
          latencyMs: _sessionPing,
        );
        _sessionStartedAt = null;
        _sessionMode = null;
        _sessionPing = null;
      } else if (previousStatus == VpnStatus.connecting || _connectStartedAt != null) {
        _saveHistory(
          mode: _connectMode ?? mode.label,
          startedAt: _connectStartedAt ?? DateTime.now(),
          success: false,
          reason: 'Connection failed',
        );
        _connectStartedAt = null;
        _connectMode = null;
      }
    }
    if (event.status == VpnStatus.disconnected) activeV2rayId = null;
    exitDetail = event.detail;
    if (status == VpnStatus.connected) {
      _startTrafficTimer();
      if (!wasConnected && !sameSession) {
        needsReconnect = false;
        totalUp = totalDown = 0;
        unawaited(refreshMyIps());
        unawaited(refreshUsage());
        _redeployDue(); // The API may only be reachable through the tunnel.
      }
    } else {
      _trafficTimer?.cancel();
      upSpeed = downSpeed = 0;
      if (status == VpnStatus.disconnected) {
        pingMs = null;
        myIps = null;
        needsReconnect = false;
      }
    }
    notifyListeners();
  }

  void _startTrafficTimer() {
    _trafficTimer?.cancel();
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final t = await VpnChannel.traffic();
        upSpeed = t.up;
        downSpeed = t.down;
        totalUp = t.totalUp;
        totalDown = t.totalDown;
        notifyListeners();
      } catch (_) {
        // Core stopping; ignore.
      }
    });
  }

  Future<void> toggle() =>
      status == VpnStatus.disconnected ? connect() : disconnect();

  Future<void> connect() async {
    if (isBusy || _smartV2rayConnecting) return;
    if (status != VpnStatus.disconnected) {
      await VpnChannel.stop();
      await _waitUntilDisconnected();
      if (status != VpnStatus.disconnected) {
        error = 'The previous VPN session did not stop; refusing to start another engine.';
        notifyListeners();
        return;
      }
    }
    activeV2rayId = null;
    v2rayNeedsReconnect = false;
    _connectStartedAt = DateTime.now();
    _connectMode = mode.label;
    error = null;
    status = VpnStatus.connecting;
    notifyListeners();
    try {
      if (!await VpnChannel.prepare(vpn: !proxyMode)) {
        throw StateError('VPN permission denied');
      }
      // First WARP / MASQUE connection: register the account, which also gives its endpoints.
      final warp = profile.warp, masque = profile.masque;
      if (mode.isWarp && (warp.account == null || warp.endpoints.isEmpty)) {
        await renewWarpAccount();
      }
      if (mode == ConnectionMode.masque &&
          (masque.account == null || masque.endpoints.isEmpty)) {
        await renewMasqueAccount();
      }
      if (mode == ConnectionMode.serverless &&
          serverlessMode == ServerlessMode.domainFronting &&
          !await VpnChannel.mitmCaExists()) {
        throw StateError(
          'Install the MITM certificate first: Settings → Serverless.',
        );
      }
      await _start();
    } catch (e) {
      status = VpnStatus.disconnected;
      error = e is StateError ? e.message : '$e';
      if (_connectStartedAt != null) {
        _saveHistory(
          mode: _connectMode ?? mode.label,
          startedAt: _connectStartedAt!,
          success: false,
          reason: 'Connection failed',
        );
        _connectStartedAt = null;
        _connectMode = null;
      }
      notifyListeners();
    }
  }

  /// Starts a saved V2Ray workspace profile using the shared Xray/VPN service.
  /// Any existing engine is stopped first, so only one tunnel can own the VPN interface.
  Future<bool> connectV2ray(ChainProxy config, {bool fromSmartConnect = false}) async {
    if (isBusy || (v2raySmartConnecting && !fromSmartConnect) || smartConnecting) return false;
    v2rayConnecting = true;
    v2rayError = null;
    error = null;
    notifyListeners();
    try {
      if (status != VpnStatus.disconnected) {
        await VpnChannel.stop();
        await _waitUntilDisconnected();
        if (status != VpnStatus.disconnected) {
          throw StateError('The previous VPN session did not stop.');
        }
      }
      activeV2rayId = config.id;
      selectV2ray(config);
      v2rayNeedsReconnect = false;
      _connectStartedAt = DateTime.now();
      _connectMode = 'V2Ray · ${config.name}';
      status = VpnStatus.connecting;
      notifyListeners();
      if (!await VpnChannel.prepare(vpn: v2rayAppMode == AppMode.vpn)) {
        throw StateError('VPN permission denied');
      }
      final build = await XrayConfigBuilder(profile, device)
          .buildStandaloneChain(config, appMode: v2rayAppMode, mtu: v2rayMtu);
      await VpnChannel.start(
        config: build.config,
        remark: 'V2Ray · ${config.name}',
        perAppMode: v2rayPerAppMode.name,
        apps: v2rayPerAppApps,
        mtu: v2rayMtu,
        appendHttpProxy: false,
        proxyOnly: v2rayAppMode == AppMode.proxy,
        verifyConnection: true,
      );
      final connected = await _waitForConnection();
      if (!connected) {
        await VpnChannel.stop();
        await _waitUntilDisconnected();
        if (status != VpnStatus.disconnected) {
          throw StateError('The failed V2Ray session did not stop cleanly.');
        }
        activeV2rayId = null;
      }
      return connected;
    } catch (e) {
      try {
        await VpnChannel.stop();
        await _waitUntilDisconnected();
      } catch (_) {
        // Preserve the original startup error.
      }
      activeV2rayId = null;
      status = VpnStatus.disconnected;
      v2rayError = e is StateError ? e.message : '$e';
      if (_connectStartedAt != null) {
        _saveHistory(
          mode: _connectMode ?? 'V2Ray',
          startedAt: _connectStartedAt!,
          success: false,
          reason: 'Connection failed',
        );
        _connectStartedAt = null;
        _connectMode = null;
      }
      notifyListeners();
      return false;
    } finally {
      v2rayConnecting = false;
      notifyListeners();
    }
  }

  /// Auto Connect probes TCP-capable V2Ray endpoints, then tries the lowest-latency
  /// candidates in order. A failed real connection falls through to the next.
  Future<ChainProxy?> smartConnectV2ray() async {
    if ((smartConnecting || v2raySmartConnecting || isBusy) || v2rayConfigs.isEmpty) return null;
    v2raySmartConnecting = true;
    _smartV2rayConnecting = true;
    _cancelV2raySmartConnection = false;
    v2raySmartConnectionStatus = 'Checking servers…';
    v2rayError = null;
    error = null;
    notifyListeners();
    try {
      // Probe the physical network, not an existing VPN tunnel.
      if (status != VpnStatus.disconnected) {
        await VpnChannel.stop();
        await _waitUntilDisconnected();
        if (status != VpnStatus.disconnected) {
          throw StateError('The previous VPN session did not stop before server checks.');
        }
      }
      final measured = <({ChainProxy config, int latency})>[];
      var skippedUdpOnly = 0;
      for (final config in v2rayConfigs) {
        if (_cancelV2raySmartConnection) break;
        final info = ChainInfo.of(config.link);
        if (info == null) continue;
        if (info.isUdp) {
          skippedUdpOnly++;
          continue;
        }
        v2raySmartConnectionStatus = 'Checking servers…';
        notifyListeners();
        try {
          final watch = Stopwatch()..start();
          final socket = await Socket.connect(
            info.uri.server,
            info.uri.port,
            timeout: const Duration(seconds: 4),
          );
          watch.stop();
          socket.destroy();
          measured.add((config: config, latency: watch.elapsedMilliseconds));
        } catch (_) {
          // An unreachable TCP endpoint is excluded; no synthetic ping is reported.
        }
      }
      if (_cancelV2raySmartConnection) {
        v2raySmartConnectionStatus = 'Auto Connect cancelled';
        return null;
      }
      measured.sort((a, b) => a.latency.compareTo(b.latency));
      if (measured.isEmpty) {
        v2raySmartConnectionStatus = skippedUdpOnly > 0
            ? 'No TCP-reachable server found; skipped $skippedUdpOnly UDP-only profile(s) because they cannot be measured with a direct TCP probe.'
            : 'No TCP-reachable V2Ray server was found';
        return null;
      }
      for (final candidate in measured) {
        if (_cancelV2raySmartConnection) break;
        v2raySmartConnectionStatus = 'Connecting';
        notifyListeners();
        if (await connectV2ray(candidate.config, fromSmartConnect: true)) {
          v2raySmartConnectionStatus = 'Connected';
          return candidate.config;
        }
        if (_cancelV2raySmartConnection) break;
        if (status != VpnStatus.disconnected) {
          await VpnChannel.stop();
          await _waitUntilDisconnected();
        }
      }
      if (_cancelV2raySmartConnection) {
        v2raySmartConnectionStatus = 'Auto Connect cancelled';
        return null;
      }
      v2raySmartConnectionStatus = 'All reachable V2Ray servers failed to connect';
      return null;
    } finally {
      v2raySmartConnecting = false;
      _smartV2rayConnecting = false;
      _cancelV2raySmartConnection = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    final wasV2ray = activeV2rayId != null;
    if (wasV2ray) {
      v2rayDisconnecting = true;
      notifyListeners();
    }
    activeV2rayId = null;
    v2rayNeedsReconnect = false;
    try {
      await VpnChannel.stop();
      if (wasV2ray) await _waitUntilDisconnected();
    } finally {
      if (wasV2ray) {
        v2rayDisconnecting = false;
        notifyListeners();
      }
    }
  }

  Future<void> reconnect() async {
    final v2rayId = activeV2rayId;
    if (v2rayId != null) {
      final saved = v2rayConfigs.where((c) => c.id == v2rayId).firstOrNull;
      if (saved != null) {
        await connectV2ray(saved);
        return;
      }
      activeV2rayId = null;
    }
    if (status == VpnStatus.disconnected) return connect();
    // Stop the current engine before starting the newly selected mode/configuration.
    needsReconnect = false;
    await VpnChannel.stop();
    await _waitUntilDisconnected();
    if (status != VpnStatus.disconnected) {
      error = 'The previous VPN session did not stop.';
      notifyListeners();
      return;
    }
    // Switching from Proxy to VPN mode needs the VPN permission.
    if (!await VpnChannel.prepare(vpn: !proxyMode)) {
      error = 'VPN permission denied';
      notifyListeners();
      return;
    }
    try {
      await _start();
    } catch (e) {
      error = e is StateError ? e.message : '$e';
      notifyListeners();
    }
  }

  Future<void> _start() async {
    final build = await buildConfig();
    // The Psiphon / Tor types connect directly. As an exit, Psiphon / Tor run only when the
    // config has their upstream inbound.
    final exitType = switch (mode) {
      ConnectionMode.psiphon => ExitNode.psiphon,
      ConnectionMode.tor => ExitNode.tor,
      _ => null,
    };
    final inbounds = (build.config['inbounds'] as List?) ?? const [];
    bool hasInbound(String tag) =>
        inbounds.any((i) => i is Map && i['tag'] == tag);
    final dnsMode =
        mode == ConnectionMode.serverless &&
        serverlessMode == ServerlessMode.dns;
    // The exit process: "psiphon" or "tor".
    final exit = dnsMode
        ? null
        : exitType?.name ??
              const [
                'psiphon',
                'tor',
              ].where((name) => hasInbound('$name-in')).firstOrNull;
    // The Psiphon / Tor types are already named after their exit.
    final exitInRemark = exit != null && exitType == null;
    await VpnChannel.start(
      config: build.config,
      // Shown after the app name in the notification header: "BPB · Fragment · Psiphon".
      remark: [
        mode.label,
        if (exitInRemark)
          XrayConfigBuilder.exitLabel(ExitNode.values.byName(exit)),
        if (proxyMode) 'Proxy',
      ].join(' · '),
      perAppMode: device.perAppMode.name,
      apps: device.perAppApps,
      mtu: device.mtu,
      appendHttpProxy: device.appendHttpProxy,
      proxyOnly: proxyMode,
      exit: exit,
      exitDirect: exitType != null,
      exitRegion: dnsMode ? '' : device.exitRegion,
      torBridge: mode == ConnectionMode.tor ? device.torBridge : null,
      torCustomBridges: profile.tor.bridges,
      psiphonConfig: exit == 'psiphon'
          ? XrayConfigBuilder.psiphonConfigFor(mode, device)
          : null,
      browserDialer:
          mode == ConnectionMode.worker &&
          variant == ConnectionVariant.browserDialer,
      verifyConnection: mode.verifiesConnection,
    );
  }

  bool renewingWarp = false;

  /// Registers a fresh WARP account.
  Future<void> renewWarpAccount() async {
    if (renewingWarp) return;
    renewingWarp = true;
    notifyListeners();
    try {
      final reg = await const WarpRegistrar().register();
      write('warp.account', reg.account.toJson());
      // Its endpoints: the v4 / v6 addresses Cloudflare offered, on each port (Best Ping picks).
      write('warp.endpoints', reg.endpoints);
    } on WarpException catch (e) {
      throw e.network ? NetworkStateError(e.message) : StateError(e.message);
    } finally {
      renewingWarp = false;
      notifyListeners();
    }
  }

  bool renewingMasque = false;

  /// Registers a fresh WARP account enrolled for MASQUE, like [renewWarpAccount].
  Future<void> renewMasqueAccount() async {
    if (renewingMasque) return;
    renewingMasque = true;
    notifyListeners();
    try {
      final reg = await const MasqueRegistrar().register();
      write('masque.account', reg.account.toJson());
      write('masque.endpoints', reg.endpoints);
    } on MasqueException catch (e) {
      throw e.network ? NetworkStateError(e.message) : StateError(e.message);
    } finally {
      renewingMasque = false;
      notifyListeners();
    }
  }

  /// Checks GitHub for a newer release: through the tunnel when connected (release downloads
  /// may be slow or blocked otherwise). Null when this is the latest.
  Future<AppUpdate?> checkForUpdate() async {
    final info = await VpnChannel.appInfo();
    final client = proxiedClient(isConnected ? LocalProxy.port : null);
    try {
      return await UpdateChecker(client)
          .check(installed: info.version, abis: info.abis);
    } on UpdateException catch (e) {
      throw StateError(e.message);
    } finally {
      client.close();
    }
  }

  /// Replaces Xray's geo files with the latest Iran-v2ray-rules release's, through the tunnel
  /// when connected (like [checkForUpdate]). A running connection uses them once it reconnects.
  Future<void> updateGeoAssets() async {
    final client = proxiedClient(isConnected ? LocalProxy.port : null);
    try {
      await VpnChannel.saveGeoAssets(
        await GeoAssetsDownloader(client).download(),
      );
    } on GeoAssetsException catch (e) {
      throw StateError(e.message);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? "Couldn't save the geo assets");
    } finally {
      client.close();
    }
  }

  /// Gets bridges of [transports] from Tor Project (Moat). Goes through the tunnel when
  /// connected, since bridges.torproject.org is often filtered.
  Future<List<String>> fetchTorBridges(List<String> transports) async {
    try {
      return await TorBridgeFetcher(
        proxyPort: isConnected ? LocalProxy.port : null,
      ).fetch(transports);
    } on TorBridgesException catch (e) {
      throw StateError(
        isConnected
            ? e.message
            : '${e.message}. Connect first, then try again.',
      );
    }
  }

  /// Adds [lines] to the custom bridges, skipping ones already there; returns how many were added.
  int installTorBridges(List<String> lines) {
    final current = profile.tor.bridges;
    final added = lines.where((l) => !current.contains(l)).toSet().toList();
    if (added.isNotEmpty) write('tor.bridges', [...current, ...added]);
    return added.length;
  }

  /// Adds scan results to the selected protocol's existing endpoint setting.
  int installScannedIPs(List<String> ips, {required String protocol, required int port}) {
    final path = switch (protocol) {
      'vless' => 'vless.cleanIps',
      'warp' => 'warp.endpoints',
      'masque' => 'masque.endpoints',
      _ => throw ArgumentError.value(protocol, 'protocol'),
    };
    final current = readList(path);
    final values = ips.map((ip) {
      if (protocol == 'vless') return ip;
      return ip.contains(':') ? '[$ip]:$port' : '$ip:$port';
    });
    final added = values.where((value) => !current.contains(value)).toSet().toList();
    if (added.isNotEmpty) write(path, [...current, ...added]);
    return added.length;
  }

  Future<void> testPing() async {
    if (!isConnected || pinging) return;
    pinging = true;
    notifyListeners();
    try {
      pingMs = await VpnChannel.measureDelay();
      if (isConnected) _sessionPing = pingMs;
    } catch (_) {
      pingMs = -1;
    }
    pinging = false;
    notifyListeners();
  }

  /// Looks up the exit IPs through the tunnel (panel's "My IP").
  Future<void> refreshMyIps() async {
    if (!isConnected || loadingIps) return;
    loadingIps = true;
    notifyListeners();
    try {
      myIps = await fetchMyIps(proxyPort: LocalProxy.port);
    } finally {
      loadingIps = false;
      if (!isConnected) myIps = null;
      notifyListeners();
    }
  }

  /// The LAN address can change (Wi-Fi switch, hotspot on/off), so it's re-checked often.
  Future<void> refreshLanIp() async {
    final ip = await lanIPv4();
    if (ip == lanIp) return;
    lanIp = ip;
    notifyListeners();
  }

  // endregion

  // region Cloudflare API access

  /// Runs [action] with the API (routing and fallbacks are [CloudflareClient]'s).
  Future<T> _withApi<T>(
    String token,
    Future<T> Function(CloudflareApi api) action,
  ) async {
    final api = CloudflareApi(token);
    try {
      return await action(api);
    } finally {
      api.close();
    }
  }

  /// [_withApi], with Cloudflare's errors as [StateError]s for the UI.
  Future<T> _cf<T>(
    String token,
    Future<T> Function(CloudflareApi api) action,
  ) async {
    try {
      return await _withApi(token, action);
    } on CloudflareException catch (e) {
      throw StateError(e.message);
    }
  }

  // endregion

  // region deployments

  final _deploying = <String>{};
  final _deployAgain = <String>{};

  /// Why a deployment's last redeploy failed, by [deploymentKey].
  final deployErrors = <String, String>{};

  bool isDeploying(SavedCfAccount a, Deployment d) =>
      _deploying.contains(deploymentKey(a, d));

  /// A newer worker script than [d]'s is bundled.
  static bool updateAvailable(Deployment d) =>
      d.version < CloudflareApi.workerVersion;

  ({SavedCfAccount account, Deployment deployment})? _find(
    String accountId,
    WorkerType type,
  ) {
    final a = cfAccounts.where((a) => a.id == accountId).firstOrNull;
    final d = a?.deployment(type);
    return a == null || d == null ? null : (account: a, deployment: d);
  }

  /// Replaces [d] (by type) in [account] and saves.
  void _putDeployment(SavedCfAccount account, Deployment d) {
    final current = cfAccounts.where((a) => a.id == account.id).firstOrNull;
    if (current == null) return;
    unawaited(
      _saveAccounts([
        for (final a in cfAccounts)
          a.id == account.id ? current.withDeployment(d) : a,
      ]),
    );
  }

  /// Deploys the bundled script with the deployment's current ENV (also the script update).
  /// One at a time per deployment: a change while one runs deploys again after it.
  Future<void> redeploy(SavedCfAccount account, WorkerType type) async {
    final key = '${account.id}/${type.name}';
    if (!_deploying.add(key)) {
      _deployAgain.add(key);
      return;
    }
    deployErrors.remove(key);
    notifyListeners();
    try {
      do {
        _deployAgain.remove(key);
        final e = _find(account.id, type);
        if (e == null) break;
        final d = e.deployment;
        final env = CloudflareApi.encodeEnv(
          uuid: e.account.uuid,
          proxyIps: d.vless.proxyIps,
          fallbackUrl: d.vless.fallbackUrl ?? '',
        );
        final host = await _withApi(
          e.account.token,
          (api) => type == WorkerType.pages
              ? api.deployPages(e.account.id, d.name, env, create: false)
              : api.deployWorker(e.account.id, d.name, env),
        );
        final now = _find(account.id, type);
        if (now != null) {
          _putDeployment(
            now.account,
            now.deployment.copyWith(
              host: host,
              version: CloudflareApi.workerVersion,
              pending: _deployAgain.contains(key),
            ),
          );
        }
      } while (_deployAgain.contains(key));
    } catch (e) {
      _deployAgain.remove(key);
      deployErrors[key] = e is CloudflareException ? e.message : '$e';
    } finally {
      _deploying.remove(key);
      notifyListeners();
    }
  }

  /// Redeploys what's due: changes that didn't deploy, and scripts older than
  /// [CloudflareApi.minWorkerVersion] (e.g. the app installed again after a long while).
  void _redeployDue() {
    for (final e in deployments) {
      final d = e.deployment;
      if (d.pending || d.version < CloudflareApi.minWorkerVersion) {
        unawaited(redeploy(e.account, d.type));
      }
    }
  }

  // endregion

  // region usage

  /// Refreshes the 24-hour Workers request usage for the selected deployment's account.
  Future<void> refreshUsage() async {
    final s = selected, w = worker;
    if (s == null || w == null || loadingUsage) return;
    loadingUsage = true;
    usageError = null;
    notifyListeners();
    try {
      // Pages Functions are reported under the project name, like Workers scripts.
      usage = await _withApi(
        s.account.token,
        (api) => api.workerUsage(w.accountId, w.name),
      );
    } catch (e) {
      usageError = e is CloudflareException
          ? e.message
          : 'Could not load usage';
    } finally {
      loadingUsage = false;
      notifyListeners();
    }
  }

  // endregion

  // region worker

  /// Waits for the selected deployment to come online: a WebSocket handshake, as a VPN client
  /// would start one. New workers.dev / pages.dev hosts take a little while to go live.
  /// Returns false if it's still unreachable (~2 minutes).
  Future<bool> waitForWorkerOnline() async {
    final w = worker;
    if (w == null) return false;
    for (var i = 0; i < 40; i++) {
      try {
        final socket = await WebSocket.connect('wss://${w.host}/')
            .timeout(const Duration(seconds: 10));
        await socket.close();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    return false;
  }

  ({SavedCfAccount account, Deployment deployment}) _manageable() =>
      selected ??
      (throw StateError('No VPN worker yet. Add a Cloudflare account first.'));

  /// Routes [hostname] to the selected deployment in Cloudflare (replacing its previous one).
  Future<void> setCustomDomain(String hostname) async {
    final s = _manageable();
    final w = worker!;
    if (hostname == w.customDomain) return;
    await _cf(s.account.token, (api) async {
      if (w.customDomain != null) {
        await api.detachCustomDomain(w, w.customDomain!);
      }
      await api.attachCustomDomain(w, hostname);
    });
    _putDeployment(
      s.account,
      s.deployment.copyWith(customDomain: () => hostname),
    );
    _markChangedWhileConnected();
  }

  /// Detaches the selected deployment's custom domain in Cloudflare.
  Future<void> removeCustomDomain() async {
    final s = _manageable();
    final w = worker!;
    final domain = w.customDomain;
    if (domain == null) return;
    await _cf(s.account.token, (api) => api.detachCustomDomain(w, domain));
    _putDeployment(s.account, s.deployment.copyWith(customDomain: () => null));
    _markChangedWhileConnected();
  }

  // endregion

  // region Cloudflare accounts

  Future<void> _saveAccounts(List<SavedCfAccount> accounts) async {
    cfAccounts = accounts;
    _profile = null;
    notifyListeners();
    await _secrets.write(
      key: _kSecretAccounts,
      value: jsonEncode(cfAccounts.map((a) => a.toJson()).toList()),
    );
  }

  /// Checks [token]; returns it cleaned up, its user's email and the accounts it can access.
  Future<({String token, String email, List<CfAccount> accounts})> checkCfToken(
    String token,
  ) async {
    final CloudflareApi api;
    try {
      api = CloudflareApi(token);
    } on CloudflareException catch (e) {
      throw StateError(e.message);
    }
    try {
      final accounts = await api.accounts();
      if (accounts.isEmpty) {
        throw StateError('This token has no account access');
      }
      return (
        token: api.token,
        email: await api.userEmail(),
        accounts: accounts,
      );
    } on CloudflareException catch (e) {
      throw StateError(e.message);
    } finally {
      api.close();
    }
  }

  /// Deploys a fresh [type] worker in [accountId] with [uuid] in its ENV; nothing is saved (see
  /// [addCfAccount]). Through Network failures throw [NetworkStateError].
  Future<Deployment> deployFresh({
    required String token,
    required String accountId,
    required WorkerType type,
    required String uuid,
  }) async {
    final env = CloudflareApi.encodeEnv(
      uuid: uuid,
      proxyIps: const [],
      fallbackUrl: '',
    );
    final api = CloudflareApi(token);
    try {
      final name = await api.freeName(accountId, type);
      final host = type == WorkerType.pages
          ? await api.deployPages(accountId, name, env, create: true)
          : await api.deployWorker(accountId, name, env);
      return Deployment(
        type: type,
        name: name,
        host: host,
        version: CloudflareApi.workerVersion,
      );
    } on CloudflareException catch (e) {
      throw StateError(e.message);
    } catch (e) {
      if (isNetworkError(e)) {
        throw NetworkStateError("Can't reach Cloudflare: $e");
      }
      rethrow;
    } finally {
      api.close();
    }
  }

  /// Saves [account] once its Workers and Pages are both deployed, and selects it unless a usable
  /// deployment already is. Adding an account again replaces it: its earlier workers are deleted
  /// from Cloudflare (best effort).
  Future<void> addCfAccount({
    required String token,
    required String email,
    required CfAccount account,
    required String uuid,
    required List<Deployment> deployments,
  }) async {
    final earlier = cfAccounts.where((a) => a.id == account.id).firstOrNull;
    if (earlier != null) {
      await _deleteDeployments(earlier).catchError((_) {});
    }
    final saved = SavedCfAccount(
      id: account.id,
      name: account.name,
      token: token,
      email: email,
      uuid: uuid,
      deployments: [...deployments]
        ..sort((a, b) => a.type.index.compareTo(b.type.index)),
    );
    final wasUsable = selected != null && selected!.account.id != account.id;
    await _saveAccounts([
      ...cfAccounts.where((a) => a.id != account.id),
      saved,
    ]);
    if (!wasUsable) selectDeployment(saved, saved.deployments.first);
  }

  /// Deletes [deployments] of [accountId] from Cloudflare, custom domains first (see
  /// CloudflareApi.deleteDeployment). The setup wizard uses it for a half-deployed account it
  /// skips.
  Future<void> deleteFresh({
    required String token,
    required String accountId,
    required List<Deployment> deployments,
  }) async {
    final api = CloudflareApi(token);
    try {
      for (final d in deployments) {
        await api.deleteDeployment(
          ActiveWorker(
            accountId: accountId,
            name: d.name,
            type: d.type,
            host: d.host,
            customDomain: d.customDomain,
          ),
        );
      }
    } finally {
      api.close();
    }
  }

  Future<void> _deleteDeployments(SavedCfAccount account) =>
      _cf(account.token, (api) async {
        for (final d in account.deployments) {
          await api.deleteDeployment(
            ActiveWorker(
              accountId: account.id,
              name: d.name,
              type: d.type,
              host: d.host,
              customDomain: d.customDomain,
            ),
          );
        }
      });

  /// Removes the account: its custom domains and workers from Cloudflare, then the account from
  /// this device. With [cleanUp] false (Cloudflare couldn't be reached or refused), only the
  /// latter. Network failures throw [NetworkStateError].
  Future<void> removeCfAccount(
    SavedCfAccount account, {
    bool cleanUp = true,
  }) async {
    if (selected?.account.id == account.id &&
        status != VpnStatus.disconnected) {
      await disconnect();
    }
    if (cleanUp) {
      try {
        await _deleteDeployments(account);
      } on StateError {
        rethrow;
      } catch (e) {
        if (isNetworkError(e)) {
          throw NetworkStateError("Can't reach Cloudflare: $e");
        }
        rethrow;
      }
    }
    await _saveAccounts(cfAccounts.where((a) => a.id != account.id).toList());
  }

  // endregion
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Access without subscribing to rebuilds (for callbacks).
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
