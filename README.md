# FaultOrdering

Order files can reduce app startup time by co-locating symbols that are accessed during app launch, reducing overall memory used by the app code. This package generates an order
file by launching the app in an XCUITest. Read all about how order files work in [our blog post](https://www.emergetools.com/blog/posts/FasterAppStartupOrderFiles).

## Installation

Create a UI testing target using XCUITest. Add the package dependency to your Xcode project using the URL of this repository (https://github.com/getsentry/FaultOrdering).
Add `FaultOrderingTests` and `FaultOredering` as a dependency of your new UI test target.

### Linkmaps
To use this package you’ll need to generate a linkmap for your main app binary. In your xcode target build settings set the following flags:
```
LD_GENERATE_MAP_FILE = YES
LD_MAP_FILE_PATH = PATH_TO_YOUR_UI_TEST/Linkmap.txt
```

The linkmap should be copied into your UI test target. Add it in the build phases for your target under Copy Bundle Resources. 

> [!IMPORTANT]
> The linkmap file must be included in our UI test target. Ensure the LD_MAP_FILE_PATH is set to the file that you include in Copy Bundle Resources. 

## Usage

Create an instance of FaultOrderingTest and provide a closure to performan any setup. The setup closure will be called before generating the order file
so you can put the app in a state that users commonly see. For example, you may want to log in to the app. Then the order file will generate
for the codepaths your app uses when users are logged in.

Example:

```swift
let app = XCUIApplication()
let test = FaultOrderingTest { app in
  // Perform setup such as logging in
}
test.testApp(testCase: self, app: app)
```

### Accessing results

Results are added as a XCTAttachment named "order-file"

### Device support

To run on a physical device the app must link to the `FaultOrdering` product from this package. Update your main app target to have this framework in it’s embedded frameworks.
