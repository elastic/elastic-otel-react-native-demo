#!/usr/bin/env bash
# Copyright Elastic Technologies Inc. and/or licensed to
# Elastic Technologies Inc. under one or more contributor license
# agreements. See the NOTICE file distributed with this work for
# additional information regarding copyright ownership.
# Elastic Technologies Inc. licenses this file to you under the Apache
# License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


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
    # The app exports OTLP to localhost:4318; forward it to the host collector.
    adb reverse tcp:4318 tcp:4318
    adb shell am force-stop co.elastic.edot.reactnative.demo
    adb shell am start -n co.elastic.edot.reactnative.demo/com.reactnativedemoapp.MainActivity
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
      co.elastic.edot.reactnative.demo
    echo "E2E_DEVICE_ID=$simulator"
    ;;
  *)
    echo "Usage: $0 <android|ios> [built-app-path]" >&2
    exit 1
    ;;
esac
