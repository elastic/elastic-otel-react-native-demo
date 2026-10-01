const path = require('path');
const { getDefaultConfig } = require('@react-native/metro-config');

const projectRoot = __dirname;
const localPackageRoot = path.dirname(
  require.resolve('@elastic/otel-react-native/package.json'),
);
const config = getDefaultConfig(projectRoot);

config.watchFolders = [localPackageRoot];
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, 'node_modules')];

module.exports = config;
