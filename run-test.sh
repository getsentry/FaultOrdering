#!/bin/bash

set -euo pipefail

# Configurable variables
PROJECT_PATH="Demos/DemoApp/DemoApp.xcodeproj"
SCHEME="DemoApp"
DESTINATION="name=iPhone 16 Pro"
XCRESULT_PATH="TestResults.xcresult"
OUTPUT_FILE="order-file.txt"

# 1. Run the test
echo "Running xcodebuild test..."
xcodebuild test \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -resultBundlePath "$XCRESULT_PATH"

echo "Test finished. Searching for attachment..."

# Run xcparse to extract plain text attachments
xcparse attachments "$XCRESULT_PATH" ./out/ --uti public.plain-text

# Find the output file matching the order-file pattern
ORDER_FILE=$(find ./out -type f -name "order-file_*.txt" | head -n 1)

if [[ -z "$ORDER_FILE" ]]; then
  echo "❌ No 'order-file_*.txt' found in ./out"
  exit 1
fi

# Move and rename it
mv "$ORDER_FILE" ./order-file.txt
echo "✅ Done"
