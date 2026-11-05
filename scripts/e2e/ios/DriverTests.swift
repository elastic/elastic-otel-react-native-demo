// Copyright Elastic Technologies Inc. and/or licensed to
// Elastic Technologies Inc. under one or more contributor license
// agreements. See the NOTICE file distributed with this work for
// additional information regarding copyright ownership.
// Elastic Technologies Inc. licenses this file to you under the Apache
// License, Version 2.0 (the "License"); you may not use this file except
// in compliance with the License. You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest

final class DriverTests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "co.elastic.edot.reactnative.demo")

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app.activate()
  }

  private func tap(_ identifier: String) {
    let element = app.descendants(matching: .any)[identifier].firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 120), "Missing UI target: \(identifier)")
    if !element.isHittable { app.swipeUp() }
    element.tap()
  }

  func testBerlin() {
    tap("Berlin")
    tap("fetch-forecast-button")
    XCTAssertTrue(app.staticTexts["Weather data by Open-Meteo.com"].waitForExistence(timeout: 120))
  }

  func testNewYork() {
    tap("forecast-back-button")
    let city = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New York"))
      .firstMatch
    XCTAssertTrue(city.waitForExistence(timeout: 120))
    city.tap()
    tap("fetch-forecast-button")
    XCTAssertTrue(app.buttons["retry-forecast-button"].waitForExistence(timeout: 120))
  }

  func testCrash() {
    tap("error-back-button")
    tap("crash-button")
  }
}
