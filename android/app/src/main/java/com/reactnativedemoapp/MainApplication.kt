package com.reactnativedemoapp

import android.app.Application
import co.elastic.otel.reactnative.AuthenticationConfiguration
import co.elastic.otel.reactnative.BootstrapConfiguration
import co.elastic.otel.reactnative.ElasticOtelReactNative
import co.elastic.otel.reactnative.Transport
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost

class MainApplication : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    getDefaultReactHost(
      context = applicationContext,
      packageList = PackageList(this).packages,
    )
  }

  override fun onCreate() {
    super.onCreate()
    ElasticOtelReactNative.initialize(
      this,
      BootstrapConfiguration(
        exportUrl = "http://10.0.2.2:4318",
        authentication = AuthenticationConfiguration.none(),
        protocol = Transport.HTTP,
        sessionSampleRate = 1.0,
        serviceName = "weather-demo-react-native",
        instrumentationScopeName = "co.elastic.weather-demo",
      ),
    )
    loadReactNative(this)
  }
}
