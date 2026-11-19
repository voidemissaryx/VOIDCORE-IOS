# VOIDCORE VPN — iOS Port

**One app. Multiple ways to stay connected.**

This is the iOS/iPadOS port of VOIDCORE VPN 1.3.1. The Flutter UI is shared
with the Android build; the native layer is rewritten in Swift on top of
Apple's Network Extension framework, with the same Xray-core engine
(gomobile `bind -target=ios`) driving the tunnel.

> Built for networks where ordinary connections may be restricted. Results
> depend on your network and configuration; no method can guarantee access
> everywhere.

---

## What's in this repo

| Folder | What it contains |
| --- | --- |
| `lib/` | Flutter UI and services (shared with the Android build) |
| `ios/Runner/` | Swift app code: `AppDelegate`, `VpnController`, the Flutter bridge, keychain, document picker |
| `ios/PacketTunnel/` | The `NEPacketTunnelProvider` extension that owns the live tunnel |
| `ios/Runner.xcodeproj/` | Xcode project with `Runner` and `PacketTunnel` targets |
| `ios/Flutter/` | `.xcconfig` build variables (bundle id, app group, team, Flutter build name) |
| `ios/Frameworks/` | Drop-in location for the built `Xray.xcframework` |
| `xray/` `psiphon/` `networking/` `scanner/` | Go source for the VPN engine (built by `scripts/build_xray_ios.sh`) |
| `scripts/` | Build scripts (`build_xray_ios.sh` is the iOS one) |
| `.github/workflows/ios-build.yml` | macOS CI workflow |
| `docs/IOS_SETUP.md` | Apple capabilities, signing, and build steps |
| `docs/IOS_FEATURES.md` | Implemented vs. unsupported features |

The Android build (`android/`, `scripts/build_xray.sh`, `.github/workflows/release.yml`)
is preserved unchanged.

---

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────┐
│ Flutter UI (lib/) — identical on Android and iOS              │
│   VpnChannel.start() → MethodChannel('bpb/core')             │
│   VpnChannel.states  ← EventChannel('bpb/state')              │
└──────────────────────────────┬──────────────────────────────┘
                               │ (same channel names on both OSes)
                ┌──────────────┴──────────────┐
                │ Android: MainActivity.kt     │   iOS: AppDelegate.swift
                │ + BpbVpnService              │   + VpnController (NETunnelProviderManager)
                │ + CoreManager (gomobile xray)│   + AppStatePoller (shared state.json)
                └──────────────┬──────────────┘   └───────────────┬─────────┘
                               │                                   │
                               ▼                                   ▼
        ┌──────────────────────────────┐         ┌─────────────────────────────────────┐
        │ android.net.VpnService       │         │ NEPacketTunnelProvider extension     │
        │ + ParcelFileDescriptor TUN   │         │ + NEPacketTunnelNetworkSettings       │
        │ + Xray reads TUN fd directly │         │ + Xray via Xray.xcframework (dlsym)  │
        └──────────────────────────────┘         └─────────────────────────────────────┘
```

The iOS extension and the Flutter app communicate through a **shared App Group
container** (`group.com.bpb.voidcore`). The Runner writes the pending
`VpnConfig` into `pending_config.json` before starting the tunnel; the
extension reads it in `startTunnel`. The extension writes `state.json`
whenever the connection state changes; the Runner polls it (500 ms) and
republishes on the `bpb/state` EventChannel. Sensitive secrets (Cloudflare
tokens, VLESS UUIDs, MITM CA keys) live in the iOS **Keychain**, shared with
the extension through the same App Group's keychain-access-groups entry.

The Xray-core engine is built once as `Xray.xcframework` (gomobile bind
`-target=ios -prefix=Xray`) and linked weakly into both targets. At runtime,
`XrayCoreProbe.swift` resolves the framework symbols through `dlsym`; if the
framework is missing (e.g. a local unsigned build before the binary is built),
every call returns a safe default and the VPN reports an actionable error
rather than crashing.

---

## Quick start (local build)

You need a Mac with Xcode 16+, the iOS 16 SDK, Go 1.26+, and Flutter 3.32+.

```bash
# 1. Resolve Flutter deps.
flutter pub get

# 2. Build the Xray engine for iOS (gomobile bind). Produces
#    ios/Frameworks/Xray.xcframework with device + simulator slices.
bash scripts/build_xray_ios.sh

# 3. Fetch routing data and Tor bridges (best-effort; the app still builds
#    without them).
bash scripts/fetch_geo.sh || true
bash scripts/fetch_tor_bridges.sh || true

# 4. Open the project and configure signing (set your team id in
#    ios/Flutter/Runner.xcconfig or Xcode's Signing & Capabilities tab).
open ios/Runner.xcodeproj

# 5. Build from Xcode (Cmd+R) or the command line:
flutter build ios --release --no-codesign    # unsigned
flutter build ipa --release                  # signed (requires profiles)
```

For full signing setup, see [`docs/IOS_SETUP.md`](docs/IOS_SETUP.md).

---

## CI

`.github/workflows/ios-build.yml` runs on every push to `main` and on PRs.
It installs Flutter + Go + Java on a `macos-15` runner, builds the
`Xray.xcframework`, runs `flutter analyze` and `flutter test`, then builds
the Packet Tunnel Extension and the app. When `APPLE_P12_BASE64`,
`APPLE_P12_PASSWORD`, `APPLE_PROVISION_PROFILE_BASE64`, and
`APPLE_PROVISION_PROFILE_EXT_BASE64` secrets are set, it produces a signed
IPA; otherwise it ships an unsigned `.app` ZIP.

Tagging a release (`git tag v1.3.1 && git push origin v1.3.1`) creates a
GitHub Release with the signed IPA and SHA-256 checksums.

---

## Minimum iOS target

iOS 16.0 / iPadOS 16.0. This is the oldest version current Flutter (3.32+)
supports, and it gives us the modern Network Extension API surface plus
BGTaskScheduler for background refreshes. The deployment target is set in
`ios/Flutter/Debug.xcconfig` and `Release.xcconfig` and applied to both
targets.

---

## License

GNU GPL v3.0 — see [`LICENSE`](LICENSE).
