/// The app's version and build, kept equal to `version:` in pubspec.yaml
/// (a test checks it). A constant instead of a plugin: nothing to load at
/// start, and it reads the same in widget tests.
library;

const appVersion = '1.0.0';
const appBuild = 1;

/// "Asset Explorer 1.0.0 (build 1)": Settings' About line and the Help
/// footer.
const appVersionLabel = 'Asset Explorer $appVersion (build $appBuild)';
