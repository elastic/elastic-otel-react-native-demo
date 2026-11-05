# Local E2E verification

These scripts need Python 3, `curl`, and `jq` in addition to the demo prerequisites.

## Run the hosted CI path locally

The CI entry point starts a fresh stack, builds the Release app, drives the UI, verifies telemetry,
and cleans up its own processes. It refuses to replace services already listening on ports 9200,
4318, or 8080. Start with `npm ci`.

Read the shared Elastic version pin from the workflow:

```sh
export ELASTIC_VERSION=$(ruby -ryaml -e 'puts YAML.load_file(".github/workflows/ci.yml")["env"]["ELASTIC_VERSION"]')
```

For Android, start one emulator and Docker, then run:

```sh
bash scripts/e2e/ci.sh android
```

For iOS, use macOS with Xcode, its matching iOS Simulator runtime, CocoaPods, and JDK 21.
Read the backend download pin from the workflow, then run:

```sh
export BACKEND_VERSION=$(ruby -ryaml -e 'puts YAML.load_file(".github/workflows/ci.yml")["env"]["BACKEND_VERSION"]')
bash scripts/e2e/ci.sh ios
```

The iOS path creates and deletes its own simulator. It downloads checksum-verified native
Elasticsearch and Elastic Agent archives and the backend JAR into `.ci-cache/`. Docker is not
needed for that path. The collector configuration is `scripts/e2e/otel.yml`.
See [CI documentation](../../.github/CI.md) for jobs, dependency automation, and diagnostics.

## Build and launch the release app

`npm run android:check` runs the package's `setup-android` command and fails if it changes
anything under `android/`. Check the Android setup, build the release APK, and install and launch
it on the running emulator:

```sh
npm run android:check
npm run android:build
./scripts/e2e/launch-app.sh android
```

`npm run ios:check` runs the package's `setup-ios` command, fails if it changes anything under
`ios/`, checks iOS autolinking and Swift formatting, and installs the pods from the lockfile. Check
the iOS setup and build the release app for the iOS Simulator:

```sh
npm run ios:install
npm run ios:check
npm run ios:build
```

With one simulator booted, install and launch that release app:

```sh
./scripts/e2e/launch-app.sh ios
```

`launch-app.sh` installs the built release app with `adb` or `xcrun simctl`, forwards the Android
emulator's OTLP port with `adb reverse tcp:4318 tcp:4318`, and launches the app.

## Run the verifier

Use a fresh `start-local` data set. Start the stack and backend, build the release app for the
selected platform, then run:

```sh
set -a
source elastic-start-local/.env
set +a

npm run android:build
./scripts/e2e/verify.sh \
  android \
  http://localhost:9200 \
  "$ES_LOCAL_API_KEY"
```

For iOS, boot exactly one simulator first:

```sh
npm run ios:check
npm run ios:build
./scripts/e2e/verify.sh \
  ios \
  http://localhost:9200 \
  "$ES_LOCAL_API_KEY"
```

Set `IOS_SIMULATOR_UDID` when more than one simulator is booted. The verifier
first refuses any existing `weather-demo-react-native` or
`weather-demo-backend` documents. It then installs and launches the built
release app with `launch-app.sh` and tells you when to fetch Berlin
successfully and New York unsuccessfully. You perform the UI actions on both
platforms, so both exercise the same visible app behavior.

### Automatic UI step hook

Set `E2E_STEP_COMMAND` to a trusted shell command to run UI steps without operator input.
The verifier appends one final argument: `berlin`, `new-york`, or `crash`.
It exports the selected device as `E2E_DEVICE_ID`. A nonzero command exit fails verification
and names the failed step. For example, with a fresh stack and the built Android app:

```sh
E2E_STEP_COMMAND="python3 scripts/e2e/android-step.py" \
  scripts/e2e/verify.sh android "$ES_LOCAL_URL" "$ES_LOCAL_API_KEY"
```

For iOS, set `IOS_SIMULATOR_UDID` if multiple simulators are booted:

```sh
E2E_STEP_COMMAND="bash scripts/e2e/ios-step.sh" \
  scripts/e2e/verify.sh ios "$ES_LOCAL_URL" "$ES_LOCAL_API_KEY"
```

The Android driver reads the UI hierarchy and taps visible city text and existing button
identifiers or labels. The standalone `scripts/e2e/ios/Driver.xcodeproj` has no host app and
addresses the installed demo by bundle ID. Its runner builds once and selects one test per step.
Neither driver changes app labels or identifiers. The verifier owns crash detection and relaunch.

With the hook unset, the two forecast steps accept operator input or wait for
`berlin-complete` and `new-york-complete` files under `E2E_MARKER_DIR`. The crash step waits for
the operator to crash the app. A hook takes precedence over markers. To exercise failure
diagnostics, set `E2E_STEP_COMMAND="exit 1"` against a fresh stack and built app.

On both platforms, the verifier then asks you to press **Crash**. It waits
until the app process exits: on Android, `adb shell pidof co.elastic.edot.reactnative.demo`
returns nothing; on iOS, `xcrun simctl spawn <udid> launchctl list` shows no
running `UIKitApplication:co.elastic.edot.reactnative.demo` job. It then confirms that no
crash record was exported before the relaunch, relaunches the app with `launch-app.sh`, and
waits for the `app.crash` record that the native EDOT SDK exports on the next
launch. It fails with a message that says whether the process did not exit or
the crash record did not arrive.
The crash freshness check accepts ISO timestamps and Elasticsearch epoch-millisecond timestamps.

For a repeated run against local loopback Elasticsearch, set
`E2E_LOCAL_RERUN=1`. This mode deletes only documents whose exact service name
is `weather-demo-react-native` or `weather-demo-backend`; it refuses cleanup
unless the parsed endpoint host is exactly `localhost`, `127.0.0.1`, or `::1`.
The scheme (`http://` or `https://`) and port are optional; bracket IPv6 when
specifying its scheme or port. Paths, userinfo, credentials, and deceptive hosts
are refused before any deletion request.

`E2E_VERIFY_ONLY=1` skips freshness, app launch, and operator actions. It reports
only an evidence-inspection result and never fresh acceptance.

The verifier polls Elasticsearch for up to three minutes per assertion. It
checks the startup root/child relationship, the startup instrumentation scope
`@elastic/otel-react-native` and the `deployment.environment.name=local` and
`service.namespace=weather-demo` resource attributes from
`elastic-otel-config.json` on both platforms, the correlated startup log, independent
ERROR log, automatic `fetch-forecast-button` and `forecast-back-button`
`app.widget.click` EventRecords, backend span, auto-instrumented app HTTP span sharing the backend's
`trace.id`, exactly one Berlin app HTTP span on both platforms, the New York app HTTP span's
`http.response.status_code` of 500 on both platforms, no iOS app span with URL path
`/config/v1/agents`, and the `app.crash` record with `exception.type`,
`session.id`, and an `exception.stacktrace` containing the intentional crash
message. It accepts both the Android and the iOS event-name representation in
Elasticsearch. For the ERROR log, it matches only the phrase
`Forecast request failed:` in the log body and does not check the backend's
HTTP status.

Matching documents are written to `build/e2e/`. Every failure also captures
verifier output, cluster health, backend logs, container state, and either
Android logcat or iOS Simulator logs. Run `npm run e2e:test` to exercise the URL
safety guard, both launch paths, and the crash scenario on both platforms.
