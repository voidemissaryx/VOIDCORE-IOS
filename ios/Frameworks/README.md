# ios/Frameworks

This folder holds `Xray.xcframework`, the iOS build of the Xray-core VPN engine.

The framework is NOT checked into git (it is too large and platform-specific).
Build it locally with:

    bash scripts/build_xray_ios.sh

or let the GitHub Actions workflow (`ios-build.yml`) build it on the macOS
runner before the Xcode build step.

The Runner and PacketTunnel targets reference this folder through
`FRAMEWORK_SEARCH_PATHS = $(PROJECT_DIR)/Frameworks` and link the framework
weakly (`-weak_framework Xray`), so the project builds even before the
framework is present. At runtime, `XrayCoreProbe.swift` resolves the framework
symbols through `dlsym`; when the framework is missing, every call returns a
sensible default and the VPN reports an actionable error rather than crashing.
