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
