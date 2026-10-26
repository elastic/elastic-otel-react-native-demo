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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT_DIR="${E2E_ARTIFACT_DIR:-build/e2e}"
mkdir -p "$ARTIFACT_DIR"
VERIFIER_OUTPUT="$ARTIFACT_DIR/verifier-output.txt"
rm -f \
  "$ARTIFACT_DIR/cluster-health.json" \
  "$ARTIFACT_DIR/ios-simulator.log" \
  "$ARTIFACT_DIR/logcat.txt" \
  "$ARTIFACT_DIR/backend.log" \
  "$ARTIFACT_DIR/docker-ps.txt"
exec > >(tee "$VERIFIER_OUTPUT") 2>&1

ES_URL=""
API_KEY=""
COLLECT_ES_DIAGNOSTICS=0
PLATFORM=""
DEVICE_ID=""

es_request() {
  local path="$1"
  local body="$2"
  curl -fsS "$ES_URL/$path" \
    -H "Authorization: ApiKey $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
}

collect_diagnostics() {
  local status="$?"
  trap - EXIT

  if [[ "$status" -eq 0 ]]; then
    return
  fi

  set +e +u
  set +o pipefail
  echo "Verifier failed with exit code $status; collecting diagnostics."

  if [[ "$COLLECT_ES_DIAGNOSTICS" == "1" && -n "$ES_URL" && -n "$API_KEY" ]]; then
    es_request "_cluster/health" '{}' >"$ARTIFACT_DIR/cluster-health.json" 2>&1 ||
      echo "Elasticsearch cluster health request failed." >>"$ARTIFACT_DIR/cluster-health.json"
  else
    echo "Elasticsearch diagnostics unavailable: endpoint was not safe for diagnostics or API key was not provided." \
      >"$ARTIFACT_DIR/cluster-health.json"
  fi

  if [[ "$PLATFORM" == "android" ]] && command -v adb >/dev/null 2>&1; then
    adb logcat -d >"$ARTIFACT_DIR/logcat.txt" 2>&1 ||
      echo "adb logcat collection failed." >>"$ARTIFACT_DIR/logcat.txt"
  else
    echo "Android logcat diagnostics not selected or adb is unavailable." \
      >"$ARTIFACT_DIR/logcat.txt"
  fi

  if [[ "$PLATFORM" == "ios" && -n "$DEVICE_ID" ]] &&
    command -v xcrun >/dev/null 2>&1; then
    xcrun simctl spawn "$DEVICE_ID" log show \
      --style compact \
      --last 10m \
      --predicate 'process == "ReactNativeDemoApp"' \
      >"$ARTIFACT_DIR/ios-simulator.log" 2>&1 ||
      echo "iOS simulator log collection failed." >>"$ARTIFACT_DIR/ios-simulator.log"
  else
    echo "iOS simulator diagnostics not selected or unavailable." \
      >"$ARTIFACT_DIR/ios-simulator.log"
  fi

  if command -v docker >/dev/null 2>&1; then
    docker logs react-native-weather-backend >"$ARTIFACT_DIR/backend.log" 2>&1 ||
      echo "Backend log collection failed." >>"$ARTIFACT_DIR/backend.log"
    docker ps -a >"$ARTIFACT_DIR/docker-ps.txt" 2>&1 ||
      echo "Container-state collection failed." >>"$ARTIFACT_DIR/docker-ps.txt"
  else
    echo "docker is unavailable." >"$ARTIFACT_DIR/backend.log"
    echo "docker is unavailable." >"$ARTIFACT_DIR/docker-ps.txt"
  fi

  exit "$status"
}

trap collect_diagnostics EXIT

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <android|ios> <elasticsearch-url> <api-key>" >&2
  exit 1
fi

PLATFORM="$1"
if [[ "$PLATFORM" != "android" && "$PLATFORM" != "ios" ]]; then
  echo "Platform must be android or ios." >&2
  exit 1
fi
ES_URL="${2%/}"
API_KEY="$3"
COLLECT_ES_DIAGNOSTICS=1

assert_no_existing_documents() {
  local label="$1"
  local query="$2"
  local response
  response=$(es_request "traces-*,logs-*/_count" "$query")
  local count
  count=$(jq -r '.count' <<<"$response")
  if [[ "$count" != "0" ]]; then
    echo "Expected a fresh Elasticsearch data set, but found $count existing $label documents." >&2
    exit 1
  fi
}

