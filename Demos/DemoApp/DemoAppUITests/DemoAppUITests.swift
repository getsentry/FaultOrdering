//
//  DemoAppUITests.swift
//  DemoAppUITests
//
//  Created by Noah Martin on 6/13/25.
//

import XCTest
import FaultOrderingTests

final class DemoAppUITests: XCTestCase {

    @MainActor
    func testExample() throws {
      let app = XCUIApplication()
      let test = FaultOrderingTest { app in
          // Perform setup such as logging in
      }
      test.testApp(testCase: self, app: app)
    }
}
