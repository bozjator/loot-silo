/// The app's version and build, kept equal to `version:` in pubspec.yaml
/// (a test checks it). A constant instead of a plugin: nothing to load at
/// start, and it reads the same in widget tests.
library;

/// The app's name, shown in the window title, the app bar and Help.
const appName = 'Loot Silo';

/// The slogan under the name (first-start screen, Settings → About, Help).
const appSlogan = 'Your game assets. At a glance.';

const appVersion = '1.0.0';
const appBuild = 1;

/// "Loot Silo 1.0.0 (build 1)": Settings' About line and the Help
/// footer.
const appVersionLabel = '$appName $appVersion (build $appBuild)';