delete_existing_documents() {
  if ! python3 "$SCRIPT_DIR/validate-local-elasticsearch-url.py" "$ES_URL"; then
    COLLECT_ES_DIAGNOSTICS=0
    echo "Local-rerun cleanup requires loopback Elasticsearch; refusing $ES_URL." >&2
    exit 1
  fi

  echo "Deleting prior telemetry only for the demo app and backend services..."
  es_request \
    "traces-*,logs-*/_delete_by_query?conflicts=proceed&refresh=true" \
    '{"query":{"terms":{"service.name":["weather-demo-react-native","weather-demo-backend"]}}}' \
    >"$ARTIFACT_DIR/local-rerun-cleanup.json"
}

wait_for_hit() {
  local index="$1"
  local label="$2"
  local query="$3"
  local output="$4"
  local elapsed=0

  while (( elapsed < 180 )); do
    local response
    response=$(es_request "$index/_search" "$query")
    if [[ $(jq -r '.hits.total.value' <<<"$response") -gt 0 ]]; then
      jq '.hits.hits[0]' <<<"$response" | tee "$output"
      return
    fi
    echo "Waiting for $label (${elapsed}s/180s)..." >&2
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Timed out waiting for $label." >&2
  exit 1
}

field() {
  local document="$1"
  local expression="$2"
  jq -r "$expression // empty" "$document"
}

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "$label mismatch: expected '$expected', got '$actual'." >&2
    exit 1
  fi
}

list_span_names_and_ids() {
  jq -r '.hits.hits[] | "- name=\(._source.name // "unknown") span.id=\(._source["span.id"] // ._source.span_id // "unknown")"'
}

app_path_query() {
  local trace="$1"
  local path_field="$2"
  local path_value="$3"
  jq -nc \
    --arg trace "$trace" \
    --arg field "$path_field" \
    --arg path "$path_value" \
    '{
      size: 10,
      query: {
        bool: {
          filter: [
            {term: {"service.name": {value: "weather-demo-react-native"}}},
            (if $trace == "" then empty else {term: {"trace.id": {value: $trace}}} end),
            {term: {($field): {value: $path}}}
          ]
        }
      }
    }'
}

assert_one_berlin_app_span() {
  local trace="$1"
  local query="$2"
  local response count kind
  response=$(es_request "traces-*/_search" "$query")
  count=$(jq -r '.hits.total.value' <<<"$response")
  if [[ "$count" != "1" ]]; then
    echo "Expected exactly one app HTTP span in Berlin trace $trace, found $count:" >&2
    list_span_names_and_ids <<<"$response" >&2
    if [[ "$count" -gt 10 ]]; then
      echo "The span list is truncated at 10." >&2
    fi
    exit 1
  fi
  kind=$(jq -r '.hits.hits[0]._source["span.kind"] // .hits.hits[0]._source.kind // empty' <<<"$response")
  assert_equal "Berlin app HTTP span kind" "CLIENT" "$(tr '[:lower:]' '[:upper:]' <<<"$kind")"
}

resolve_ios_url_path_field() {
  local trace="$1"
  local candidate response count
  for candidate in "url.path" "attributes.url.path"; do
    response=$(es_request "traces-*/_search" "$(app_path_query "$trace" "$candidate" "/v1/forecast")")
    count=$(jq -r '.hits.total.value' <<<"$response")
    if [[ "$count" -gt 0 ]]; then
      jq '.hits.hits[0]' <<<"$response" >"$ARTIFACT_DIR/forecast-path-control.json"
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "URL path field matched no Berlin app span with path /v1/forecast. Tried url.path and attributes.url.path." >&2
  return 1
}

assert_no_ios_poll_span() {
  local path_field="$1"
  local response count
  response=$(es_request "traces-*/_search" "$(app_path_query "" "$path_field" "/config/v1/agents")")
  count=$(jq -r '.hits.total.value' <<<"$response")
  if [[ "$count" != "0" ]]; then
    echo "Found $count iOS app span(s) with URL path /config/v1/agents:" >&2
    list_span_names_and_ids <<<"$response" >&2
    exit 1
  fi
}

