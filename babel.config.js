module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: [
    [
      '@elastic/otel-react-native/babel-plugin',
      {
        interactions: {
          components: [{ name: 'DemoButton', instrumentations: { click: {} } }],
        },
      },
    ],
  ],
};
