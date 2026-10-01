#!/bin/sh

set -eu

npm run lockfile:check
npm run format:check
npm run lint
npm run typecheck
npm test -- --runInBand
npm run e2e:test
npm run android:check
npm run android:build
npm run ios:check
npm run ios:build
