# EDOT React Native demo

This demo shows the `@elastic/otel-react-native` bridge over
[EDOT Android](https://www.elastic.co/docs/reference/opentelemetry/edot-sdks/android)
and
[EDOT iOS](https://www.elastic.co/docs/reference/opentelemetry/edot-sdks/ios).
Choose a city, request its weather through a local instrumented backend, and
inspect the resulting spans, logs, and interaction events in Elastic.

`package.json` and `android/build.gradle` pin the React Native and EDOT Android
versions the demo is validated with.

## Related project

This demo uses the
[`@elastic/otel-react-native` SDK](https://github.com/elastic/elastic-otel-react-native).
Start with that repository for the bridge API, installation command, and SDK
reference documentation.

## Table of contents

- [What you can observe](#what-you-can-observe)
- [Components](#components)
  - [Backend service](#backend-service)
  - [React Native application](#react-native-application)
  - [Elastic Agent](#elastic-agent)
- [Prerequisites](#prerequisites)
- [Run the demo](#run-the-demo)
  - [1. Start the Elastic Stack](#1-start-the-elastic-stack)
  - [2. Start the instrumented backend](#2-start-the-instrumented-backend)
  - [3. Install the local SDK](#3-install-the-local-sdk)
  - [4. Run Android](#4-run-android)
  - [5. Run iOS](#5-run-ios)
- [Inspect the data](#inspect-the-data)
- [Emulator, simulator, and physical-device networking](#emulator-simulator-and-physical-device-networking)
- [Limitations](#limitations)
- [License](#license)

## What you can observe

- A `Creating app` root span and `Initialize React Native UI` child span.
- A `During app creation` log correlated with the child span.
- An independent ERROR log when the backend rejects New York.
- A non-blocking `app.widget.click` EventRecord when you press **Fetch
  forecast**.
- An automatically instrumented app HTTP span that propagates W3C trace context
  to `weather-demo-backend`.
- Native automatic instrumentation owned by EDOT Android or EDOT iOS.

## Components

![The app and backend send telemetry through an OTLP endpoint to Elasticsearch.](assets/components.png)

### Backend service

The released backend from
[`elastic/shared-otel-sdk-demo`](https://github.com/elastic/shared-otel-sdk-demo/tree/main/backend)
serves `GET /v1/forecast?city=<name>`. It fetches Open-Meteo data for Berlin,
London, and Paris, and intentionally rejects New York.

### React Native application

The app uses plain React Native `fetch`. Android routes local requests through
`10.0.2.2`; the iOS Simulator uses `localhost`. EDOT Android's OkHttp
instrumentation and EDOT iOS's URLSession instrumentation own the app HTTP span
and W3C propagation. There is no manual request span.

Native initialization in
[`MainApplication.kt`](android/app/src/main/java/com/reactnativedemoapp/MainApplication.kt)
and [`AppDelegate.swift`](ios/ReactNativeDemoApp/AppDelegate.swift) runs before
React Native loads. Android reads
[`elastic-otel-config.json`](elastic-otel-config.json), which the package's
Gradle script copies into the app assets at build time. It configures
OTLP/HTTP to `http://localhost:4318`, service name
`weather-demo-react-native`, `deployment.environment.name=local`,
`service.namespace=weather-demo`, and full session sampling. iOS configures
OTLP/HTTP, the same service name, and full session sampling in code. On both
platforms, spans and logs created through the package use the instrumentation
scope `@elastic/otel-react-native`. Remote management is not configured.

The package Babel plugin instruments the static
`fetch-forecast-button` `Pressable` at build time. The app contains no manual
tap telemetry. `app.widget.click`, `app.widget.id`, and `app.widget.name` are
Development OpenTelemetry semantic conventions and can change before
stabilization.

### Elastic Agent

The
[Elastic Agent](https://www.elastic.co/docs/reference/fleet/elastic-agent-as-otel-collector)
provides the local OTLP endpoint and forwards telemetry to Elasticsearch.

## Prerequisites

- Node.js 22.11 or newer and npm.
- Python 3, `curl`, and `jq`.
- Docker for the local Elastic Stack and backend.
- A sibling checkout of `../elastic-otel-react-native`.
- For Android: JDK 21, Android SDK tooling, and an API 26-or-newer emulator.
- For iOS: macOS, Xcode 26.6, CocoaPods 1.16.2, and an iOS 16-or-newer
  simulator.

## Run the demo

### 1. Start the Elastic Stack

Use [start-local](https://github.com/elastic/start-local) to start
Elasticsearch, Kibana, and an Elastic Agent OTLP endpoint:

```sh
curl -fsSL https://elastic.co/start-local | sh -s -- --edot
```

The OTLP/HTTP endpoint is available at `http://localhost:4318`. The iOS
Simulator reaches it directly. The Android app also exports to
`http://localhost:4318`; forward that port from the emulator to the host
before you launch the app:

```sh
adb reverse tcp:4318 tcp:4318
```

### 2. Start the instrumented backend

Run this command from the repository root:

```sh
./backend-manager start
```

The backend is available to the host and iOS Simulator at
`http://localhost:8080/v1`. Android reaches it at
`http://10.0.2.2:8080/v1`.

Use these commands when needed:

```sh
./backend-manager logs
./backend-manager stop
./backend-manager uninstall
```

### 3. Install the local SDK

Install the sibling SDK checkout:

```sh
npm install ../elastic-otel-react-native
```

### 4. Run Android

Verify the deterministic Android setup, build the release APK, install it, and
launch it:

```sh
npm run android:check
npm run android:build
adb install -r android/app/build/outputs/apk/release/app-release.apk
adb reverse tcp:4318 tcp:4318
adb shell am start -n com.reactnativedemoapp/.MainActivity
```

For an interactive debug build with Metro, forward the OTLP port first:

```sh
adb reverse tcp:4318 tcp:4318
npm run android
```

`adb reverse` lasts until the emulator restarts or adb reconnects. Run it again
after either.

### 5. Run iOS

Apply the deterministic iOS setup and install the CocoaPods workspace:

```sh
npm run ios:install
npm run ios:check
```

Build the release app for the iOS Simulator:

```sh
npm run ios:build
```

With one simulator booted, install and launch that release app:

```sh
./scripts/e2e/launch-app.sh ios
```

For an interactive debug build with Metro, run:

```sh
npm run ios:run
```

On either platform, select Berlin, London, or Paris for a successful forecast.
Return to the city picker and select New York to exercise the backend error and
independent ERROR log. Loading, success, error, and retry states remain
available in the app.

## Inspect the data

Open Kibana at <http://localhost:5601> and sign in with the credentials printed
by start-local. Look for:

- `weather-demo-react-native`
- `weather-demo-backend`
- `Creating app`
- `Initialize React Native UI`
- `During app creation`
- `otel.event.name=app.widget.click` or the platform-compatible event-name
  representation, with `app.widget.id=fetch-forecast-button`

For repeatable document-level checks on either platform, follow
[`scripts/e2e/README.md`](scripts/e2e/README.md). The shared verifier installs
and launches the selected release app, then checks parent, trace, and log
correlation IDs, the independent ERROR log, the automatic widget-click
EventRecord, and the app/backend distributed trace. On Android it then asks you
to press **Crash** and checks the `app.crash` record exported on the next
launch.

For more information, see the Android and iOS **Visualize telemetry** guidance:

- [Android](https://www.elastic.co/docs/reference/opentelemetry/edot-sdks/android/getting-started#visualize-telemetry)
- [iOS](https://www.elastic.co/docs/reference/opentelemetry/edot-sdks/ios/getting-started#visualize-telemetry)

## Emulator, simulator, and physical-device networking

The Android app sends OTLP to `localhost:4318`, which `adb reverse` forwards to
the development machine, and reaches the backend through the emulator's
`10.0.2.2` host alias. The iOS configuration uses `localhost`, which resolves
to the development Mac from the iOS Simulator. Android network security and iOS App Transport Security
allow only the local clear-text development paths needed by this demo.

A physical device cannot use these simulator-specific assumptions. Replace the
OTLP URL in `elastic-otel-config.json` (Android) or `AppDelegate.swift` (iOS)
and the backend URL with the development machine's LAN address, update the
platform network policy where necessary, and ensure ports `4318` and `8080` are
reachable. Do not carry this local clear-text configuration into production.

## Limitations

- The iOS host adopts the UIScene lifecycle, which the stock React Native
  template lacks, because Xcode 27 builds terminate at launch on iOS 27
  without it. Otherwise the demo follows the stock template host shape.
- The **Crash** button throws an uncaught JavaScript error. The shared verifier
  asserts its `app.crash` export on Android only; iOS crash export is not
  asserted.
- Android requires API 26 or later.
- The checked-in iOS workflow targets a simulator. Physical-device execution
  needs signing and LAN endpoint configuration.
- Automatic tap events cover only supported standard React Native `Button` and
  `Pressable` handlers with static `testID` values.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
