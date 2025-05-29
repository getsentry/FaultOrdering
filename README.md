# FaultOrdering

Order files can reduce app startup time by co-locating symbols that are accessed during app launch, reducing the number of page faults from the app. This package generates an order
file by launching the app in an XCUITest. Read all about how order files work in [our blog post](https://www.emergetools.com/blog/posts/FasterAppStartupOrderFiles).

Setting up your app for order files requires 2 steps:
1 - Use this library to generate an order file as part of your XCUITest. The library instruments app launch in the UI test and uses the results to generate an optimized order file
2 - Re-build the app with the order file. Once the order file is generated you build the app again, this time passing the order file as an option to the linker.

## Installation

Create a UI testing target using XCUITest. Add the package dependency to your Xcode project using the URL of this repository (https://github.com/getsentry/FaultOrdering).
Add `FaultOrderingTests` and `FaultOrdering` as a dependency of your new UI test target.

### Generating the linkmap

To use this package you'll need to tell Xcode to generate a linkmap for your main app binary. In your app's Xcode target, set the following build settings:

```
LD_GENERATE_MAP_FILE = YES
LD_MAP_FILE_PATH = $(PROJECT_DIR)/Linkmap.txt
```

We recommend using `$(PROJECT_DIR)` so that it generates within your project directory instead of derived data, but this can be changed to whatever makes sense for your setup.

After adding these settings, make sure to build your app and verify the file exists.

### Including the linkmap

Once the `Linkmap.txt` file exists, it needs to be included as a resource in your UI test target. Add it in the build phases for your target under Copy Bundle Resources.

<img src="images/copy.png" width="600" alt="Copy Bundle Resources">

<img src="images/choose.png" width="400" alt="Choose File">
Choose "Add Other" and browse to where you generated the file. You may need to create the file first, by building your main app target once with the new build settings.

<img src="images/confirm.png" width="600" alt="Confirm">
Confirm your selection and <strong>do not</strong> check the box to copy the file.

> [!IMPORTANT]
> The generated Linkmap.txt file must be included in your UI test target. You don't need to specificly use `"$(PROJECT_DIR)/Linkmap.txt"` as the path, only that whatever the `LD_MAP_FILE_PATH` is set is also the file that you include in Copy Bundle Resources.

## Usage

In a UI test, create an instance of `FaultOrderingTest` and optionally provide a closure to perform any necessary app setup. In most cases, this should include logging in to the app. Centering your UI test around a fully logged in session is strongly recommended, not only because it optimizes for the most common user experience, but also because it significantly improves the efficacy of this tool. By logging in, you allow much more of the app’s initial code to execute within the test context, allowing for a greater number of page fault reductions. The test case can then be executed.

Example:

```swift
let app = XCUIApplication()
let test = FaultOrderingTest { app in
  // Perform setup such as logging in
}
test.testApp(testCase: self, app: app)
```

> [!IMPORTANT]
> This test should be run with a release build configuration, using the same compiler/linker optimizations that you would use on the App Store.

### Accessing results

Results are added as a XCTAttachment named `"order-file"`.

### Device support

To run on a physical device the app must link to the `FaultOrdering` product from this package. Update your main app target to have this framework in it's embedded frameworks. If your app takes a different codepath on physical devices than simulators (such as using device only frameworks like Metal) it is best to generate an order file while running on the physical device.

## Using the order file

Once you run the UI test to generate an order file you have to use this file as an input to a new build of the app. Technically you only need to re-link the app, not re-compile everything, but running a new build with xcode is the easiest way to do this. Set the xcode build setting "ORDER_FILE" to the path to your order file when you build the app.
