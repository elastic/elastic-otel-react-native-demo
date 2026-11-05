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
platform="${1:-}"
if [[ "$platform" != android && "$platform" != ios ]]; then
  echo "Usage: $0 <android|ios>" >&2
  exit 1
fi
: "${ELASTIC_VERSION:?Set ELASTIC_VERSION from .github/workflows/ci.yml}"
export E2E_ARTIFACT_DIR="$ROOT/build/e2e"
mkdir -p "$E2E_ARTIFACT_DIR" "$ROOT/build/tmp"
export TMPDIR="$ROOT/build/tmp"
exec > >(tee "$E2E_ARTIFACT_DIR/ci.log") 2>&1
backend_pid=""
collector_pid=""
elasticsearch_pid=""
simulator=""
docker_started=0

cleanup() {
  status=$?
  trap - EXIT
  set +e
  local curl_args=(-sS)
  if [[ "$platform" == android && -n "${ES_LOCAL_API_KEY:-}" ]]; then
    curl_args+=(-H "Authorization: ApiKey $ES_LOCAL_API_KEY")
  fi
  curl "${curl_args[@]}" http://localhost:9200/_cluster/health >"$E2E_ARTIFACT_DIR/cluster-health.json"
  for signal in traces logs; do
    curl "${curl_args[@]}" \
      -H "Content-Type: application/json" \
      -d '{"size":100,"sort":[{"@timestamp":{"order":"desc","unmapped_type":"date"}}]}' \
      "http://localhost:9200/$signal-*/_search?ignore_unavailable=true" \
      >"$E2E_ARTIFACT_DIR/recent-$signal.json"
  done
  if [[ "$platform" == android ]]; then
    adb logcat -d >"$E2E_ARTIFACT_DIR/logcat.txt" 2>&1
    adb shell am force-stop co.elastic.edot.reactnative.demo
    if [[ "$docker_started" == 1 ]]; then
      docker logs react-native-weather-backend >"$E2E_ARTIFACT_DIR/backend.log" 2>&1
      if [[ -n "${ES_LOCAL_CONTAINER_NAME:-}" ]]; then
        docker logs "$ES_LOCAL_CONTAINER_NAME" >"$E2E_ARTIFACT_DIR/elasticsearch.log" 2>&1
      fi
      if [[ -n "${EDOT_LOCAL_CONTAINER_NAME:-}" ]]; then
        docker logs "$EDOT_LOCAL_CONTAINER_NAME" >"$E2E_ARTIFACT_DIR/collector.log" 2>&1
      fi
      docker ps -a >"$E2E_ARTIFACT_DIR/docker-ps.txt" 2>&1
      ./backend-manager stop
      (cd elastic-start-local && ./stop.sh)
    fi
  elif [[ -n "$simulator" ]]; then
    xcrun simctl spawn "$simulator" log show --style compact --info --debug --last 10m \
      --predicate 'process == "ReactNativeDemoApp"' >"$E2E_ARTIFACT_DIR/ios-simulator.log" 2>&1
    xcrun simctl shutdown "$simulator"
    xcrun simctl delete "$simulator"
  fi
  for pid in "$backend_pid" "$collector_pid" "$elasticsearch_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
  done
  rm -rf "$ROOT/build/e2e-runtime"
  exit "$status"
}

# Refuse to replace an environment that another local run might own.
python3 - <<'PY'
import socket
for port in (9200, 4318, 8080):
    with socket.socket() as connection:
        if connection.connect_ex(("127.0.0.1", port)) == 0:
            raise SystemExit(f"Port {port} is already in use; stop its owner before running CI locally.")
PY
trap cleanup EXIT

wait_url() {
  local url="$1"
  for _ in {1..90}; do
    if curl -fsS "$url" >/dev/null 2>&1; then return; fi
    sleep 2
  done
  echo "Timed out waiting for $url" >&2
  return 1
}

download_verified() {
  local url="$1" file="$2" algorithm="$3"
  if [[ ! -f "$file" ]]; then
    curl -fL --retry 3 -o "$file" "$url"
  fi
  if [[ ! -f "$file.sha$algorithm" ]]; then
    curl -fL --retry 3 -o "$file.sha$algorithm" "$url.sha$algorithm"
  fi
  local expected actual
  expected=$(awk '{print $1}' "$file.sha$algorithm")
  actual=$(shasum -a "$algorithm" "$file" | awk '{print $1}')
  if [[ "$expected" != "$actual" ]]; then
    echo "Checksum verification failed for $file" >&2
    return 1
  fi
}

