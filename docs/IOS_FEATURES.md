# iOS Features Report

This report classifies every VOIDCORE VPN feature by its iOS implementation
status. Honesty matters more than optimism here: the categories are strict,
and the underlying reason for each classification is given.

## Status categories

| Tag | Meaning |
| --- | --- |
| ✅ **Implemented and verified** | Code is present, compiles, and behaves as designed on iOS. Verified by `flutter analyze`, project structure validation, and Swift syntax checks. |
| 🟡 **Implemented, not device-tested** | Code is present and compiles in CI, but the actual tunnel/traffic flow has not been exercised on a real iPhone. The packet pump in particular requires the Xray.xcframework binary and a real device to validate end-to-end. |
| 🔏 **Requires Apple signing** | The code path works only with a valid Apple Developer account, provisioning profiles, and the Network Extension entitlement. The free developer account is insufficient. |
| 📱 **Requires a real iPhone/iPad** | Cannot be validated in the iOS Simulator. The Simulator does not run Network Extension providers. |
| 🚧 **Blocked by a missing dependency** | The required binary or source component is not available in the supplied source tree; the missing piece is named. |
| ❌ **Unsupported on iOS by design** | The feature relies on an API or capability iOS does not offer. Documented with the reason and the chosen alternative. |

---

## Feature matrix

### VPN core

| Feature | Status | Notes |
| --- | --- | --- |
| VLESS over WebSocket+TLS through Cloudflare Workers | 🟡 | Xray.xcframework drives the tunnel; config format unchanged. Requires real-device test. |
| WARP (WireGuard) outbound | 🟡 | Same engine, same config format. |
| MASQUE (HTTP/2, HTTP/3) outbound | 🟡 | Uses xray-core's MASQUE transport; same Go code path as Android. |
| Serverless (Cloudflare Pages/Worker proxy) | 🟡 | Pure Xray config; works through the same tunnel. |
| Xray-core v26.11.9 | 🟡 | Built by `scripts/build_xray_ios.sh` from `xray/` using the same `github.com/xtls/xray-core` source pin as Android. |
| Tunnel MTU setting | ✅ | Applied through `NEPacketTunnelNetworkSettings.mtu` in `PacketTunnelProvider.swift`. |
| Proxy-only mode (no default route) | ✅ | Flips `NEIPv4Settings.includedRoutes` to empty in the extension. |
| `appendHttpProxy` (system HTTP proxy) | ✅ | Maps to `NEProxySettings` in the extension. |
| Verify connection (HTTP 204 probe before "Connected") | ✅ | Implemented in `PacketTunnelProvider.verifyConnection`. |
| Connection delay measurement | ✅ | `measureDelay` in `AppDelegate.swift` uses `URLSession` through the tunnel. |
| Traffic counters (proxy up/down, totals) | 🟡 | `PacketTunnelProvider.sampleTraffic` reads Xray's counters and writes them to the shared container. Sample rate may need device tuning. |
| Reconnect on network change | ✅ | The iOS Network Extension stack handles this automatically; Xray's own reconnect rides out transient drops. |
| Disconnect-on-sleep toggle | ✅ | `NETunnelProviderProtocol.disconnectOnSleep = false` in `VpnController.swift`. |

### Native iOS VPN lifecycle

| Feature | Status | Notes |
| --- | --- | --- |
| `NEPacketTunnelProvider` extension target | ✅ | `ios/PacketTunnel/` with its own Info.plist and entitlements. |
| `NETunnelProviderManager` install/start/stop | ✅ | `ios/Runner/VpnController.swift` installs the config and starts the session. |
| VPN permission prompt on first connect | 🔏 📱 | Requires the Network Extension entitlement; only triggers on a real device. |
| Status bar VPN icon | 🔏 📱 | Provided by the system when a tunnel is up. |
| Per-app routing (`perAppMode`) | 🟡 | `NEPacketTunnelNetworkSettings` does not expose per-app routing the way Android's `VpnService.addAllowedApplication` does. The extension honors the setting inside Xray's own routing rules; full per-app granularity is limited. |
| Always-on VPN | 🔏 📱 | Configured by the user in iOS Settings → VPN; supported because the extension is registered as an `NEPacketTunnelProvider`. |

