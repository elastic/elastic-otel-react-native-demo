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

import { spawnSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// package-lock.json must be exactly what npm regenerates from package.json.
// Regenerate in an isolated copy without editing the committed lockfile.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FIX = 'npm install --package-lock-only';

await mkdir(join(ROOT, 'build'), { recursive: true });
const scratch = await mkdtemp(join(ROOT, 'build', 'lockfile-'));
let stale = false;
try {
  const copy = scratch;
  for (const file of ['package.json', 'package-lock.json']) {
    await cp(join(ROOT, file), join(copy, file));
  }
  const run = spawnSync(
    'npm',
    [
      'install',
      '--package-lock-only',
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
    ],
    { cwd: copy, encoding: 'utf8' },
  );
  if (run.status !== 0) {
    throw new Error(
      `npm could not regenerate package-lock.json:\n${run.stderr}`,
    );
  }
  const [committed, regenerated] = await Promise.all([
    readFile(join(ROOT, 'package-lock.json'), 'utf8'),
    readFile(join(copy, 'package-lock.json'), 'utf8'),
  ]);
  stale = committed !== regenerated;
} finally {
  await rm(scratch, { recursive: true, force: true });
}

if (stale) {
  console.error(
    `package-lock.json is out of date with package.json (run \`${FIX}\`).`,
  );
  process.exitCode = 1;
} else {
  console.log('package-lock.json matches package.json.');
}
