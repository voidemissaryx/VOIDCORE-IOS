# iOS Setup Guide

This document walks through the Apple Developer Portal setup, Xcode
capabilities, signing, and the full build process for VOIDCORE VPN on iOS.

---

## 1. Apple Developer Portal prerequisites

VOIDCORE VPN uses the **Network Extension** capability, which requires a paid
Apple Developer account (the free account cannot sign Network Extension
binaries).

Log in to <https://developer.apple.com/account> and create the following
identifiers, groups, and profiles:

### 1.1 App ID

1. **Certificates, Identifiers & Profiles → Identifiers → App IDs → +**
2. Description: `VOIDCORE VPN`
3. Bundle ID: `com.bpb.voidcore` (explicit)
4. Capabilities to enable:
   - **Network Extensions** (the Packet Tunnel entitlement)
   - **App Groups** (so the Runner and extension can share files)
   - **Keychain Sharing** (so both targets can read the same keychain items)
   - **Associated Domains** (only if you will host an app-site association file)

### 1.2 App Extension App ID

1. Create a second App ID with bundle ID `com.bpb.voidcore.PacketTunnel`.
2. Enable **Network Extensions** and **App Groups** (same group as above).

### 1.3 App Group

1. **Identifiers → App Groups → +**
2. Identifier: `group.com.bpb.voidcore`
3. Description: `VOIDCORE VPN shared container`
4. Edit both App IDs from §1.1 and §1.2 and add this App Group to each.

### 1.4 Provisioning profiles

Create one profile per App ID, per environment:

- `VOIDCORE Runner (Development)` — for `com.bpb.voidcore`, development cert
- `VOIDCORE Runner (Distribution)` — for `com.bpb.voidcore`, distribution cert
- `VOIDCORE PacketTunnel (Development)` — for `com.bpb.voidcore.PacketTunnel`
- `VOIDCORE PacketTunnel (Distribution)` — for `com.bpb.voidcore.PacketTunnel`

Download each `.mobileprovision` file. You'll need them for both local builds
and the CI workflow.

---

## 2. Required Apple capabilities and entitlements

Each target carries its own entitlements file:

| Entitlement | Runner | PacketTunnel | Why |
| --- | :-: | :-: | --- |
| `com.apple.security.application-groups` | ✅ | ✅ | Shared `group.com.bpb.voidcore` container |
| `keychain-access-groups` | ✅ | ✅ | Shared keychain for tokens, UUIDs, MITM CA key |
| `com.apple.developer.networking.networkextension` = `[packet-tunnel-provider]` | ✅ | ✅ | Installs a packet-tunnel VPN config |
| `com.apple.developer.networking.HotspotConfiguration` | ✅ | — | Optional, for the future Wi-Fi scan feature |

The Runner's entitlements files are `ios/Runner/Runner.entitlements`,
`ios/Runner/Debug.entitlements`, and `ios/Runner/Release.entitlements`. The
Packet Tunnel's is `ios/PacketTunnel/PacketTunnel.entitlements`. The
`application-groups` and `keychain-access-groups` arrays use
`$(CUSTOM_APP_GROUP)`, which resolves to `group.com.bpb.voidcore` from
`ios/Flutter/Runner.xcconfig`.

### Required Info.plist keys

| Key | Value | Why |
| --- | --- | --- |
| `NSCameraUsageDescription` | "VOIDCORE uses the camera to scan QR codes and import VPN configurations." | `mobile_scanner` requires it |
| `NSPhotoLibraryUsageDescription` | "VOIDCORE needs photo library access to import VPN configuration files from images." | QR code import from images |
| `NSLocalNetworkUsageDescription` | "VOIDCORE scans the local network for reachable Cloudflare and WARP endpoints." | Scanner feature |
| `ITSAppUsesNonExemptEncryption` | `false` | The app uses only standard HTTPS/TLS, so it is exempt from the export encryption question |
| `UIBackgroundModes` | `[fetch, processing]` | Keepalive for VPN status notifications |
| `BGTaskSchedulerPermittedIdentifiers` | `[com.bpb.voidcore.refresh]` | Background refresh task id |

---

## 3. Local build setup

### 3.1 Install tools

```bash
brew install go
brew install --cask flutter
# Xcode 16+ from the App Store, then:
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version  # verify
```

### 3.2 Configure signing variables

Edit `ios/Flutter/Runner.xcconfig`:

```
APP_BUNDLE_IDENTIFIER = com.bpb.voidcore
APP_GROUP_IDENTIFIER = group.com.bpb.voidcore
DEVELOPMENT_TEAM = ABCDE12345          # your team id from developer.apple.com
```

