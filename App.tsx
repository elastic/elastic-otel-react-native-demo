import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { emitLog, endSpan, startSpan } from '@elastic/otel-react-native';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { DemoButton } from './DemoButton';

type WeatherCity = {
  name: string;
  intentionalError?: boolean;
};

type WeatherReport = {
  cityName: string;
  temperatureC: number;
};

type ForecastState =
  | { status: 'loading' }
  | { status: 'success'; report: WeatherReport }
  | { status: 'error'; message: string };

const cities: WeatherCity[] = [
  { name: 'Berlin' },
  { name: 'London' },
  { name: 'Paris' },
  { name: 'New York', intentionalError: true },
];

function App(): React.JSX.Element {
  return (
    <SafeAreaProvider>
      <AppContent />
    </SafeAreaProvider>
  );
}

function AppContent(): React.JSX.Element {
  const [selectedCity, setSelectedCity] = useState(cities[0]);
  const [forecastCity, setForecastCity] = useState<WeatherCity | null>(null);

  useEffect(() => {
    const createAppTelemetry = async () => {
      const parent = await startSpan('Creating app');
      try {
        const child = await startSpan('Initialize React Native UI', {
          parentSpanHandle: parent,
        });
        try {
          await emitLog('During app creation', 'info', {
            spanHandle: child,
          });
        } finally {
          await endSpan(child);
        }
      } finally {
        await endSpan(parent);
      }
    };

    createAppTelemetry().catch(error => {
      console.error('Failed to create startup telemetry.', error);
    });
  }, []);

  if (forecastCity) {
    return (
      <ForecastScreen
        city={forecastCity}
        onBack={() => setForecastCity(null)}
      />
    );
  }

  return (
    <CityPickerScreen
      selectedCity={selectedCity}
      onSelectCity={setSelectedCity}
      onFetchForecast={() => setForecastCity(selectedCity)}
    />
  );
}

function CityPickerScreen({
  selectedCity,
  onSelectCity,
  onFetchForecast,
}: {
  selectedCity: WeatherCity;
  onSelectCity: (city: WeatherCity) => void;
  onFetchForecast: () => void;
}): React.JSX.Element {
  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar barStyle="dark-content" />
      <ScrollView contentContainerStyle={styles.screen}>
        <View style={styles.heroIcon}>
          <Text style={styles.heroIconText}>RN</Text>
        </View>
        <Text style={styles.title}>Weather demo</Text>
        <Text style={styles.subtitle}>
          Pick a city, then fetch the current weather through the local
          instrumented backend. New York intentionally exercises the HTTP error
          path.
        </Text>

        <View style={styles.cityList}>
          {cities.map(city => {
            const isSelected = city.name === selectedCity.name;

            return (
              <Pressable
                key={city.name}
                accessibilityRole="button"
                accessibilityState={{ selected: isSelected }}
                onPress={() => onSelectCity(city)}
                style={[styles.cityButton, isSelected && styles.selectedCity]}
              >
                <Text
                  style={[
                    styles.cityName,
                    isSelected && styles.selectedCityName,
                  ]}
                >
                  {city.name}
                </Text>
                {city.intentionalError ? (
                  <Text style={styles.errorHint}>Intentional error</Text>
                ) : null}
              </Pressable>
            );
          })}
        </View>

        <Pressable
          accessibilityLabel="Fetch forecast"
          accessibilityRole="button"
          onPress={onFetchForecast}
          style={styles.primaryButton}
          testID="fetch-forecast-button"
        >
          <Text style={styles.primaryButtonText}>Fetch forecast</Text>
        </Pressable>

        <Pressable
          accessibilityLabel="Crash the app"
          accessibilityRole="button"
          onPress={crashApp}
          testID="crash-button"
        >
          <Text style={styles.crashButtonText}>Crash</Text>
        </Pressable>
      </ScrollView>
    </SafeAreaView>
  );
}

