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
VERIFY="$REPOSITORY_ROOT/scripts/e2e/verify.sh"
LAUNCH="$REPOSITORY_ROOT/scripts/e2e/launch-app.sh"
VALIDATE="$REPOSITORY_ROOT/scripts/e2e/validate-local-elasticsearch-url.py"
TEMP_DIR="$REPOSITORY_ROOT/build/e2e-test-verify"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

for endpoint in \
  localhost \
  localhost:9200 \
  http://localhost:9200 \
  https://127.0.0.1 \
  127.0.0.1:9200 \
  ::1 \
  "[::1]:9200" \
  "http://[::1]:9200"; do
  python3 "$VALIDATE" "$endpoint"
done

for endpoint in \
  "******example.invalid" \
  "http://user@localhost:9200" \
  "http://localhost.example:9200" \
  "http://127.1:9200" \
  "http://[::1]:9200/path"; do
  if python3 "$VALIDATE" "$endpoint" >/dev/null 2>&1; then
    echo "Expected local endpoint validation to reject $endpoint." >&2
    exit 1
  fi
done

fake_bin="$TEMP_DIR/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REQUEST_LOG"
printf '{"status":"green"}\n'
EOF
cat >"$fake_bin/adb" <<'EOF'
#!/usr/bin/env bash
printf 'adb %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == "get-serialno" ]]; then
  echo "emulator-5554"
fi
EOF
cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "fake docker diagnostics"
EOF
cat >"$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == "simctl list devices booted -j" ]]; then
  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"state":"Booted","udid":"SIM-123"}]}}\n'
fi
EOF
chmod +x "$fake_bin/curl" "$fake_bin/adb" "$fake_bin/docker" "$fake_bin/xcrun"

wrong_args_artifacts="$TEMP_DIR/wrong-args"
request_log="$TEMP_DIR/requests.log"
command_log="$TEMP_DIR/commands.log"
if PATH="$fake_bin:$PATH" \
  REQUEST_LOG="$request_log" \
  COMMAND_LOG="$command_log" \
  E2E_ARTIFACT_DIR="$wrong_args_artifacts" \
  "$VERIFY"; then
  echo "Expected wrong argument count to fail." >&2
  exit 1
else
  status=$?
fi
if [[ "$status" -ne 1 ]]; then
  echo "Wrong argument count returned $status instead of 1." >&2
  exit 1
fi
grep -F "Usage:" "$wrong_args_artifacts/verifier-output.txt" >/dev/null
grep -F "Verifier failed with exit code 1" "$wrong_args_artifacts/verifier-output.txt" >/dev/null
grep -F "API key was not provided" "$wrong_args_artifacts/cluster-health.json" >/dev/null

deceptive_artifacts="$TEMP_DIR/deceptive"
if PATH="$fake_bin:$PATH" \
  REQUEST_LOG="$request_log" \
  COMMAND_LOG="$command_log" \
  E2E_ARTIFACT_DIR="$deceptive_artifacts" \
  E2E_LOCAL_RERUN=1 \
  "$VERIFY" android "******example.invalid" "not-a-real-key"; then
  echo "Expected deceptive endpoint cleanup to fail." >&2
  exit 1
fi
if [[ -s "$request_log" ]]; then
  echo "Deceptive endpoint refusal attempted an Elasticsearch request." >&2
  exit 1
fi
grep -F "refusing ******example.invalid" \
  "$deceptive_artifacts/verifier-output.txt" >/dev/null

mkdir -p "$TEMP_DIR/apps/ReactNativeDemoApp.app"
touch "$TEMP_DIR/apps/app-release.apk"
: >"$command_log"

PATH="$fake_bin:$PATH" \
  COMMAND_LOG="$command_log" \
  "$LAUNCH" android "$TEMP_DIR/apps/app-release.apk" |
  grep -F "E2E_DEVICE_ID=emulator-5554" >/dev/null
grep -F "adb install -r $TEMP_DIR/apps/app-release.apk" "$command_log" >/dev/null
grep -F "adb reverse tcp:4318 tcp:4318" "$command_log" >/dev/null
grep -F "adb shell am force-stop co.elastic.edot.reactnative.demo" "$command_log" >/dev/null
grep -F "adb shell am start -n co.elastic.edot.reactnative.demo/com.reactnativedemoapp.MainActivity" "$command_log" >/dev/null

