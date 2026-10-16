# Local E2E verification

Use a fresh `start-local` data set. Start the stack and backend, build the
release app for the selected platform, then run:

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
release app with `adb` or `xcrun simctl`, forwards the Android emulator's
OTLP port with `adb reverse tcp:4318 tcp:4318`, and tells you when to fetch Berlin
successfully and New York unsuccessfully. The UI actions remain operator-driven
so both platforms exercise the same visible app behavior.

On both platforms, the verifier then asks you to press **Crash**. It waits
until the app process exits: on Android, `adb shell pidof com.reactnativedemoapp`
returns nothing; on iOS, `xcrun simctl spawn <udid> launchctl list` shows no
running `UIKitApplication:com.reactnativedemoapp` job. It then confirms that no
crash record was exported before the relaunch, relaunches the app with `launch-app.sh`, and
waits for the `app.crash` record that the native EDOT SDK exports on the next
launch. It fails with a message that says whether the process did not exit or
the crash record did not arrive.

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
`trace.id`, and the `app.crash` record with `exception.type`,
`session.id`, and an `exception.stacktrace` containing the intentional crash
message. It accepts the compatible Android and iOS event-name
representations instead of requiring one Elasticsearch field layout. For the
ERROR log, it matches only the phrase `Forecast request failed:` in the log
body and does not check the backend's HTTP status, so a backend status change
needs only the unit tests in `__tests__/App.test.tsx` updated.

Matching documents are written to `build/e2e/`. Every failure also captures
verifier output, cluster health, backend logs, container state, and either
Android logcat or iOS Simulator logs. Run `npm run e2e:test` to exercise the URL
safety guard, both launch paths, and the crash scenario on both platforms with
focused command mocks.
