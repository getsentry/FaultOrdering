# FaultOrdering

Order files can reduce app startup time by co-locating symbols that are accessed during app launch, reducing the number of page faults from the app. This package generates an order
file by launching the app in an XCUITest. Read all about how order files work in [our blog post](https://www.emergetools.com/blog/posts/FasterAppStartupOrderFiles).

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

In a UI test, create an instance of `FaultOrderingTest` and optionally provide a closure to perform any required app setup. For example, you may want to log in to the app since that's the most common code path for the majority of your app users. The test case can then be executed.

Example:

```swift
let app = XCUIApplication()
let test = FaultOrderingTest { app in
  // Perform setup such as logging in
}
test.testApp(testCase: self, app: app)
```

### Accessing results

Results are added as a XCTAttachment named `"order-file"`.

### Device support

To run on a physical device the app must link to the `FaultOrdering` product from this package. Update your main app target to have this framework in it's embedded frameworks.
