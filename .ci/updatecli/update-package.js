/*
 * Copyright Elastic Technologies Inc. and/or licensed to
 * Elastic Technologies Inc. under one or more contributor license
 * agreements. See the NOTICE file distributed with this work for
 * additional information regarding copyright ownership.
 * Elastic Technologies Inc. licenses this file to you under the Apache
 * License, Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

const { execFileSync } = require('node:child_process');
const { readFileSync, writeFileSync } = require('node:fs');
const semver = require('semver');

function selectReactVersion(versions, range) {
  const stable = versions.filter(
    version => semver.prerelease(version) === null,
  );
  const version = semver.maxSatisfying(stable, range);
  if (!version) {
    throw new Error(`No stable React version satisfies ${range}.`);
  }
  return version;
}

function npmView(...args) {
  return JSON.parse(
    execFileSync('npm', ['view', ...args, '--json'], { encoding: 'utf8' }),
  );
}

if (require.main === module) {
  const [name, version] = process.argv.slice(2);
  const manifest = JSON.parse(readFileSync('package.json', 'utf8'));
  if (
    ![
      '@elastic/otel-react-native',
      'react-native',
      'react-native-safe-area-context',
    ].includes(name) ||
    !semver.valid(version)
  ) {
    throw new Error('Usage: update-package.js <owned-package> <version>');
  }
  if (name === 'react-native') {
    const range = npmView(`react-native@${version}`, 'peerDependencies.react');
    manifest.dependencies.react = selectReactVersion(
      npmView('react', 'versions'),
      range,
    );
  }
  manifest.dependencies[name] = version;
  writeFileSync('package.json', JSON.stringify(manifest, null, 2) + '\n');
}

module.exports = { selectReactVersion };