function ForecastScreen({
  city,
  onBack,
}: {
  city: WeatherCity;
  onBack: () => void;
}): React.JSX.Element {
  const [refreshToken, setRefreshToken] = useState(0);
  const [forecast, setForecast] = useState<ForecastState>({
    status: 'loading',
  });

  const loadForecast = useCallback(async () => {
    setForecast({ status: 'loading' });

    try {
      const report = await fetchCurrentWeather(city);
      setForecast({ status: 'success', report });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setForecast({
        status: 'error',
        message,
      });
      emitLog(`Forecast request failed: ${message}`, 'error').catch(
        loggingError => {
          console.error(
            'Failed to emit forecast error telemetry.',
            loggingError,
          );
        },
      );
    }
  }, [city]);

  useEffect(() => {
    loadForecast();
  }, [loadForecast, refreshToken]);

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar barStyle="dark-content" />
      <View style={styles.forecastHeader}>
        <DemoButton
          accessibilityLabel="Return to city picker"
          accessibilityRole="button"
          onPress={onBack}
          testID="forecast-back-button"
        >
          <Text style={styles.backButton}>Back</Text>
        </DemoButton>
        <Text style={styles.headerTitle}>{city.name}</Text>
      </View>
      <View style={styles.forecastBody}>
        {forecast.status === 'loading' ? (
          <LoadingForecast cityName={city.name} />
        ) : null}
        {forecast.status === 'success' ? (
          <ForecastSuccess report={forecast.report} />
        ) : null}
        {forecast.status === 'error' ? (
          <ForecastError
            cityName={city.name}
            message={forecast.message}
            onRetry={() => setRefreshToken(token => token + 1)}
            onBack={onBack}
          />
        ) : null}
      </View>
    </SafeAreaView>
  );
}

function crashApp(): never {
  throw new Error('Intentional crash from the EDOT React Native demo');
}

async function fetchCurrentWeather(city: WeatherCity): Promise<WeatherReport> {
  const response = await fetch(forecastUrl(city.name));

  if (!response.ok) {
    throw new Error(`Backend returned HTTP ${response.status}`);
  }

  const payload = (await response.json()) as {
    current_weather?: {
      temperature?: number;
    };
  };
  const current = payload.current_weather;

  if (!current || typeof current.temperature !== 'number') {
    throw new Error('Backend response did not include current weather.');
  }

  return {
    cityName: city.name,
    temperatureC: current.temperature,
  };
}

export function forecastUrl(
  cityName: string,
  platform: string = Platform.OS,
): string {
  const host = platform === 'android' ? '10.0.2.2' : 'localhost';
  return `http://${host}:8080/v1/forecast?city=${encodeURIComponent(cityName)}`;
}

function LoadingForecast({
  cityName,
}: {
  cityName: string;
}): React.JSX.Element {
  return (
    <View style={styles.centerCard}>
      <ActivityIndicator size="large" color="#00796b" />
      <Text style={styles.loadingText}>
        Fetching forecast for {cityName}...
      </Text>
    </View>
  );
}

function ForecastSuccess({
  report,
}: {
  report: WeatherReport;
}): React.JSX.Element {
  const accentColor = useMemo(
    () => temperatureColor(report.temperatureC),
    [report.temperatureC],
  );

  return (
    <View style={[styles.weatherCard, { borderColor: accentColor }]}>
      <Text style={[styles.weatherIcon, { color: accentColor }]}>
        {weatherIcon(report.temperatureC)}
      </Text>
      <Text style={styles.title}>{report.cityName}</Text>
      <Text style={styles.temperature}>{report.temperatureC.toFixed(1)} C</Text>
      <Text style={styles.weatherDescription}>
        {temperatureDescription(report.temperatureC)}
      </Text>
      <Text style={styles.attribution}>Weather data by Open-Meteo.com</Text>
    </View>
  );
}

function ForecastError({
  cityName,
  message,
  onRetry,
  onBack,
}: {
  cityName: string;
  message: string;
  onRetry: () => void;
  onBack: () => void;
}): React.JSX.Element {
  return (
    <View style={styles.centerCard}>
      <Text style={styles.errorIcon}>!</Text>
      <Text style={styles.errorTitle}>
        Could not load forecast for {cityName}
      </Text>
      <Text style={styles.errorMessage}>{message}</Text>
      <Pressable
        accessibilityLabel="Retry forecast request"
        accessibilityRole="button"
        onPress={onRetry}
        style={styles.primaryButton}
        testID="retry-forecast-button"
      >
        <Text style={styles.primaryButtonText}>Retry request</Text>
      </Pressable>
      <Pressable
        accessibilityLabel="Return to city picker"
        accessibilityRole="button"
        onPress={onBack}
        testID="error-back-button"
      >
        <Text style={styles.secondaryButtonText}>Try another city</Text>
      </Pressable>
    </View>
  );
}

function weatherIcon(temperatureC: number): string {
  if (temperatureC <= 0) {
    return 'Snow';
  }
  return 'Sun';
}