if [[ "$platform" == android ]]; then
  docker_started=1
  curl -fsSL https://elastic.co/start-local | sh -s -- -v "$ELASTIC_VERSION" --esonly --edot
  set -a
  source elastic-start-local/.env
  set +a
  ./backend-manager start
  npm run android:build
  export E2E_STEP_COMMAND="python3 scripts/e2e/android-step.py"
  scripts/e2e/verify.sh android "$ES_LOCAL_URL" "$ES_LOCAL_API_KEY"
else
  : "${BACKEND_VERSION:?Set BACKEND_VERSION from .github/workflows/ci.yml}"
  case "$(uname -m)" in
    arm64) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "Unsupported macOS architecture." >&2; exit 1 ;;
  esac
  cache="$ROOT/.ci-cache"
  runtime="$ROOT/build/e2e-runtime"
  mkdir -p "$cache/elastic" "$cache/backend" "$runtime"
  es_archive="$cache/elastic/elasticsearch-$ELASTIC_VERSION-darwin-$arch.tar.gz"
  agent_archive="$cache/elastic/elastic-agent-$ELASTIC_VERSION-darwin-$arch.tar.gz"
  download_verified "https://artifacts.elastic.co/downloads/elasticsearch/$(basename "$es_archive")" "$es_archive" 512
  download_verified "https://artifacts.elastic.co/downloads/beats/elastic-agent/$(basename "$agent_archive")" "$agent_archive" 512
  tar -xzf "$es_archive" -C "$runtime"
  tar -xzf "$agent_archive" -C "$runtime"
  es_home="$runtime/elasticsearch-$ELASTIC_VERSION"
  agent_home="$runtime/elastic-agent-$ELASTIC_VERSION-darwin-$arch"
  xattr -dr com.apple.quarantine "$es_home" "$agent_home" 2>/dev/null || true
  ES_JAVA_OPTS="-Xms512m -Xmx512m" "$es_home/bin/elasticsearch" \
    -Ediscovery.type=single-node \
    -Expack.security.enabled=false \
    -Expack.security.autoconfiguration.enabled=false \
    -Expack.ml.enabled=false \
    -Ecluster.routing.allocation.disk.threshold_enabled=false \
    >"$E2E_ARTIFACT_DIR/elasticsearch.log" 2>&1 &
  elasticsearch_pid=$!
  wait_url http://localhost:9200
  ELASTIC_ENDPOINT=http://localhost:9200 "$agent_home/otelcol" \
    --config scripts/e2e/otel.yml >"$E2E_ARTIFACT_DIR/collector.log" 2>&1 &
  collector_pid=$!
  collector_ready=0
  for _ in {1..60}; do
    if nc -z 127.0.0.1 4318; then collector_ready=1; break; fi
    sleep 2
  done
  [[ "$collector_ready" == 1 ]] || { echo "OTLP endpoint did not start." >&2; exit 1; }
  jar="$cache/backend/backend-$BACKEND_VERSION.jar"
  download_verified \
    "https://github.com/elastic/shared-otel-sdk-demo/releases/download/backend/v$BACKEND_VERSION/$(basename "$jar")" "$jar" 256
  OTEL_SERVICE_NAME=weather-demo-backend \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    java -jar "$jar" >"$E2E_ARTIFACT_DIR/native-backend.log" 2>&1 &
  backend_pid=$!
  wait_url http://localhost:8080/v1/health
  # Match the runtime to the selected Xcode's simulator SDK.
  sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version | cut -d. -f1)
  runtime_json=$(xcrun simctl list runtimes -j | jq -c --arg major "$sdk_version" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-")) and
      (.version | split(".")[0]) == $major)] | sort_by(.version | split(".") | map(tonumber)) | last')
  runtime_id=$(jq -r '.identifier // empty' <<<"$runtime_json")
  device_type=$(jq -r \
    '[.supportedDeviceTypes[]? | select(.productFamily == "iPhone")] | first | .identifier // empty' \
    <<<"$runtime_json")
  [[ -n "$runtime_id" && -n "$device_type" ]] || { echo "No iPhone runtime matching Xcode." >&2; exit 1; }
  simulator=$(xcrun simctl create "React Native E2E" "$device_type" "$runtime_id")
  export IOS_SIMULATOR_UDID="$simulator"
  xcrun simctl boot "$simulator"
  xcrun simctl bootstatus "$simulator" -b
  npm run ios:install
  npm run ios:build
  export E2E_STEP_COMMAND="bash scripts/e2e/ios-step.sh"
  scripts/e2e/verify.sh ios http://localhost:9200 local-ci
fi
