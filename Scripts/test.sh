#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$PROJECT_ROOT/build/tests"
COMPATIBLE_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -d "$COMPATIBLE_SDK" ]]; then
  SDK_PATH="$COMPATIBLE_SDK"
else
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$TEST_BUILD" "$TEST_BUILD/module-cache"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$TEST_BUILD/module-cache" \
  "$PROJECT_ROOT/Sources/Models.swift" \
  "$PROJECT_ROOT/Sources/ShellConfiguration.swift" \
  "$PROJECT_ROOT/Tests/CoreTests.swift" \
  -o "$TEST_BUILD/CoreTests"

"$TEST_BUILD/CoreTests"

swiftc \
  -parse-as-library \
  -swift-version 5 \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$TEST_BUILD/module-cache" \
  -framework AppKit \
  -framework Combine \
  "$PROJECT_ROOT/Sources/Models.swift" \
  "$PROJECT_ROOT/Sources/ShellConfiguration.swift" \
  "$PROJECT_ROOT/Sources/EnvironmentStore.swift" \
  "$PROJECT_ROOT/Tests/StoreTests.swift" \
  -o "$TEST_BUILD/StoreTests"

"$TEST_BUILD/StoreTests"
