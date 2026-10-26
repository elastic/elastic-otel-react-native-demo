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
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// package-lock.json must be exactly what npm regenerates from package.json.
// The demo links the bridge through a `file:` dependency, and the lockfile
// copies that package's metadata, so the check also copies each linked
// package.json to the same relative path. It regenerates in a temporary
// copy and never edits the worktree.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FIX = 'npm install --package-lock-only';

const packageJson = JSON.parse(
  await readFile(join(ROOT, 'package.json'), 'utf8'),
);
const linked = Object.values({
  ...packageJson.dependencies,
  ...packageJson.devDependencies,
})
  .filter(specifier => specifier.startsWith('file:'))
  .map(specifier => resolve(ROOT, specifier.slice('file:'.length)));

const scratch = await mkdtemp(join(tmpdir(), 'edot-rn-demo-lockfile-'));
let stale = false;
try {
  const copy = join(scratch, basename(ROOT));
  await mkdir(copy);
  for (const file of ['package.json', 'package-lock.json']) {
    await cp(join(ROOT, file), join(copy, file));
  }
  for (const directory of linked) {
    const target = join(copy, relative(ROOT, directory));
    await mkdir(target, { recursive: true });
    await cp(join(directory, 'package.json'), join(target, 'package.json'));
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
    `package-lock.json is out of date with package.json or a linked package (run \`${FIX}\`).`,
  );
  process.exitCode = 1;
} else {
  console.log('package-lock.json matches package.json.');
}
