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
