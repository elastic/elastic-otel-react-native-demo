import React from 'react';
import { Text } from 'react-native';
import ReactTestRenderer, { ReactTestRendererJSON } from 'react-test-renderer';
import { emitLog, endSpan, startSpan } from '@elastic/otel-react-native';
import App, { forecastUrl } from '../App';
import { DemoButton } from '../DemoButton';

const mockRecordWidgetClick = jest.fn(
  async (_options: {
    widgetId: string;
    widgetName?: string;
    timestamp: number;
  }) => undefined,
);

jest.mock(
  'react-native-safe-area-context',
  () => require('react-native-safe-area-context/jest/mock').default,
);

// Mirrors the package's tap contract: the first candidate that is a
// non-empty string wins, and the widget id falls back to the component name.
function mockFirstValue(candidates: unknown[]): string | undefined {
  return candidates.find(
    (candidate): candidate is string =>
      typeof candidate === 'string' && candidate.trim() !== '',
  );
}

jest.mock('@elastic/otel-react-native', () => ({
  __widgetContent: (...parts: unknown[]) =>
    parts
      .filter(part => typeof part === 'string' || typeof part === 'number')
      .map(part => String(part).trim())
      .filter(Boolean)
      .join(' '),
  __wrapPressHandler: (
    handler: (...args: unknown[]) => unknown,
    componentName: string,
    widgetIdCandidates: unknown[],
    widgetNameCandidates: unknown[],
  ) =>
    function (this: unknown, ...args: unknown[]) {
      const widgetName = mockFirstValue(widgetNameCandidates);
      mockRecordWidgetClick({
        widgetId: mockFirstValue(widgetIdCandidates) ?? componentName,
        ...(widgetName === undefined ? {} : { widgetName }),
        timestamp: Date.now(),
      }).catch(() => {});
      return handler.apply(this, args);
    },
  emitLog: jest.fn(async () => undefined),
  endSpan: jest.fn(async () => undefined),
  recordWidgetClick: mockRecordWidgetClick,
  startSpan: jest
    .fn()
    .mockResolvedValueOnce('root-handle')
    .mockResolvedValueOnce('child-handle'),
}));

const successfulWeatherResponse = {
  current_weather: {
    temperature: 18.5,
  },
};

beforeEach(() => {
  jest.clearAllMocks();
  jest
    .mocked(startSpan)
    .mockResolvedValueOnce('root-handle')
    .mockResolvedValueOnce('child-handle');
  globalThis.fetch = jest.fn(async () => ({
    ok: true,
    status: 200,
    json: async () => successfulWeatherResponse,
  })) as unknown as typeof fetch;
});

afterEach(() => {
  jest.restoreAllMocks();
});

test.each([
  ['android', 'http://10.0.2.2:8080/v1/forecast?city=New%20York'],
  ['ios', 'http://localhost:8080/v1/forecast?city=New%20York'],
])('uses the %s simulator host for local forecasts', (platform, expected) => {
  expect(forecastUrl('New York', platform)).toBe(expected);
});

test('creates correlated startup telemetry and renders the city picker', async () => {
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });

  expect(startSpan).toHaveBeenNthCalledWith(1, 'Creating app');
  expect(startSpan).toHaveBeenNthCalledWith(2, 'Initialize React Native UI', {
    parentSpanHandle: 'root-handle',
  });
  expect(emitLog).toHaveBeenCalledWith('During app creation', 'info', {
    spanHandle: 'child-handle',
  });
  expect(endSpan).toHaveBeenNthCalledWith(1, 'child-handle');
  expect(endSpan).toHaveBeenNthCalledWith(2, 'root-handle');
  expect(renderedText(renderer)).toEqual(
    expect.arrayContaining(['Weather demo', 'Berlin', 'Fetch forecast']),
  );
});

test('fetches and renders a forecast from the shared backend', async () => {
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });

  await ReactTestRenderer.act(async () => {
    renderer!.root
      .findByProps({ testID: 'fetch-forecast-button' })
      .props.onPress();
  });

  expect(globalThis.fetch).toHaveBeenCalledWith(
    'http://localhost:8080/v1/forecast?city=Berlin',
  );
  expect(mockRecordWidgetClick).toHaveBeenCalledWith(
    expect.objectContaining({
      widgetId: 'fetch-forecast-button',
      widgetName: 'Fetch forecast',
    }),
  );
  expect(renderedText(renderer)).toEqual(
    expect.arrayContaining([
      'Berlin',
      '18.5 C',
      'Mild',
      'Weather data by Open-Meteo.com',
    ]),
  );
});