Or, to keep secrets out of git, create `ios/Flutter/Runner.local.xcconfig`
(it is included via `#include?` and is gitignored):

```
DEVELOPMENT_TEAM = ABCDE12345
```

### 3.3 Build the Xray engine

```bash
bash scripts/build_xray_ios.sh
```

This runs `gomobile bind -target=ios,iossimulator -prefix=Xray` and drops
`Xray.xcframework` into `ios/Frameworks/`. The project links the framework
weakly, so it will still build (and run in a degraded mode) before this
step is run, but the tunnel won't carry traffic until the framework is present.

### 3.4 Build the app

```bash
flutter pub get
flutter build ios --release --no-codesign    # unsigned, for simulator-only testing
flutter build ipa --release                  # signed, for TestFlight / App Store
```

Or open `ios/Runner.xcodeproj` in Xcode, pick the `Runner` scheme, select
your device, and press Cmd+R.

---

## 4. Configuring Apple signing

### 4.1 Manual signing (recommended for local development)

1. In Xcode, select the **Runner** target → **Signing & Capabilities**.
2. Check **Automatically manage signing**.
3. Select your team. Xcode will match the App ID and create a development
   provisioning profile automatically.
4. Repeat for the **PacketTunnel** target.

If you see "No profiles for 'com.bpb.voidcore.PacketTunnel' were found",
make sure you created the App Extension App ID (§1.2) first.

### 4.2 Manual signing with explicit profiles

For CI you want explicit profiles, not automatic. Uncheck "Automatically
manage signing" in Xcode, then for each target pick:

- **Runner → Debug**: VOIDCORE Runner (Development)
- **Runner → Release**: VOIDCORE Runner (Distribution)
- **PacketTunnel → Debug**: VOIDCORE PacketTunnel (Development)
- **PacketTunnel → Release**: VOIDCORE PacketTunnel (Distribution)

### 4.3 CI signing

In your GitHub repository → **Settings → Secrets and variables → Actions**,
add:

| Secret | What it holds |
| --- | --- |
| `APPLE_DEVELOPMENT_TEAM` | Your 10-character team id |
| `APPLE_P12_BASE64` | Your distribution certificate (.p12), base64-encoded |
| `APPLE_P12_PASSWORD` | The .p12 export password |
| `APPLE_PROVISION_PROFILE_BASE64` | `Runner.mobileprovision`, base64-encoded |
| `APPLE_PROVISION_PROFILE_EXT_BASE64` | `PacketTunnel.mobileprovision`, base64-encoded |

Encode a file with:

```bash
base64 -i distribution.p12 | pbcopy
base64 -i Runner.mobileprovision | pbcopy
```

The workflow (`ios-build.yml`) imports the .p12 into a temporary keychain
and drops both profiles into `~/Library/MobileDevice/Provisioning Profiles/`
before the build, then cleans up afterwards. Secrets are never printed.

---

## 5. First-run on device

1. Install the app on a real iPhone or iPad (the simulator cannot run a
   Network Extension).
2. On first connect, iOS shows the **"VOIDCORE VPN" Would Like to Add VPN
   Configurations** dialog. Tap **Allow**.
3. Authenticate with Face ID / Touch ID / passcode when prompted.
4. The VPN icon appears in the status bar; the home screen shows **Connected**.

If the connection doesn't come up, check **Settings → VPN → VOIDCORE VPN**
to confirm the configuration was installed. If the toggle is off, the system
may have removed the profile because the extension failed to start — check
the device console (Window → Devices and Simulators → Open Console) for
messages tagged `com.bpb.voidcore.tunnel`.

---

## 6. App Store submission notes

- VOIDCORE VPN uses the Network Extension capability. Apple reviews apps with
  this capability carefully; expect a request for a screencast demonstrating
  the VPN functionality and a justification of the entitlement.
- The `ITSAppUsesNonExemptEncryption` key is set to `false` because the app
  uses only standard HTTPS/TLS through system frameworks. If you add a custom
  crypto routine (e.g. for the chain-proxy WireGuard support), re-evaluate.
- Privacy policy: required because the app processes user data (configuration
  files, QR codes). Link it from the App Store Connect record.
- The Packet Tunnel Extension's `CFBundleShortVersionString` is `1.3.1` and
  `CFBundleVersion` is `3`; keep these in sync with `pubspec.yaml`'s
  `version: 1.3.1+3` on every release.