: >"$command_log"
PATH="$fake_bin:$PATH" \
  COMMAND_LOG="$command_log" \
  "$LAUNCH" ios "$TEMP_DIR/apps/ReactNativeDemoApp.app" |
  grep -F "E2E_DEVICE_ID=SIM-123" >/dev/null
grep -F "xcrun simctl install SIM-123 $TEMP_DIR/apps/ReactNativeDemoApp.app" \
  "$command_log" >/dev/null
grep -F "xcrun simctl launch --terminate-running-process SIM-123 co.elastic.edot.reactnative.demo" \
  "$command_log" >/dev/null

ci_root="$TEMP_DIR/ci"
ci_bin="$ci_root/bin"
mkdir -p "$ci_bin" "$ci_root/scripts/e2e" "$ci_root/elastic-start-local"
cp "$REPOSITORY_ROOT/scripts/e2e/ci.sh" "$ci_root/scripts/e2e/ci.sh"
cp "$fake_bin/adb" "$ci_bin/adb"
cat >"$ci_root/elastic-start-local/.env" <<'EOF'
ES_LOCAL_URL=http://localhost:9200
ES_LOCAL_API_KEY=fixture-key
ES_LOCAL_CONTAINER_NAME=fixture-elasticsearch
EDOT_LOCAL_CONTAINER_NAME=fixture-collector
EOF
cat >"$ci_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REQUEST_LOG"
if [[ "$*" == *https://elastic.co/start-local* ]]; then
  printf 'printf "installer %%s\\n" "$*" >>"$COMMAND_LOG"\n'
else
  printf '{"hits":{"hits":[{"_source":{"fixture.unmatched":true}}]}}\n'
fi
EOF
cat >"$ci_bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$COMMAND_LOG"
printf 'fixture container output: %s\n' "$*"
EOF
cat >"$ci_bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "Intentional fixture build failure." >&2
exit 17
EOF
cat >"$ci_bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$ci_root/backend-manager" <<'EOF'
#!/usr/bin/env bash
printf 'backend %s\n' "$*" >>"$COMMAND_LOG"
EOF
cp "$ci_root/backend-manager" "$ci_root/elastic-start-local/stop.sh"
chmod +x "$ci_bin/"* "$ci_root/backend-manager" "$ci_root/elastic-start-local/stop.sh"
: >"$command_log"
if env -u ELASTIC_VERSION PATH="$ci_bin:$PATH" \
  REQUEST_LOG="$request_log" COMMAND_LOG="$command_log" \
  "$ci_root/scripts/e2e/ci.sh" android >"$ci_root/missing-version.log" 2>&1; then
  echo "Expected CI to reject a missing Elastic version." >&2
  exit 1
fi
grep -F "Set ELASTIC_VERSION" "$ci_root/missing-version.log" >/dev/null
if [[ -s "$command_log" ]]; then
  echo "Missing version must fail before starting the stack." >&2
  exit 1
fi
if PATH="$ci_bin:$PATH" ELASTIC_VERSION=9.4.2 \
  REQUEST_LOG="$request_log" COMMAND_LOG="$command_log" \
  "$ci_root/scripts/e2e/ci.sh" android; then
  echo "Expected the fixture build to fail." >&2
  exit 1
else
  status=$?
fi
if [[ "$status" -ne 17 ]]; then
  echo "CI cleanup returned $status instead of the original build failure." >&2
  exit 1
fi
grep -F "installer -v 9.4.2 --esonly --edot" "$command_log" >/dev/null
grep -F "fixture container output: logs fixture-elasticsearch" \
  "$ci_root/build/e2e/elasticsearch.log" >/dev/null
grep -F "fixture container output: logs fixture-collector" \
  "$ci_root/build/e2e/collector.log" >/dev/null
for signal in traces logs; do
  jq -e '.hits.hits[0]._source["fixture.unmatched"] == true' \
    "$ci_root/build/e2e/recent-$signal.json" >/dev/null
done

crash_bin="$TEMP_DIR/crash-bin"
crash_state="$TEMP_DIR/crash-state"
mkdir -p "$crash_bin" "$crash_state" "$TEMP_DIR/markers"
touch "$TEMP_DIR/markers/berlin-complete" "$TEMP_DIR/markers/new-york-complete"
cat >"$crash_bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
hit() {
  local document="$1"
  if [[ -n "${FAKE_CRASH_TIMESTAMP:-}" && "$document" == *'"@timestamp"'* ]]; then
    document=$(jq --argjson timestamp "$FAKE_CRASH_TIMESTAMP" '.["@timestamp"] = $timestamp' <<<"$document")
  fi
  printf '{"hits":{"total":{"value":1},"hits":[{"_id":"fake","_source":%s}]}}\n' "$document"
}
case "$url" in
  */_count) echo '{"count":0}' ;;
  */_search)
    if [[ "$body" == *app.crash* ]]; then
      if [[ "${FAKE_CRASH_EXPORTED:-0}" == "1" && -f "$CRASH_STATE/relaunched" ]]; then
        if [[ "$FAKE_PLATFORM" == "ios" ]]; then
          hit "$(cat <<'JSON'
{"@timestamp":"2026-09-21T14:13:25.000Z","service.name":"weather-demo-react-native","attributes":{"exception.type":"SIGABRT","exception.stacktrace":"Incident Identifier: FAKE\nHardware Model: arm64\nProcess: ReactNativeDemoA [4321]\nException Type: SIGABRT\n\nApplication Specific Information:\n*** Terminating app due to uncaught exception 'RCTFatalException: Unhandled JS Exception: Error: Intentional crash from the EDOT React Native demo', reason: 'Unhandled JS Exception: Error: Intentional crash from the EDOT React Native demo, stack:\ncrashApp@44536:19","session.id":"fake-session"}}
JSON
)"
        else
          hit '{"@timestamp":"2026-09-21T14:13:25.000Z","service.name":"weather-demo-react-native","attributes":{"exception.type":"com.facebook.react.common.JavascriptException","exception.stacktrace":"com.facebook.react.common.JavascriptException: Error: Intentional crash from the EDOT React Native demo","session.id":"fake-session"}}'
        fi
      else
        echo '{"hits":{"total":{"value":0},"hits":[]}}'
      fi
    elif [[ "$body" == *"Forecast request failed"* ]]; then
      hit '{"service.name":"weather-demo-react-native","log.level":"ERROR"}'
    elif [[ "$body" == *forecast-back-button* ]]; then
      hit '{"service.name":"weather-demo-react-native","app.widget.id":"forecast-back-button","app.widget.name":"Back","scope":{"name":"@elastic/otel-react-native.interactions"},"attributes":{"otel.event.name":"app.widget.click"}}'
    elif [[ "$body" == *app.widget.id* ]]; then
      hit '{"service.name":"weather-demo-react-native","app.widget.id":"fetch-forecast-button","app.widget.name":"Fetch forecast","scope":{"name":"@elastic/otel-react-native.interactions"},"attributes":{"otel.event.name":"app.widget.click"}}'
    elif [[ "$body" == *"/config/v1/agents"* ]]; then
      if [[ "${FAKE_POLL_SPAN:-0}" == "1" ]]; then
        hit '{"service.name":"weather-demo-react-native","trace.id":"t-poll","span.id":"s-poll","name":"GET /config/v1/agents","span.kind":"Client","url.path":"/config/v1/agents"}'
      else
        echo '{"hits":{"total":{"value":0},"hits":[]}}'
      fi
    elif [[ "$body" == *"url.path"* && "$body" == *"/v1/forecast"* ]]; then
      if [[ "${FAKE_OMIT_PATH_CONTROL:-0}" == "1" ]]; then
        echo '{"hits":{"total":{"value":0},"hits":[]}}'
      else
        hit '{"service.name":"weather-demo-react-native","trace.id":"t1","span.id":"s1","name":"GET /v1/forecast","span.kind":"Client","url.path":"/v1/forecast"}'
      fi
    elif [[ "$body" == *"city=New%20York"* ]]; then
      hit '{"service.name":"weather-demo-backend","trace.id":"t-ny","span.id":"s-ny-backend","name":"GET /v1/forecast","http.response.status_code":500,"url.query":"city=New%20York"}'
    elif [[ "$body" == *"t-ny"* ]]; then
      if [[ "${FAKE_NY_STATUS:-500}" == "missing" ]]; then
        hit '{"service.name":"weather-demo-react-native","trace.id":"t-ny","span.id":"s-ny","name":"GET /v1/forecast","span.kind":"Client"}'
      elif [[ "${FAKE_NY_STATUS:-500}" == "0" ]]; then
        hit '{"service.name":"weather-demo-react-native","trace.id":"t-ny","span.id":"s-ny","name":"GET /v1/forecast","span.kind":"Client","http.response.status_code":0}'
      else
        hit '{"service.name":"weather-demo-react-native","trace.id":"t-ny","span.id":"s-ny","name":"GET /v1/forecast","span.kind":"Client","http.response.status_code":500}'
      fi
    elif [[ "${FAKE_EXTRA_BERLIN_SPAN:-0}" == "1" && "$body" == *"t1"* && "$body" == *"weather-demo-react-native"* && "$body" != *"Creating app"* && "$body" != *"Initialize React Native UI"* && "$body" != *"app.widget"* && "$body" != *"Forecast request failed"* && "$body" != *"During app creation"* && "$body" != *"url.path"* ]]; then
      printf '%s\n' '{"hits":{"total":{"value":2},"hits":[{"_id":"berlin-1","_source":{"service.name":"weather-demo-react-native","trace.id":"t1","span.id":"s1","name":"GET /v1/forecast","span.kind":"Client","parent.id":"s1","scope":{"name":"@elastic/otel-react-native"},"deployment.environment.name":"local","resource":{"attributes":{"service.namespace":"weather-demo"}}}},{"_id":"berlin-2","_source":{"service.name":"weather-demo-react-native","trace.id":"t1","span.id":"s2","name":"GET localhost","span.kind":"Client"}}]}}'
    elif [[ "${FAKE_OMIT_NAMESPACE:-0}" == "1" ]]; then
      hit '{"service.name":"weather-demo-react-native","trace.id":"t1","span.id":"s1","parent.id":"s1","span.kind":"Client","scope":{"name":"@elastic/otel-react-native"},"deployment.environment.name":"local"}'
    else
      hit '{"service.name":"weather-demo-react-native","trace.id":"t1","span.id":"s1","parent.id":"s1","span.kind":"Client","scope":{"name":"@elastic/otel-react-native"},"deployment.environment.name":"local","resource":{"attributes":{"service.namespace":"weather-demo"}}}'
    fi
    ;;
  *) echo '{"status":"green"}' ;;