test('records one tap event for the demo-owned back button', async () => {
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });
  await ReactTestRenderer.act(async () => {
    renderer!.root
      .findByProps({ testID: 'fetch-forecast-button' })
      .props.onPress();
  });
  mockRecordWidgetClick.mockClear();

  // The pressable that DemoButton renders receives the wrapped handler.
  const backButton = renderer!.root
    .findAllByProps({ testID: 'forecast-back-button' })
    .find(node => typeof node.type !== 'string' && node.type !== DemoButton);
  await ReactTestRenderer.act(async () => {
    backButton!.props.onPress();
  });

  expect(mockRecordWidgetClick).toHaveBeenCalledTimes(1);
  expect(mockRecordWidgetClick).toHaveBeenCalledWith(
    expect.objectContaining({
      widgetId: 'forecast-back-button',
      widgetName: 'Back',
    }),
  );
  expect(renderedText(renderer)).toEqual(
    expect.arrayContaining(['Weather demo', 'Fetch forecast']),
  );
});

test('updates the UI when automatic tap telemetry rejects', async () => {
  mockRecordWidgetClick.mockRejectedValueOnce(new Error('event unavailable'));
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });
  await ReactTestRenderer.act(async () => {
    renderer!.root
      .findByProps({ testID: 'fetch-forecast-button' })
      .props.onPress();
  });

  expect(renderedText(renderer)).toEqual(
    expect.arrayContaining(['Berlin', '18.5 C', 'Mild']),
  );
});

test('emits an independent error log for a rejected forecast', async () => {
  globalThis.fetch = jest.fn(async () => ({
    ok: false,
    status: 500,
    json: async () => ({}),
  })) as unknown as typeof fetch;

  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });

  const newYorkButton = renderer!.root
    .findAllByProps({ accessibilityRole: 'button' })
    .find(node => renderedNodeText(node).includes('New York'));

  await ReactTestRenderer.act(async () => {
    newYorkButton!.props.onPress();
  });
  await ReactTestRenderer.act(async () => {
    renderer!.root
      .findByProps({ testID: 'fetch-forecast-button' })
      .props.onPress();
  });

  expect(globalThis.fetch).toHaveBeenCalledWith(
    'http://localhost:8080/v1/forecast?city=New%20York',
  );
  expect(emitLog).toHaveBeenCalledWith(
    'Forecast request failed: Backend returned HTTP 500',
    'error',
  );
  expect(renderedText(renderer)).toEqual(
    expect.arrayContaining(['Could not load forecast for New York']),
  );
});

test('renders a rejected forecast when error logging also rejects', async () => {
  globalThis.fetch = jest.fn(async () => ({
    ok: false,
    status: 500,
    json: async () => ({}),
  })) as unknown as typeof fetch;
  const loggingError = new Error('logging unavailable');
  const consoleError = jest
    .spyOn(console, 'error')
    .mockImplementation(() => {});

  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });
  jest.mocked(emitLog).mockRejectedValueOnce(loggingError);

  const newYorkButton = renderer!.root
    .findAllByProps({ accessibilityRole: 'button' })
    .find(node => renderedNodeText(node).includes('New York'));

  await ReactTestRenderer.act(async () => {
    newYorkButton!.props.onPress();
  });
  await ReactTestRenderer.act(async () => {
    renderer!.root
      .findByProps({ testID: 'fetch-forecast-button' })
      .props.onPress();
  });

  expect(renderedText(renderer)).toEqual(
    expect.arrayContaining(['Could not load forecast for New York']),
  );
  expect(consoleError).toHaveBeenCalledWith(
    'Failed to emit forecast error telemetry.',
    loggingError,
  );
});

function renderedNodeText(node: ReactTestRenderer.ReactTestInstance): string {
  return node
    .findAllByType(Text)
    .flatMap(text => text.props.children)
    .join('');
}

function renderedText(
  renderer: ReactTestRenderer.ReactTestRenderer | undefined,
): string[] {
  if (!renderer) {
    return [];
  }

  return renderer.root.findAllByType(Text).flatMap(node => {
    const children = node.props.children as ReactTestRendererJSON['children'];

    if (typeof children === 'string') {
      return [children];
    }
    if (Array.isArray(children)) {
      return [children.join('')];
    }
    return [];
  });
}
