const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// The SDK package is the parent directory (installed as file:..): let Metro
// watch it and resolve its dependencies from this app's node_modules, while
// ignoring the package's own node_modules symlink and its example copy.
const sdkRoot = path.resolve(__dirname, '..');
const config = {
  watchFolders: [sdkRoot],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    blockList: [new RegExp(`${sdkRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/(node_modules|lib|example/ios|example/android)/.*`)],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