esac
EOF
cat >"$crash_bin/adb" <<'EOF'
#!/usr/bin/env bash
printf 'adb %s\n' "$*" >>"$COMMAND_LOG"
case "$*" in
  get-serialno) echo "emulator-5554" ;;
  "shell date -u +%s") echo "1790000000" ;;
  "shell pidof co.elastic.edot.reactnative.demo")
    if [[ "${FAKE_APP_EXITS:-0}" == "1" ]]; then
      exit 1
    fi
    echo "1234"
    ;;
  "shell am start"*)
    starts=$(( $(cat "$CRASH_STATE/starts" 2>/dev/null || echo 0) + 1 ))
    echo "$starts" >"$CRASH_STATE/starts"
    if (( starts >= 2 )); then
      touch "$CRASH_STATE/relaunched"
    fi
    ;;
esac
EOF
cat >"$crash_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >>"$COMMAND_LOG"
case "$*" in
  "simctl list devices booted -j")
    printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Booted","udid":"SIM-123"}]}}\n'
    ;;
  "simctl launch"*)
    launches=$(( $(cat "$CRASH_STATE/launches" 2>/dev/null || echo 0) + 1 ))
    echo "$launches" >"$CRASH_STATE/launches"
    if (( launches >= 2 )); then
      touch "$CRASH_STATE/relaunched"
    fi
    echo "co.elastic.edot.reactnative.demo: 4321"
    ;;
  "simctl spawn SIM-123 launchctl list")
    printf '4000\t0\tUIKitApplication:com.apple.Preferences[1a2b][rb-legacy]\n'
    if [[ "${FAKE_APP_EXITS:-0}" == "1" ]]; then
      printf -- '-\t0\tUIKitApplication:co.elastic.edot.reactnative.demo[3c4d][rb-legacy]\n'
    else
      printf '4321\t0\tUIKitApplication:co.elastic.edot.reactnative.demo[3c4d][rb-legacy]\n'
    fi
    ;;
