/// Set by CI (`--dart-define=APP_VERSION=1.0.<run number>`). Local builds are
/// 0.0.0, so any announced version counts as newer.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');
