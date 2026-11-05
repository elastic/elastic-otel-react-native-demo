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

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const body = `Copyright Elastic Technologies Inc. and/or licensed to
Elastic Technologies Inc. under one or more contributor license
agreements. See the NOTICE file distributed with this work for
additional information regarding copyright ownership.
Elastic Technologies Inc. licenses this file to you under the Apache
License, Version 2.0 (the "License"); you may not use this file except
in compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.`;
const lines = body.split('\n');
const headers = {
  block: `/*\n${lines
    .map(line => (line ? ` * ${line}` : ' *'))
    .join('\n')}\n */\n\n`,
  slash: `${lines.map(line => (line ? `// ${line}` : '//')).join('\n')}\n\n`,
  hash: `${lines.map(line => (line ? `# ${line}` : '#')).join('\n')}\n\n`,
  xml: `<!--\n${body}\n-->\n\n`,
};

function classify(path) {
  const name = basename(path);
  const extension = extname(path);
  if (path === 'android/app/src/main/res/drawable/rn_edit_text_material.xml') {
    return 'xml';
  }
  if (
    ['gradlew', 'gradlew.bat'].includes(name) ||
    /(^|\/)gradle\/wrapper\//.test(path)
  ) {
    return null;
  }
  if (/\.(ts|tsx|js|cjs|mjs|cts|kt|m|gradle)$/.test(path)) return 'block';
  if (extension === '.swift') return 'slash';
  if (
    /\.(sh|py|rb|podspec)$/.test(path) ||
    ['Podfile', 'Gemfile', 'backend-manager'].includes(name) ||
    /^\.github\/workflows\/[^/]+\.yml$/.test(path) ||
    /^(?:\.ci\/updatecli|scripts\/e2e)\/[^/]+\.yml$/.test(path)
  ) {
    return 'hash';
  }
  if (
    [
      'LICENSE',
      'NOTICE.txt',
      '.gitignore',
      '.npmignore',
      '.node-version',
      '.watchmanconfig',
      '.gitattributes',
      'Package.resolved',
      'Gemfile.lock',
      'Podfile.lock',
    ].includes(name) ||
    path === '.github/CODEOWNERS' ||
    /^docs\/.*\.yml$/.test(path) ||
    /\.(json|md|env|properties|pro|storyboard|plist|xcprivacy|pbxproj|xcscheme|xcworkspacedata|excalidraw|png|jpg|jpeg|gif|svg|webp|ico|jar|keystore)$/.test(
      path,
    ) ||
    (extension === '.xml' && path.includes('/src/') && path.includes('/main/'))
  ) {
    return null;
  }
  throw new Error('unclassified tracked file');
}

function splitFirstLine(source) {
  if (/^(#!|\/\/ swift-tools-version:|<\?xml)/.test(source)) {
    const end = source.indexOf('\n');
    if (end === -1) return [source + '\n', ''];
    return [source.slice(0, end + 1), source.slice(end + 1)];
  }
  return ['', source];
}

// Only consume an exact canonical prefix with one deleted line. Never search
// for a later comment closer: it could occur after unrelated source code.
function contentAfterHeader(source, style) {
  const header = headers[style];
  const headerLines = header.match(/[^\n]*\n/g);
  const suffixes = new Set();
  for (let deleted = 0; deleted < headerLines.length; deleted++) {
    const partial = headerLines
      .filter((_, index) => index !== deleted)
      .join('');
    if (source.startsWith(partial)) suffixes.add(source.slice(partial.length));
  }
  if (suffixes.size > 1) {
    throw new Error('ambiguous malformed license header; repair manually');
  }
  if (suffixes.size === 1) return suffixes.values().next().value;

  // Recognizable Elastic fragments without a supported shape need a manual
  // correction. Ordinary comments, including company mentions, stay intact.
  const leading = source.slice(0, header.length);
  if (
    headerLines.some(
      line =>
        line.includes('Elastic Technologies Inc.') && leading.includes(line),
    )
  ) {
    throw new Error('unrecognized malformed license header; repair manually');
  }
  return source;
}

const fix = process.argv.includes('--fix');
if (process.argv.slice(2).some(arg => arg !== '--fix')) {
  throw new Error('Usage: node scripts/check-license-headers.mjs [--fix]');
}
const paths = execFileSync('git', ['ls-files', '-z'], {
  cwd: root,
  encoding: 'utf8',
})
  .split('\0')
  .filter(Boolean);
const failures = [];
let checked = 0;
for (const path of paths) {
  try {
    const style = classify(path);
    if (!style) continue;
    checked++;
    const filename = resolve(root, path);
    const source = readFileSync(filename, 'utf8');
    if (source.includes('\r\n')) {
      throw new Error(
        'LF line endings required; convert this file to LF before repairing headers',
      );
    }
    const [first, rest] = splitFirstLine(source);
    const header = headers[style];
    if (rest.startsWith(header)) continue;
    if (fix) {
      const content = contentAfterHeader(rest, style);
      const suffix =
        first && content === rest && content.startsWith('\n')
          ? content.slice(1)
          : content;
      writeFileSync(filename, first + header + suffix);
    } else {
      failures.push(`${path}: missing or incorrect license header`);
    }
  } catch (error) {
    failures.push(`${path}: ${error.message}`);
  }
}
if (failures.length) {
  console.error(failures.join('\n'));
  process.exitCode = 1;
} else {
  console.log(
    `License headers ${
      fix ? 'fixed' : 'checked'
    } in ${checked} tracked source files.`,
  );
}
