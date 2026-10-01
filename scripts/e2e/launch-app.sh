#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PLATFORM="${1:-}"
ARTIFACT="${2:-}"

case "$PLATFORM" in
  android)
    APK="${ARTIFACT:-$REPOSITORY_ROOT/android/app/build/outputs/apk/release/app-release.apk}"
    if [[ ! -f "$APK" ]]; then
      echo "Android release APK not found: $APK" >&2
      exit 1
    fi

    adb install -r "$APK"
    adb shell am force-stop com.reactnativedemoapp
    adb shell am start -n com.reactnativedemoapp/.MainActivity
    echo "E2E_DEVICE_ID=$(adb get-serialno)"
    ;;
  ios)
    APP="${ARTIFACT:-$REPOSITORY_ROOT/ios/build/Build/Products/Release-iphonesimulator/ReactNativeDemoApp.app}"
    if [[ ! -d "$APP" ]]; then
      echo "iOS simulator app not found: $APP" >&2
      exit 1
    fi

    simulator="${IOS_SIMULATOR_UDID:-}"
    if [[ -z "$simulator" ]]; then
      simulator_count=$(
        xcrun simctl list devices booted -j |
          jq -r '[.devices[][] | select(.state == "Booted") | .udid] | length'
      )
      if [[ "$simulator_count" -eq 0 ]]; then
        echo "No booted iOS simulator found." >&2
        exit 1
      fi
      if [[ "$simulator_count" -gt 1 ]]; then
        echo "Multiple iOS simulators are booted; set IOS_SIMULATOR_UDID." >&2
        exit 1
      fi
      simulator=$(
        xcrun simctl list devices booted -j |
          jq -r '.devices[][] | select(.state == "Booted") | .udid'
      )
    fi

    xcrun simctl install "$simulator" "$APP"
    xcrun simctl launch \
      --terminate-running-process \
      "$simulator" \
      com.reactnativedemoapp
    echo "E2E_DEVICE_ID=$simulator"
    ;;
  *)
    echo "Usage: $0 <android|ios> [built-app-path]" >&2
    exit 1
    ;;
esac