# Platform-specific commands used by the crash step.
app_running() {
  if [[ "$PLATFORM" == "android" ]]; then
    adb shell pidof co.elastic.edot.reactnative.demo 2>/dev/null | tr -d '\r' || true
  else
    # launchctl lists a loaded job that is not running with '-' as its PID.
    xcrun simctl spawn "$DEVICE_ID" launchctl list 2>/dev/null |
      grep -E '^[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+UIKitApplication:co\.elastic\.edot\.reactnative\.demo\[' || true
  fi
}

device_epoch() {
  if [[ "$PLATFORM" == "android" ]]; then
    adb shell date -u +%s | tr -d '\r'
  else
    # The iOS Simulator shares the host clock.
    date -u +%s
  fi
}

wait_for_operator() {
  local prompt="$1"
  local marker="$2"
  if [[ -n "${E2E_MARKER_DIR:-}" ]]; then
    echo "$prompt"
    echo "Waiting for $E2E_MARKER_DIR/$marker ..." >&2
    until [[ -f "$E2E_MARKER_DIR/$marker" ]]; do
      sleep 1
    done
  else
    read -r -p "$prompt "
  fi
}

if [[ "${E2E_VERIFY_ONLY:-0}" != "1" ]]; then
  if [[ "${E2E_LOCAL_RERUN:-0}" == "1" ]]; then
    delete_existing_documents
  else
    echo "Checking that this stack has no prior demo telemetry..."
  fi
  assert_no_existing_documents \
    "React Native app" \
    '{"query":{"term":{"service.name":{"value":"weather-demo-react-native"}}}}'
  assert_no_existing_documents \
    "backend forecast" \
    '{"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-backend"}}},{"term":{"name":{"value":"GET /v1/forecast"}}}]}}}'

  cat <<'EOF'
Fresh-data preflight passed.

The verifier will install and launch the built release app.
EOF
  launch_output=$("$SCRIPT_DIR/launch-app.sh" "$PLATFORM")
  printf '%s\n' "$launch_output"
  DEVICE_ID=$(sed -n 's/^E2E_DEVICE_ID=//p' <<<"$launch_output" | tail -1)
  if [[ -z "$DEVICE_ID" ]]; then
    echo "The app launcher did not report a device identifier." >&2
    exit 1
  fi

  cat <<'EOF'
1. In the app, keep Berlin selected and press "Fetch forecast".
2. Wait until the Berlin forecast appears.
EOF
  wait_for_operator \
    "Continue after the successful Berlin forecast is visible." \
    "berlin-complete"

  cat <<'EOF'
3. Press "Back" to return to the city picker, select New York, and press
   "Fetch forecast".
4. Wait until the rejected-request error is visible.
EOF
  wait_for_operator \
    "Continue after the New York error is visible." \
    "new-york-complete"
fi

startup_root_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"term":{"name":{"value":"Creating app"}}}]}}}'
error_log_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"match_phrase":{"body.text":"Forecast request failed:"}}]}}}'
backend_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-backend"}}},{"term":{"name":{"value":"GET /v1/forecast"}}},{"term":{"http.response.status_code":{"value":200}}},{"term":{"url.query":{"value":"city=Berlin"}}}]}}}'
widget_click_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"term":{"app.widget.id":{"value":"fetch-forecast-button"}}},{"term":{"scope.name":{"value":"@elastic/otel-react-native.interactions"}}}],"should":[{"term":{"otel.event.name":{"value":"app.widget.click"}}},{"term":{"attributes.otel.event.name":{"value":"app.widget.click"}}},{"term":{"event.name":{"value":"app.widget.click"}}},{"term":{"attributes.event.name":{"value":"app.widget.click"}}}],"minimum_should_match":1}}}'
widget_click_back_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"term":{"app.widget.id":{"value":"forecast-back-button"}}},{"term":{"scope.name":{"value":"@elastic/otel-react-native.interactions"}}}],"should":[{"term":{"otel.event.name":{"value":"app.widget.click"}}},{"term":{"attributes.otel.event.name":{"value":"app.widget.click"}}},{"term":{"event.name":{"value":"app.widget.click"}}},{"term":{"attributes.event.name":{"value":"app.widget.click"}}}],"minimum_should_match":1}}}'

