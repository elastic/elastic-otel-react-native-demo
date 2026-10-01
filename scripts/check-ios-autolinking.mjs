import { spawnSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cli = join(repositoryRoot, 'node_modules', '.bin', 'react-native');
const result = spawnSync(cli, ['config'], {
  cwd: repositoryRoot,
  encoding: 'utf8',
});

if (result.status !== 0) {
  throw new Error(
    result.stderr || result.stdout || 'React Native config failed.',
  );
}

const config = JSON.parse(result.stdout);
const project = config.project?.ios;
const dependency =
  config.dependencies?.['@elastic/otel-react-native']?.platforms?.ios;
const expectedSourceDirectory = realpathSync(join(repositoryRoot, 'ios'));

if (!project || realpathSync(project.sourceDir) !== expectedSourceDirectory) {
  throw new Error('React Native did not discover the demo iOS project.');
}
if (
  project.xcodeProject?.name !== 'ReactNativeDemoApp.xcworkspace' ||
  project.xcodeProject?.isWorkspace !== true
) {
  throw new Error('React Native did not select the CocoaPods workspace.');
}
if (
  !dependency?.podspecPath ||
  !dependency.podspecPath.endsWith('ElasticOtelReactNative.podspec') ||
  !existsSync(dependency.podspecPath)
) {
  throw new Error('The EDOT React Native iOS podspec was not autolinked.');
}

console.log('React Native iOS workspace and SDK autolinking passed.');
