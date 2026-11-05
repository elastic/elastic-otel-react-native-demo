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
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
case "${1:-}" in
  berlin) test_name=testBerlin ;;
  new-york) test_name=testNewYork ;;
  crash) test_name=testCrash ;;
  *) echo "Usage: $0 <berlin|new-york|crash>" >&2; exit 1 ;;
esac
simulator="${IOS_SIMULATOR_UDID:-${E2E_DEVICE_ID:?Set IOS_SIMULATOR_UDID or use the verifier hook}}"
artifacts="${E2E_ARTIFACT_DIR:-build/e2e}"
derived="$ROOT/build/e2e-driver"
mkdir -p "$artifacts" "$ROOT/build/tmp"
export TMPDIR="$ROOT/build/tmp"
options=(-project scripts/e2e/ios/Driver.xcodeproj -scheme Driver
  -destination "platform=iOS Simulator,id=$simulator"
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO)
# Build once for this simulator; each verifier step runs only its own test.
if [[ ! -f "$derived/ready-$simulator" ]]; then
  xcodebuild "${options[@]}" build-for-testing >"$artifacts/ios-driver-build.log" 2>&1
  touch "$derived/ready-$simulator"
fi
rm -rf "$artifacts/ios-$1.xcresult"
xcodebuild "${options[@]}" test-without-building \
  -parallel-testing-enabled NO \
  -only-testing:"Driver/DriverTests/$test_name" \
  -resultBundlePath "$artifacts/ios-$1.xcresult" \
  >"$artifacts/ios-$1.log" 2>&1