esac
EOF
cat >"$crash_bin/date" <<'EOF'
#!/usr/bin/env bash
echo "1790000000"
EOF
printf '#!/usr/bin/env bash\n' >"$crash_bin/sleep"
cp "$fake_bin/docker" "$crash_bin/docker"
chmod +x "$crash_bin/curl" "$crash_bin/adb" "$crash_bin/xcrun" "$crash_bin/date" \
  "$crash_bin/sleep" "$crash_bin/docker"
# The verifier relaunches through launch-app.sh, which resolves the release app
# relative to its own checkout, so run a copy of the scripts in a scratch layout.
crash_repository="$TEMP_DIR/crash-repository"
mkdir -p "$crash_repository/scripts/e2e" \
  "$crash_repository/android/app/build/outputs/apk/release" \
  "$crash_repository/ios/build/Build/Products/Release-iphonesimulator/ReactNativeDemoApp.app"
cp "$VERIFY" "$LAUNCH" "$VALIDATE" "$crash_repository/scripts/e2e/"
touch "$crash_repository/android/app/build/outputs/apk/release/app-release.apk"

run_crash_scenario() {
  local platform="$1"
  local name="$2"
  local app_exits="$3"
  local crash_exported="$4"
  local omit_namespace="${5:-0}"
  local extra_berlin="${6:-0}"
  local ny_status="${7:-500}"
  local poll_span="${8:-0}"
  local omit_path="${9:-0}"
  rm -f "$crash_state"/*
  : >"$command_log"
  PATH="$crash_bin:$PATH" \
    COMMAND_LOG="$command_log" \
    CRASH_STATE="$crash_state" \
    FAKE_PLATFORM="$platform" \
    FAKE_APP_EXITS="$app_exits" \
    FAKE_CRASH_EXPORTED="$crash_exported" \
    FAKE_OMIT_NAMESPACE="$omit_namespace" \
    FAKE_EXTRA_BERLIN_SPAN="$extra_berlin" \
    FAKE_NY_STATUS="$ny_status" \
    FAKE_POLL_SPAN="$poll_span" \
    FAKE_OMIT_PATH_CONTROL="$omit_path" \
    FAKE_CRASH_TIMESTAMP="${CRASH_TIMESTAMP:-}" \
    E2E_STEP_COMMAND="${STEP_COMMAND:-}" \
    E2E_MARKER_DIR="${STEP_MARKER_DIR-$TEMP_DIR/markers}" \
    E2E_ARTIFACT_DIR="$TEMP_DIR/$platform-$name" \
    "$crash_repository/scripts/e2e/verify.sh" "$platform" http://localhost:9200 \
    "not-a-real-key" >/dev/null 2>&1
}

cat >"$TEMP_DIR/step-hook.sh" <<'EOF'
#!/usr/bin/env bash
echo "$2:$E2E_DEVICE_ID" >>"$1"
[[ "$2" != "${FAIL_STEP:-}" ]]
EOF

for platform in android ios; do
  case "$platform" in
    android) launch_command="adb shell am start -n co.elastic.edot.reactnative.demo/com.reactnativedemoapp.MainActivity" ;;
    ios) launch_command="xcrun simctl launch --terminate-running-process SIM-123 co.elastic.edot.reactnative.demo" ;;
  esac

  run_crash_scenario "$platform" crash-success 1 1
  grep -F "Intentional crash from the EDOT React Native demo" \
    "$TEMP_DIR/$platform-crash-success/crash.json" >/dev/null
  grep -F "Local React Native $platform demo E2E verification passed." \
    "$TEMP_DIR/$platform-crash-success/verifier-output.txt" >/dev/null
  if [[ $(grep -c -F "$launch_command" "$command_log") -ne 2 ]]; then
    echo "Expected the $platform crash scenario to relaunch the app once." >&2
    exit 1
  fi

  STEP_COMMAND="bash \"$TEMP_DIR/step-hook.sh\" \"$TEMP_DIR/steps.log\""
  STEP_MARKER_DIR="$TEMP_DIR/nonexistent-markers"
  : >"$TEMP_DIR/steps.log"
  run_crash_scenario "$platform" hook-success 1 1
  case "$platform" in
    android) expected_device=emulator-5554 ;;
    ios) expected_device=SIM-123 ;;
  esac
  printf 'berlin:%s\nnew-york:%s\ncrash:%s\n' \
    "$expected_device" "$expected_device" "$expected_device" \
    >"$TEMP_DIR/expected-steps.log"
  diff -u "$TEMP_DIR/expected-steps.log" "$TEMP_DIR/steps.log"
  for step in berlin new-york crash; do
    if FAIL_STEP="$step" run_crash_scenario "$platform" "hook-failure-$step" 1 1; then
      echo "Expected the $platform $step hook failure to fail verification." >&2
      exit 1
    fi
    grep -F "UI step '$step' failed." \
      "$TEMP_DIR/$platform-hook-failure-$step/verifier-output.txt" >/dev/null
    test -s "$TEMP_DIR/$platform-hook-failure-$step/cluster-health.json"
  done
  unset STEP_COMMAND
  # With neither hook nor markers, the two forecast prompts accept stdin.
  STEP_MARKER_DIR=""
  run_crash_scenario "$platform" hook-unset 1 1 <<< $'\n\n'
  if grep -F "Running UI step:" "$TEMP_DIR/$platform-hook-unset/verifier-output.txt"; then
    echo "An unset hook unexpectedly ran." >&2
    exit 1
  fi
  unset STEP_MARKER_DIR

  for timestamp in '1790000000123.456' '"1790000000123.456"'; do
    CRASH_TIMESTAMP="$timestamp" run_crash_scenario "$platform" epoch-millis 1 1
  done
  if CRASH_TIMESTAMP='"1789999999123.456"' run_crash_scenario "$platform" stale-epoch-millis 1 1; then
    echo "Expected a $platform crash timestamp older than the prompt to fail." >&2
    exit 1
  fi
  grep -F "The crash record predates the Crash prompt" \
    "$TEMP_DIR/$platform-stale-epoch-millis/verifier-output.txt" >/dev/null

  if run_crash_scenario "$platform" crash-no-exit 0 1; then
    echo "Expected a $platform crash scenario whose process never exits to fail." >&2
    exit 1
  fi
  grep -F "did not exit within 180s of the Crash prompt" \
    "$TEMP_DIR/$platform-crash-no-exit/verifier-output.txt" >/dev/null

  if run_crash_scenario "$platform" crash-no-record 1 0; then
    echo "Expected a $platform crash scenario without an exported record to fail." >&2
    exit 1
  fi
  grep -F "no app.crash record arrived within 180s of the relaunch" \
    "$TEMP_DIR/$platform-crash-no-record/verifier-output.txt" >/dev/null

  if run_crash_scenario "$platform" missing-namespace 1 1 1; then
    echo "Expected $platform startup telemetry without service.namespace to fail." >&2
    exit 1
  fi
  grep -F "Startup service.namespace mismatch: expected 'weather-demo', got ''." \
    "$TEMP_DIR/$platform-missing-namespace/verifier-output.txt" >/dev/null

  if run_crash_scenario "$platform" extra-berlin-span 1 1 0 1; then
    echo "Expected a $platform run with two Berlin app spans to fail." >&2
    exit 1
  fi
  grep -F "Expected exactly one app HTTP span in Berlin trace" \
    "$TEMP_DIR/$platform-extra-berlin-span/verifier-output.txt" >/dev/null

  if run_crash_scenario "$platform" ny-missing-status 1 1 0 0 missing; then
    echo "Expected a $platform New York span without a status code to fail." >&2
    exit 1
  fi
  grep -F "New York app HTTP span http.response.status_code mismatch: expected '500', got ''." \
    "$TEMP_DIR/$platform-ny-missing-status/verifier-output.txt" >/dev/null

  if run_crash_scenario "$platform" ny-zero-status 1 1 0 0 0; then
    echo "Expected a $platform New York span with status 0 to fail." >&2
    exit 1
  fi
  grep -F "New York app HTTP span http.response.status_code mismatch: expected '500', got '0'." \
    "$TEMP_DIR/$platform-ny-zero-status/verifier-output.txt" >/dev/null

  if [[ "$platform" == "ios" ]]; then
    if run_crash_scenario ios ios-poll-span 1 1 0 0 500 1; then
      echo "Expected an iOS poll span to fail." >&2
      exit 1
    fi
    grep -F "URL path /config/v1/agents" \
      "$TEMP_DIR/ios-ios-poll-span/verifier-output.txt" >/dev/null

    if run_crash_scenario ios ios-missing-path-control 1 1 0 0 500 0 1; then
      echo "Expected an iOS run with no path control to fail." >&2
      exit 1
    fi
    grep -F "URL path field matched no Berlin app span" \
      "$TEMP_DIR/ios-ios-missing-path-control/verifier-output.txt" >/dev/null
    if grep -F "/config/v1/agents" \
      "$TEMP_DIR/ios-ios-missing-path-control/verifier-output.txt" >/dev/null; then
      echo "Path-control failure mentioned the poll path." >&2
      exit 1
    fi
  else
    run_crash_scenario android android-poll-span-ignored 1 1 0 0 500 1
    grep -F "Local React Native android demo E2E verification passed." \
      "$TEMP_DIR/android-android-poll-span-ignored/verifier-output.txt" >/dev/null
  fi

  echo "$platform crash scenarios passed: crash-success, crash-no-exit, crash-no-record, missing-namespace, extra-berlin-span, ny-missing-status, ny-zero-status."
done

echo "Verifier safety, platform launcher, and crash scenario probes passed."