function temperatureDescription(temperatureC: number): string {
  if (temperatureC >= 30) {
    return 'Hot';
  }
  if (temperatureC >= 25) {
    return 'Warm';
  }
  if (temperatureC >= 15) {
    return 'Mild';
  }
  if (temperatureC >= 5) {
    return 'Cool';
  }
  if (temperatureC >= 0) {
    return 'Chilly';
  }
  return 'Freezing';
}

function temperatureColor(temperatureC: number): string {
  if (temperatureC >= 25) {
    return '#ef6c00';
  }
  if (temperatureC >= 10) {
    return '#2e7d32';
  }
  if (temperatureC >= 0) {
    return '#1565c0';
  }
  return '#4527a0';
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#effaf7',
  },
  screen: {
    flexGrow: 1,
    padding: 24,
    justifyContent: 'center',
  },
  heroIcon: {
    width: 72,
    height: 72,
    borderRadius: 36,
    alignSelf: 'center',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#00796b',
    marginBottom: 24,
  },
  heroIconText: {
    color: 'white',
    fontSize: 22,
    fontWeight: '700',
  },
  title: {
    color: '#10201c',
    fontSize: 32,
    fontWeight: '700',
    textAlign: 'center',
  },
  subtitle: {
    color: '#52635e',
    fontSize: 16,
    lineHeight: 24,
    textAlign: 'center',
    marginTop: 12,
  },
  cityList: {
    gap: 12,
    marginTop: 32,
  },
  cityButton: {
    borderWidth: 1,
    borderColor: '#c4d7d0',
    borderRadius: 16,
    padding: 16,
    backgroundColor: 'white',
  },
  selectedCity: {
    borderColor: '#00796b',
    backgroundColor: '#d8f2eb',
  },
  cityName: {
    color: '#10201c',
    fontSize: 18,
    fontWeight: '600',
  },
  selectedCityName: {
    color: '#00695c',
  },
  errorHint: {
    color: '#a33a2a',
    fontSize: 13,
    marginTop: 4,
  },
  primaryButton: {
    alignItems: 'center',
    borderRadius: 999,
    backgroundColor: '#00796b',
    marginTop: 24,
    paddingVertical: 14,
    paddingHorizontal: 20,
  },
  primaryButtonText: {
    color: 'white',
    fontSize: 16,
    fontWeight: '700',
  },
  secondaryButtonText: {
    color: '#00796b',
    fontSize: 16,
    fontWeight: '700',
    marginTop: 18,
  },
  crashButtonText: {
    color: '#ba1a1a',
    fontSize: 16,
    fontWeight: '700',
    marginTop: 18,
    textAlign: 'center',
  },
  forecastHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 16,
  },
  backButton: {
    color: '#00796b',
    fontSize: 16,
    fontWeight: '700',
    width: 72,
  },
  headerTitle: {
    color: '#10201c',
    flex: 1,
    fontSize: 20,
    fontWeight: '700',
    marginRight: 72,
    textAlign: 'center',
  },
  forecastBody: {
    flex: 1,
    padding: 24,
    justifyContent: 'center',
  },
  centerCard: {
    alignItems: 'center',
    borderRadius: 24,
    backgroundColor: 'white',
    padding: 24,
  },
  loadingText: {
    color: '#52635e',
    fontSize: 16,
    marginTop: 16,
    textAlign: 'center',
  },
  weatherCard: {
    alignItems: 'center',
    borderRadius: 24,
    borderWidth: 2,
    backgroundColor: 'white',
    padding: 24,
  },
  weatherIcon: {
    fontSize: 28,
    fontWeight: '800',
    marginBottom: 16,
  },
  temperature: {
    color: '#10201c',
    fontSize: 56,
    fontWeight: '800',
    marginTop: 8,
  },
  weatherDescription: {
    color: '#52635e',
    fontSize: 20,
    fontWeight: '600',
  },
  attribution: {
    color: '#52635e',
    fontSize: 12,
    marginTop: 18,
  },
  errorIcon: {
    color: '#ba1a1a',
    fontSize: 48,
    fontWeight: '800',
  },
  errorTitle: {
    color: '#10201c',
    fontSize: 22,
    fontWeight: '700',
    marginTop: 12,
    textAlign: 'center',
  },
  errorMessage: {
    color: '#52635e',
    fontSize: 15,
    lineHeight: 22,
    marginTop: 8,
    textAlign: 'center',
  },
});

export default App;
