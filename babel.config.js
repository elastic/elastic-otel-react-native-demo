module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: [
    [
      '@elastic/otel-react-native/babel-plugin',
      { includeAccessibilityLabel: true },
    ],
  ],
};
