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
const { mkdtempSync, readFileSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { delimiter, join } = require('node:path');
const { selectReactVersion } = require('../.ci/updatecli/update-package.js');

test('selects the highest stable React release satisfying the peer range', () => {
  expect(
    selectReactVersion(
      ['19.2.3', '20.0.0', '19.10.0', '19.3.0', '19.11.0-rc.1'],
      '^19.2.3',
    ),
  ).toBe('19.10.0');
});

test('honors disjoint peer ranges without selecting a prerelease', () => {
  expect(
    selectReactVersion(['18.3.2', '19.2.3', '19.4.0-rc.1'], '^18.3 || 19.2.3'),
  ).toBe('19.2.3');
});

test('fails when no stable React release satisfies the peer range', () => {
  expect(() => selectReactVersion(['19.0.0-rc.1', '18.3.2'], '^19')).toThrow(
    'No stable React version satisfies',
  );
});

test.each([
  ['react-native', '0.88.0', '19.3.1'],
  ['@elastic/otel-react-native', '0.2.0', '19.2.3'],
])(
  'updates %s without splitting React and renderer pins',
  (name, version, react) => {
    const directory = mkdtempSync(join(tmpdir(), 'demo-dependency-update-'));
    const manifest = {
      dependencies: {
        '@elastic/otel-react-native': '0.1.0',
        react: '19.2.3',
        'react-native': '0.87.1',
        'react-native-safe-area-context': '5.9.1',
      },
      devDependencies: {
        'react-test-renderer': '19.2.3',
        jest: '29.7.0',
      },
    };
    try {
      writeFileSync(join(directory, 'package.json'), JSON.stringify(manifest));
      writeFileSync(
        join(directory, 'npm'),
        `#!/usr/bin/env node
const [command, name, field] = process.argv.slice(2);
if (command !== 'view') process.exit(1);
if (name === 'react-native@0.88.0' && field === 'peerDependencies.react') {
  console.log(JSON.stringify('^19.2.3'));
} else if (name === 'react' && field === 'versions') {
  console.log(JSON.stringify(['19.2.3', '19.3.1', '19.4.0-rc.1', '20.0.0']));
} else {
  process.exit(1);
}
`,
        { mode: 0o755 },
      );
      execFileSync(
        process.execPath,
        [join(__dirname, '../.ci/updatecli/update-package.js'), name, version],
        {
          cwd: directory,
          env: {
            ...process.env,
            PATH: `${directory}${delimiter}${process.env.PATH}`,
          },
        },
      );
      expect(
        JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')),
      ).toEqual({
        ...manifest,
        dependencies: { ...manifest.dependencies, [name]: version, react },
        devDependencies: {
          ...manifest.devDependencies,
          'react-test-renderer': react,
        },
      });
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  },
);