wait_for_hit "traces-*" "startup root span" "$startup_root_query" "$ARTIFACT_DIR/startup-root.json"
root_trace=$(field "$ARTIFACT_DIR/startup-root.json" '._source."trace.id" // ._source.trace_id')
startup_child_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"term":{"name":{"value":"Initialize React Native UI"}}},{"term":{"trace.id":{"value":"'"$root_trace"'"}}}]}}}'
wait_for_hit "traces-*" "startup child span" "$startup_child_query" "$ARTIFACT_DIR/startup-child.json"
child_span=$(field "$ARTIFACT_DIR/startup-child.json" '._source."span.id" // ._source.span_id')
startup_log_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"match_phrase":{"body.text":"During app creation"}},{"term":{"trace.id":{"value":"'"$root_trace"'"}}},{"term":{"span.id":{"value":"'"$child_span"'"}}}]}}}'
wait_for_hit "logs-*" "correlated startup log" "$startup_log_query" "$ARTIFACT_DIR/startup-log.json"
wait_for_hit "logs-*" "independent forecast ERROR log" "$error_log_query" "$ARTIFACT_DIR/error-log.json"
wait_for_hit "logs-*" "automatic forecast widget click" "$widget_click_query" "$ARTIFACT_DIR/widget-click.json"
wait_for_hit "logs-*" "automatic back-button widget click" "$widget_click_back_query" "$ARTIFACT_DIR/widget-click-back.json"
wait_for_hit "traces-*" "backend forecast span" "$backend_query" "$ARTIFACT_DIR/backend-span.json"

root_span=$(field "$ARTIFACT_DIR/startup-root.json" '._source."span.id" // ._source.span_id')
child_trace=$(field "$ARTIFACT_DIR/startup-child.json" '._source."trace.id" // ._source.trace_id')
child_parent=$(field "$ARTIFACT_DIR/startup-child.json" '._source."parent.id" // ._source.parent_span_id')
log_trace=$(field "$ARTIFACT_DIR/startup-log.json" '._source."trace.id" // ._source.trace_id')
log_span=$(field "$ARTIFACT_DIR/startup-log.json" '._source."span.id" // ._source.span_id')
root_scope=$(field "$ARTIFACT_DIR/startup-root.json" '._source.scope.name')
child_scope=$(field "$ARTIFACT_DIR/startup-child.json" '._source.scope.name')
log_scope=$(field "$ARTIFACT_DIR/startup-log.json" '._source.scope.name')
root_environment=$(field "$ARTIFACT_DIR/startup-root.json" '._source."deployment.environment.name" // ._source.resource.attributes."deployment.environment.name"')
root_namespace=$(field "$ARTIFACT_DIR/startup-root.json" '._source."service.namespace" // ._source.resource.attributes."service.namespace"')
error_trace=$(field "$ARTIFACT_DIR/error-log.json" '._source."trace.id" // ._source.trace_id')
error_span=$(field "$ARTIFACT_DIR/error-log.json" '._source."span.id" // ._source.span_id')
error_severity=$(field "$ARTIFACT_DIR/error-log.json" '._source."log.level" // ._source.severity_text // ._source.severity')
widget_id=$(field "$ARTIFACT_DIR/widget-click.json" '._source."app.widget.id" // ._source.attributes."app.widget.id"')
widget_name=$(field "$ARTIFACT_DIR/widget-click.json" '._source."app.widget.name" // ._source.attributes."app.widget.name"')
widget_scope=$(field "$ARTIFACT_DIR/widget-click.json" '._source.scope.name')
widget_event_name=$(field "$ARTIFACT_DIR/widget-click.json" '._source.attributes."otel.event.name" // ._source.attributes."event.name" // ._source."otel.event.name" // ._source."event.name"')
widget_trace=$(field "$ARTIFACT_DIR/widget-click.json" '._source."trace.id" // ._source.trace_id')
widget_span=$(field "$ARTIFACT_DIR/widget-click.json" '._source."span.id" // ._source.span_id')
back_widget_id=$(field "$ARTIFACT_DIR/widget-click-back.json" '._source."app.widget.id" // ._source.attributes."app.widget.id"')
back_widget_name=$(field "$ARTIFACT_DIR/widget-click-back.json" '._source."app.widget.name" // ._source.attributes."app.widget.name"')
back_widget_scope=$(field "$ARTIFACT_DIR/widget-click-back.json" '._source.scope.name')
back_widget_event_name=$(field "$ARTIFACT_DIR/widget-click-back.json" '._source.attributes."otel.event.name" // ._source.attributes."event.name" // ._source."otel.event.name" // ._source."event.name"')
back_widget_trace=$(field "$ARTIFACT_DIR/widget-click-back.json" '._source."trace.id" // ._source.trace_id')
back_widget_span=$(field "$ARTIFACT_DIR/widget-click-back.json" '._source."span.id" // ._source.span_id')
backend_trace=$(field "$ARTIFACT_DIR/backend-span.json" '._source."trace.id" // ._source.trace_id')