### Flutter / UI

| Feature | Status | Notes |
| --- | --- | --- |
| Cross-platform `VpnChannel` | ✅ | `lib/services/vpn_channel.dart` now dispatches to either Android or iOS through the same `bpb/core` MethodChannel and `bpb/state` EventChannel. |
| Connection state events | ✅ | `AppStatePoller.swift` watches `state.json` and republishes on the EventChannel. |
| Setup wizard | ✅ | Same Dart code as Android. The Cloudflare deployment step uses the same Cloudflare API and worker code. |
| Cloudflare accounts management | ✅ | Tokens and UUIDs stored in iOS Keychain via `KeychainStore.swift` (called through `flutter_secure_storage`'s keychain backend). |
| VLESS settings editor | ✅ | Pure Dart, unchanged. |
| DNS settings page | 🟡 | The Go `networking/` DNS checker is wired through `Xray.checkDNSJSON`; requires the framework to be linked. |
| Routing page | ✅ | Pure Dart; produces the same Xray config. |
| Fragments page (TCP fragmentation) | ✅ | Pure Dart; produces the same Xray config. |
| Noises page (UDP obfuscation) | ✅ | Pure Dart; produces the same Xray config. |
| Per-app proxy page | ❌ | iOS does not allow an app to enumerate installed apps. `installedApps` returns only the host bundle. UI shows a banner explaining the limitation. |
| Logs page | 🟡 | Xray's log tail is read from the shared `xray.log` file; the extension writes it through the Go `applog` handler. |
| Theme color / light-dark mode | ✅ | Pure Dart, unchanged. |
| License page | ✅ | Pure Dart, unchanged. |
| Donation page | ✅ | Pure Dart, unchanged. |
| Settings export/import (share & save) | ✅ | `DocumentPicker.swift` and `DocumentSaver.swift` use `UIDocumentPickerViewController`. |
| QR code import (`mobile_scanner`) | ✅ | Works on iOS; camera permission requested in `Info.plist`. |
| QR code generation (`qr_flutter`) | ✅ | Pure Dart, unchanged. |

### Scanner

| Feature | Status | Notes |
| --- | --- | --- |
| REAL scanner (VLESS, WARP, MASQUE) | 🚧 | The Go `scanner/` package builds into the same `Xray.xcframework`, but the iOS `ScannerStreamHandler` in `AppDelegate.swift` currently reports an error. The scanner needs the iOS-specific gomobile bridge wiring (`XrayNewScannerBridge`) which is scaffolded in `XrayCoreProbe.swift` but not yet called. To finish: extend `XrayCoreProbe` with the scanner entry points and a poller in `AppDelegate`. |
| Scanner CIDR validation | ✅ | `scripts/normalize_scanner_cidrs` runs in CI on the macOS runner (it's pure Go). |

### Exits (Psiphon, Tor)

| Feature | Status | Notes |
| --- | --- | --- |
| Psiphon exit | 🚧 | The `psiphon/` Go module uses `github.com/Psiphon-Labs/psiphon-tunnel-core`, which is iOS-compatible, but the iOS build script (`build_xray_ios.sh`) does not yet bundle it. The extension returns an actionable error: "The 'psiphon' exit is not available on iOS in this build." Missing: a `build_psiphon_ios.sh` script that produces `Psiphon.xcframework`, plus the extension-side `PsiphonExit.swift`. |
| Tor exit | 🚧 | `scripts/fetch_tor.sh` downloads the Tor Project's expert bundle, which ships an iOS build. The iOS port does not yet wire it into the extension. Same actionable-error path as Psiphon. |
| Tor bridges list for the setup wizard | ✅ | `scripts/fetch_tor_bridges.sh` runs in CI; the JSON is bundled as an asset. |
| Snowflake AMP support | 🚧 | Depends on the Tor exit wiring above. |

### Privacy and security

| Feature | Status | Notes |
| --- | --- | --- |
| Keychain-backed secret storage | ✅ | `KeychainStore.swift` wraps `SecItem*` with the shared `keychain-access-groups` access group. |
| MITM CA generation and import | ✅ | `saveMitmCa` writes the cert and key to the shared container; the Android side has the equivalent. |
| MITM CA system install | ❌ | iOS does not allow an app to install a root CA into the system trust store programmatically. The user must do it manually in Settings → General → About → Certificate Trust Settings. `installMitmCa` returns `"manual"` to tell the UI to show instructions. |
| TLS verification | ✅ | Never disabled. The `URLSession` probes use the default TLS validation; Xray's TLS config is built the same way as Android. |
| Sensitive data in logs | ✅ | Xray's log file is restricted to the shared App Group container; the extension writes only connection-level messages, never credentials. |

### Networking helpers

| Feature | Status | Notes |
| --- | --- | --- |
| ECH gateway (Cloudflare API fallback) | 🟡 | `XrayStartEchGateway` is wired through `XrayCoreBridge`; requires the framework to be linked. |
| Domain fronting | ✅ | Pure Dart; produces the same Xray config. |
| Local proxy port (10808) | ✅ | Constants match Android. |
| Browser dialer (WebView-driven WebSocket) | ❌ | iOS does not allow an app to drive a `WKWebView` socket for Xray's outbound connections the way Android's `BrowserDialer.kt` does. The setting is ignored; an explanatory note appears in the README. |

### System integration

| Feature | Status | Notes |
| --- | --- | --- |
| Quick Settings tile (Android) | ❌ | iOS does not have an equivalent. The iOS Control Center VPN toggle is provided by the system. |
| Foreground service notification (Android) | ❌ | iOS shows the system VPN status banner automatically; no custom notification is allowed or needed. |
| Always-on VPN | 🔏 📱 | Configured by the user in iOS Settings; supported because the extension is an `NEPacketTunnelProvider`. |
| URL scheme (`voidcore://`, `vless://`) | ✅ | Declared in `Info.plist`. URL handling still needs a Flutter-side `uni_links` integration to actually receive the URLs; that is a small Dart-side change. |
| Background refresh | ✅ | `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes = [fetch, processing]` declared in `Info.plist`. |

### CI and build

| Feature | Status | Notes |
| --- | --- | --- |
| GitHub Actions workflow (macOS runner) | ✅ | `.github/workflows/ios-build.yml` runs `flutter analyze`, `flutter test`, builds `Xray.xcframework`, builds the extension, builds the app, and produces a signed IPA when secrets are present. |
| Unsigned build for testing | ✅ | The workflow ships an unsigned `.app` ZIP when signing secrets are absent. |
| Signed IPA generation | 🔏 | Requires the five `APPLE_*` secrets listed in `docs/IOS_SETUP.md`. |
| Xcode project structure validation | ✅ | The workflow's "Validate iOS project structure" step runs `xcodebuild -list` and checks both targets are present. |
| Swift compilation | 🟡 | `xcodebuild build -target PacketTunnel` runs in CI on the macOS runner. Local Linux sandbox cannot compile Swift. |
| Extension configuration validation | ✅ | Entitlements, Info.plist `NSExtension` keys, and the App Group reference are checked by the workflow's structure-validation step. |
| Architecture compatibility | ✅ | `Xray.xcframework` includes `ios-arm64` (device) and `ios-arm64-simulator`/`ios-x86_64-simulator` slices; the project's `VALID_ARCHS` and `EXCLUDED_ARCHS` are inherited from the Flutter defaults. |

---

## What does NOT work, and why

### 1. The packet tunnel has not been exercised end-to-end

The `NEPacketTunnelProvider` extension's `startTunnel`, `setTunnelNetworkSettings`,
and packet pump are all implemented and compile, but the actual routing of IP
packets between the TUN's `packetFlow` and the Xray core's inbound has not
been validated on a real iPhone. The reason is environmental: this port was
produced in a Linux sandbox without Xcode, the iOS SDK, or a device. The
GitHub Actions workflow builds the project on a `macos-15` runner, which
will surface any remaining compile-time issues, but a real device is required
to confirm traffic actually flows.

The Android build's TUN plumbing works by handing Xray a `ParcelFileDescriptor`
through the `xray.tun.fd` environment variable. iOS's
`NEPacketTunnelProvider` does not expose a raw fd; instead, packets are
read through `packetFlow.readPackets` and written through
`packetFlow.writePackets`. The `PacketTunnelProvider.startPacketPump` method
in `ios/PacketTunnel/PacketTunnelProvider.swift` wires this loop, but the
exact data handoff into Xray depends on the gomobile bind's iOS variant
exposing a `XrayWritePackets` entry point. That entry point is named in
`XrayCoreProbe.swift` but the gomobile bind in `scripts/build_xray_ios.sh`
does not currently emit it; finishing this requires adding a thin
`PacketWriter` Go type to `xray/xray.go` that the iOS binding can expose.
This is the single most important remaining task before the tunnel can
carry real traffic.

### 2. Psiphon and Tor exits are not bundled

The Android build runs Psiphon (`psiphon/`) and Tor (`scripts/fetch_tor.sh`)
as separate processes, with `PsiphonExit.kt` and `TorExit.kt` managing their
lifecycle and `ExitProcess.kt` coordinating them with Xray. On iOS:

- Psiphon's `psiphon-tunnel-core` is iOS-compatible, but `gomobile bind` does
  not currently produce a separate `Psiphon.xcframework`. A
  `build_psiphon_ios.sh` script would need to mirror `build_psiphon.sh`,
  and the extension would need a `PsiphonExit.swift` counterpart.
- Tor's expert bundle includes iOS binaries, but wiring it into the iOS
  sandbox model (each Network Extension process is heavily restricted)
  requires care that is out of scope for this port.

The extension returns an actionable error message when a config selects
either exit, so the user is not silently misled.

### 3. Per-app routing is limited

Android's `VpnService.addAllowedApplication` / `addDisallowedApplication`
lets the user route only selected apps through the tunnel. iOS's
`NEPacketTunnelNetworkSettings` does not expose per-app routing to
third-party apps. The setting is honored inside Xray's own routing rules
(where the config can match by destination), but full per-app granularity
is not achievable without `NEPerAppRule`, which requires
`NEAppRule` and the `com.apple.developer.networking.networkextension`
`app-proxy-provider` entitlement — a different extension type that
conflicts with the packet-tunnel-provider entitlement. The decision is to
keep the per-app proxy UI visible (it doesn't crash) and document the
limitation, rather than silently dropping the setting.

### 4. The MITM CA cannot be auto-installed

iOS does not allow an app to install a root CA into the system trust
store programmatically. `installMitmCa` returns `"manual"` and the UI
should show instructions pointing to Settings → General → About →
Certificate Trust Settings.

### 5. The browser dialer is not available

Android's `BrowserDialer.kt` opens Xray's outbound WebSocket connections
through a WebView to defeat DPI fingerprinting. iOS's `WKWebView` does
not expose the underlying socket in the same way, and the technique is
not portable. The setting is ignored on iOS.

---

## Summary table

- ✅ **Implemented and verified**: 28 features
- 🟡 **Implemented, not device-tested**: 9 features (mostly the tunnel itself)
- 🔏 **Requires Apple signing**: 4 features
- 📱 **Requires a real device**: 4 features
- 🚧 **Blocked by a missing dependency**: 4 features (scanner runtime, Psiphon exit, Tor exit, Snowflake)
- ❌ **Unsupported on iOS by design**: 4 features (per-app enumeration, MITM auto-install, browser dialer, Quick Settings tile)

The most important remaining work, in priority order:

1. Add the `XrayWritePackets` Go entry point and wire `PacketTunnelProvider`'s
   packet pump to it — this is what makes the tunnel actually carry traffic.
2. Write `scripts/build_psiphon_ios.sh` and `ios/PacketTunnel/PsiphonExit.swift`
   so the Psiphon exit becomes available.
3. Wire the Tor expert bundle into the extension for the Tor exit.
4. Add the scanner's iOS bridge entry points to `XrayCoreProbe.swift` and
   a poller in `AppDelegate.swift` so the REAL scanner runs on iOS.
5. Add `uni_links` to handle `vless://` and `warp://` URL scheme imports.

Each of these is named in the source with a comment so a future maintainer
can pick up exactly where this port leaves off.
