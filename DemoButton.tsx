import React from 'react';
import { Pressable, type PressableProps } from 'react-native';

type DemoButtonProps = Pick<
  PressableProps,
  | 'accessibilityLabel'
  | 'accessibilityRole'
  | 'children'
  | 'onPress'
  | 'style'
  | 'testID'
>;

// The app's own button component. babel.config.js lists it, so its taps
// record app.widget.click events like the React Native components do.
export function DemoButton({
  accessibilityLabel,
  accessibilityRole,
  children,
  onPress,
  style,
  testID,
}: DemoButtonProps): React.JSX.Element {
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole={accessibilityRole}
      onPress={onPress}
      style={style}
      testID={testID}
    >
      {children}
    </Pressable>
  );
}