assert_equal "Startup child trace.id" "$root_trace" "$child_trace"
assert_equal "Startup child parent.id" "$root_span" "$child_parent"
assert_equal "Startup log trace.id" "$child_trace" "$log_trace"
assert_equal "Startup log span.id" "$child_span" "$log_span"
startup_scope="@elastic/otel-react-native"
assert_equal "Startup root instrumentation scope" "$startup_scope" "$root_scope"
assert_equal "Startup child instrumentation scope" "$startup_scope" "$child_scope"
assert_equal "Startup log instrumentation scope" "$startup_scope" "$log_scope"
assert_equal "Startup deployment.environment.name" "local" "$root_environment"
assert_equal "Startup service.namespace" "weather-demo" "$root_namespace"

if [[ -n "$error_trace" || -n "$error_span" ]]; then
  echo "The forecast ERROR log unexpectedly contains span correlation." >&2
  exit 1
fi
assert_equal "Forecast log severity" "ERROR" "$(tr '[:lower:]' '[:upper:]' <<<"$error_severity")"
assert_equal "Widget event name" "app.widget.click" "$widget_event_name"
assert_equal "Widget ID" "fetch-forecast-button" "$widget_id"
assert_equal "Widget name" "Fetch forecast" "$widget_name"
assert_equal "Widget instrumentation scope" "@elastic/otel-react-native.interactions" "$widget_scope"
if [[ -n "$widget_trace" || -n "$widget_span" ]]; then
  echo "The widget click event unexpectedly contains span correlation." >&2
  exit 1
fi
assert_equal "Back widget event name" "app.widget.click" "$back_widget_event_name"
assert_equal "Back widget ID" "forecast-back-button" "$back_widget_id"
assert_equal "Back widget name" "Back" "$back_widget_name"
assert_equal "Back widget instrumentation scope" "@elastic/otel-react-native.interactions" "$back_widget_scope"
if [[ -n "$back_widget_trace" || -n "$back_widget_span" ]]; then
  echo "The back-button widget click event unexpectedly contains span correlation." >&2
  exit 1
fi

app_http_query='{"size":10,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"term":{"trace.id":{"value":"'"$backend_trace"'"}}}]}}}'
wait_for_hit "traces-*" "app HTTP client span in the backend trace" "$app_http_query" "$ARTIFACT_DIR/app-http-span.json"
app_trace=$(field "$ARTIFACT_DIR/app-http-span.json" '._source."trace.id" // ._source.trace_id')
app_span_kind=$(field "$ARTIFACT_DIR/app-http-span.json" '._source."span.kind" // ._source.kind')
assert_equal "Distributed trace.id" "$backend_trace" "$app_trace"
assert_equal "App HTTP span kind" "CLIENT" "$(tr '[:lower:]' '[:upper:]' <<<"$app_span_kind")"

new_york_backend_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-backend"}}},{"term":{"name":{"value":"GET /v1/forecast"}}},{"term":{"http.response.status_code":{"value":500}}},{"term":{"url.query":{"value":"city=New%20York"}}}]}}}'
wait_for_hit "traces-*" "New York backend span" "$new_york_backend_query" "$ARTIFACT_DIR/new-york-backend-span.json"
new_york_trace=$(field "$ARTIFACT_DIR/new-york-backend-span.json" '._source."trace.id" // ._source.trace_id')
new_york_app_query='{"size":10,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"term":{"trace.id":{"value":"'"$new_york_trace"'"}}}]}}}'
wait_for_hit "traces-*" "New York app HTTP span" "$new_york_app_query" "$ARTIFACT_DIR/new-york-app-span.json"
new_york_status=$(field "$ARTIFACT_DIR/new-york-app-span.json" '._source."http.response.status_code" // ._source.attributes."http.response.status_code"')
assert_equal "New York app HTTP span http.response.status_code" "500" "$new_york_status"

