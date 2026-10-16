#!/usr/bin/env bash

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
grep -F "adb shell am force-stop com.reactnativedemoapp" "$command_log" >/dev/null
grep -F "adb shell am start -n com.reactnativedemoapp/.MainActivity" "$command_log" >/dev/null

: >"$command_log"
PATH="$fake_bin:$PATH" \
  COMMAND_LOG="$command_log" \
  "$LAUNCH" ios "$TEMP_DIR/apps/ReactNativeDemoApp.app" |
  grep -F "E2E_DEVICE_ID=SIM-123" >/dev/null
grep -F "xcrun simctl install SIM-123 $TEMP_DIR/apps/ReactNativeDemoApp.app" \
  "$command_log" >/dev/null
grep -F "xcrun simctl launch --terminate-running-process SIM-123 com.reactnativedemoapp" \
  "$command_log" >/dev/null

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
  printf '{"hits":{"total":{"value":1},"hits":[{"_id":"fake","_source":%s}]}}\n' "$1"
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
  "shell pidof com.reactnativedemoapp")
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
    echo "com.reactnativedemoapp: 4321"
    ;;
  "simctl spawn SIM-123 launchctl list")
    printf '4000\t0\tUIKitApplication:com.apple.Preferences[1a2b][rb-legacy]\n'
    if [[ "${FAKE_APP_EXITS:-0}" != "1" ]]; then
      printf '4321\t0\tUIKitApplication:com.reactnativedemoapp[3c4d][rb-legacy]\n'
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
  rm -f "$crash_state"/*
  : >"$command_log"
  PATH="$crash_bin:$PATH" \
    COMMAND_LOG="$command_log" \
    CRASH_STATE="$crash_state" \
    FAKE_PLATFORM="$platform" \
    FAKE_APP_EXITS="$app_exits" \
    FAKE_CRASH_EXPORTED="$crash_exported" \
    FAKE_OMIT_NAMESPACE="$omit_namespace" \
    E2E_MARKER_DIR="$TEMP_DIR/markers" \
    E2E_ARTIFACT_DIR="$TEMP_DIR/$platform-$name" \
    "$crash_repository/scripts/e2e/verify.sh" "$platform" http://localhost:9200 \
    "not-a-real-key" >/dev/null 2>&1
}

for platform in android ios; do
  case "$platform" in
    android) launch_command="adb shell am start -n com.reactnativedemoapp/.MainActivity" ;;
    ios) launch_command="xcrun simctl launch --terminate-running-process SIM-123 com.reactnativedemoapp" ;;
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

  echo "$platform crash scenarios passed: crash-success, crash-no-exit, crash-no-record, missing-namespace."
done

echo "Verifier safety, platform launcher, and crash scenario probes passed."
