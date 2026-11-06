// Both Dart and Android must opt in; normal builds do not expose the console.
const testToolsEnabled =
    bool.fromEnvironment('SBILL_TEST_TOOLS', defaultValue: false);
