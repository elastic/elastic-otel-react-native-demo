# Continuous integration

The `ci` workflow runs on every pull request and push to `main`.

| Job           | What it runs                                                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `changes`     | A Git diff excluding Markdown files; unknown comparison bases run all checks.                                                                                       |
| `checks`      | `./checks.sh` on `macos-latest`: headers, dependency resolution, formatting, lint, types, unit and verifier tests, native setup checks, and both Release builds.    |
| `e2e-android` | An unminified Release APK on a KVM-backed emulator, with start-local Elasticsearch and the Elastic Agent OTLP endpoint, plus `backend-manager`.                     |
| `e2e-ios`     | A Release app and standalone no-host XCUITest driver on a simulator matching Xcode, with native Elasticsearch, the bundled `otelcol`, and the released backend JAR. |
| `ci`          | The required gatekeeper, using `check-dependent-jobs` with skipped jobs treated as successful.                                                                      |

Markdown-only changes skip `checks` and both E2E jobs, but the workflow and its required `ci`
check run. A failed `changes` job fails the gatekeeper. Concurrent runs for the same ref cancel
older runs. Every macOS job uses the image's Xcode.

## Local checks

Install Node.js, JDK 21, the Android SDK, Xcode, and CocoaPods, then run:

```sh
npm ci
npm run ios:install
./checks.sh
```

The main check needs no manually started device or telemetry environment. Native setup checks
reject changes to the committed project inputs; regenerate and include intentional changes before
running them.

The E2E jobs use `scripts/e2e/ci.sh`, which owns stack startup, Release builds, UI automation,
verification, and cleanup. See [the E2E guide](../scripts/e2e/README.md) for local commands and
the optional verifier step hook.

## Diagnostics and version pins

Both E2E jobs upload `build/e2e/*` after success or failure, including when a UI hook fails.
The files contain the verifier output, matching Elasticsearch documents, process/stack logs, and
device logs. Android also records the last UI hierarchy; iOS records one XCUITest result bundle
per step. The CI wrapper retains the latest 100 trace and log documents in separate snapshots
without the verifier's attribute filters. Android includes Elasticsearch and collector container
logs; iOS simulator diagnostics include info/debug levels. Symbolication artifacts are not uploaded.

CI Node.js setup reads `.node-version`; each job declares its own setup action.
`ELASTIC_VERSION` and `BACKEND_VERSION` are pinned in `ci.yml`. The native iOS downloads are
cached separately by version, runner OS, and architecture, and verified against their published
SHA-512 or SHA-256 files on every use. The backend version also appears in `backend-manager`;
update those two pins together. Android's stack is installed by start-local with
`-v "$ELASTIC_VERSION" --esonly --edot`.

## Dependency updates

`.github/renovate.json` extends Elastic's configuration and keeps updates ungrouped. Renovate
ignores the packages owned by updatecli, their React peer, and its matching test renderer.

The weekday/dispatched `updatecli` workflow runs on macOS and uses a Vault ephemeral token.
It requires Backstage registration, repository bootstrap enabling Renovate, and the token policy
`token-policy-elastic-otel-react-native-demo-updatecli`, bound to
`elastic/elastic-otel-react-native-demo/.github/workflows/updatecli.yml@refs/heads/main`.
The exact workflow binding derives the policy automatically. The policy needs repository contents
and pull-request write access, so its PRs trigger CI.

One shared manifest, `.ci/updatecli/package.yml`, and three values files maintain one rolling PR
each for the bridge, React Native, and safe-area-context. Sources select the highest stable npm
version published at least seven days ago. A React Native update selects the highest stable React
version satisfying its new `peerDependencies.react` range and writes matching exact pins for
`react` and `react-test-renderer`.
`.ci/updatecli/update-package.js` owns that selection and manifest update.

Each pipeline installs dependencies, applies the exact pin, runs `npm install`, `setup-android`,
and `npm run ios:install`, and includes all resulting native/project/lockfile changes. A failed
command fails the pipeline without opening a partial PR. Live PR validation still depends on
the repository integrations above being enabled.