crash_message="Intentional crash from the EDOT React Native demo"
crash_query='{"size":1,"query":{"bool":{"filter":[{"term":{"service.name":{"value":"weather-demo-react-native"}}},{"exists":{"field":"exception.type"}},{"exists":{"field":"session.id"}},{"wildcard":{"exception.stacktrace":{"value":"*'"$crash_message"'*"}}}],"should":[{"term":{"event_name":{"value":"app.crash"}}},{"term":{"otel.event.name":{"value":"app.crash"}}}],"minimum_should_match":1}}}'
crash_count() {
  jq -r '.hits.total.value' <<<"$(es_request "logs-*/_search" "$crash_query")"
}

if [[ "${E2E_VERIFY_ONLY:-0}" != "1" ]]; then
  crash_requested_at=$(device_epoch)
  echo '5. Return to the city picker and press "Crash".'
  elapsed=0
  until [[ -z "$(app_running)" ]]; do
    if (( elapsed >= 180 )); then
      echo "The app process did not exit within 180s of the Crash prompt; the crash did not happen." >&2
      exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "The app process exited after the Crash press."

  if [[ "$(crash_count)" != "0" ]]; then
    echo "A crash record was exported before the relaunch; expected next-launch export." >&2
    exit 1
  fi
  echo "Relaunching the app so the native EDOT SDK exports the stored crash..."
  "$SCRIPT_DIR/launch-app.sh" "$PLATFORM" >/dev/null
fi

crash_elapsed=0
until [[ "$(crash_count)" -gt 0 ]]; do
  if (( crash_elapsed >= 180 )); then
    echo "The app crashed, but no app.crash record arrived within 180s of the relaunch." >&2
    exit 1
  fi
  echo "Waiting for the exported crash record (${crash_elapsed}s/180s)..." >&2
  sleep 5
  crash_elapsed=$((crash_elapsed + 5))
done
jq '.hits.hits[0]' <<<"$(es_request "logs-*/_search" "$crash_query")" | tee "$ARTIFACT_DIR/crash.json"

crash_type=$(field "$ARTIFACT_DIR/crash.json" '._source.attributes."exception.type" // ._source."exception.type"')
crash_stacktrace=$(field "$ARTIFACT_DIR/crash.json" '._source.attributes."exception.stacktrace" // ._source."exception.stacktrace"')
crash_session=$(field "$ARTIFACT_DIR/crash.json" '._source.attributes."session.id" // ._source."session.id"')
if [[ -z "$crash_type" || -z "$crash_session" || "$crash_stacktrace" != *"$crash_message"* ]]; then
  echo "The crash record lacks exception.type, session.id, or the intentional crash message." >&2
  exit 1
fi
if [[ -n "${crash_requested_at:-}" ]]; then
  crash_timestamp=$(field "$ARTIFACT_DIR/crash.json" '._source."@timestamp" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
  if [[ -z "$crash_timestamp" ]] || (( crash_timestamp < crash_requested_at )); then
    echo "The crash record predates the Crash prompt; it is not from this run." >&2
    exit 1
  fi
fi
assert_one_berlin_app_span "$backend_trace" "$app_http_query"
if [[ "$PLATFORM" == "ios" ]]; then
  ios_path_field=$(resolve_ios_url_path_field "$backend_trace")
  assert_no_ios_poll_span "$ios_path_field"
fi
summary_items="startup-root startup-child startup-log error-log widget-click widget-click-back app-http-span backend-span new-york-backend-span new-york-app-span"
if [[ "$PLATFORM" == "ios" ]]; then
  summary_items="$summary_items forecast-path-control"
fi
summary_items="$summary_items crash"

printf '\nVerified Elasticsearch documents:\n'
for item in $summary_items; do
  document="$ARTIFACT_DIR/$item.json"
  printf '%-16s id=%s service=%s trace.id=%s span.id=%s\n' \
    "$item" \
    "$(field "$document" '._id')" \
    "$(field "$document" '._source."service.name" // ._source.resource.attributes."service.name"')" \
    "$(field "$document" '._source."trace.id" // ._source.trace_id')" \
    "$(field "$document" '._source."span.id" // ._source.span_id')"
done

if [[ "${E2E_VERIFY_ONLY:-0}" == "1" ]]; then
  echo "Verification-only evidence inspection passed; this is not a fresh acceptance run."
else
  echo "Local React Native $PLATFORM demo E2E verification passed."
fi
