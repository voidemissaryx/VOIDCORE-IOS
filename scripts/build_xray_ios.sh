#!/usr/bin/env bash
# Builds the Xray core (xray/: Xray-core + a small API around it) for iOS using
# gomobile bind, producing ios/Frameworks/Xray.xcframework. The framework is
# then linked into both the Runner app and the PacketTunnel extension through
# the project's FRAMEWORK_SEARCH_PATHS and -weak_framework Xray linker flags.
#
# This is the iOS counterpart of scripts/build_xray.sh (which targets Android).
# It must run on a Mac with Xcode, Go, and the iOS SDK installed.
#
# Usage:
#   scripts/build_xray_ios.sh            # builds device + simulator slices
#   scripts/build_xray_ios.sh device      # device slice only
#   scripts/build_xray_ios.sh simulator   # simulator slice only
#
# The produced Xray.xcframework exposes the same Go entry points as the
# Android xray.aar:
#   - XrayVersion() -> String
#   - XrayInitEnv(dir: String)
#   - XrayStartEchGateway() -> String
#   - XrayCheckDNSJSON(json: String) -> String
#   - XrayNewController() -> *Controller
#   - (*Controller) Start / Stop / IsRunning / OutboundTraffic / MeasureDelay
#
# The Swift bridge imports these generated declarations from the Xray module.
# Keep the gomobile prefix unset: the Go package is already named "xray", and
# adding -prefix=Xray duplicates the generated Objective-C/Swift symbol prefix.
set -euo pipefail

cd "$(dirname "$0")/../xray"
ROOT_DIR="$(pwd)"
OUT="../ios/Frameworks/Xray.xcframework"

# The package name supplies the Xray symbol namespace. Do not add -prefix here.
export GOBIN="$PWD/.bin"
export PATH="$GOBIN:$PATH"

# Required by gomobile bind -target=ios.
: "${XCODE_DEVELOPER_PATH:=$(xcode-select -p)}"
export DEVELOPER_DIR="$XCODE_DEVELOPER_PATH"

# Install gomobile/gobind at the version pinned in go.mod.
go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
gomobile init

TARGETS="${1:-ios,iossimulator}"
case "$TARGETS" in
  device)   GO_TARGET="ios" ;;
  simulator) GO_TARGET="iossimulator" ;;
  *)        GO_TARGET="ios,iossimulator" ;;
esac

mkdir -p "$(dirname "$OUT")"

# gomobile bind -target=ios produces an .xcframework directly.
# -trimpath -ldflags "-s -w": strip paths and debug info for a smaller binary.
# Leaving -prefix unset produces the XrayVersion/XrayNewController symbols
# consumed by ios/Runner/XrayCoreBridge.swift.
# -checklinkname=0: matches the Android build (anet links into net internals).
gomobile bind \
  -target="$GO_TARGET" \
  -trimpath \
  -ldflags "-s -w -buildid= -checklinkname=0" \
  -o "$OUT" \
  .

rm -rf "${OUT%.xcframework}-sources.jar"

go version
echo "Built: $OUT"
ls -la "$OUT"
