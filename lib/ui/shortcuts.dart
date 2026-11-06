import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One shortcut: what it does and the keys that trigger it. The key
/// handlers test events with [accepts] and the Help page prints [keys], so
/// the two can't drift apart.
class KeyBinding {
  const KeyBinding(this.label, this.activators);

  final String label;
  final List<ShortcutActivator> activators;

  /// Whether [event] presses one of [activators] (key down or repeat,
  /// exact modifiers).
  bool accepts(KeyEvent event) =>
      activators.any((a) => a.accepts(event, HardwareKeyboard.instance));

  /// [accepts], key down only (no repeats).
  bool pressed(KeyEvent event) => event is KeyDownEvent && accepts(event);

  /// For a `CallbackShortcuts` map: every activator runs [callback].
  Map<ShortcutActivator, VoidCallback> bind(VoidCallback callback) => {
    for (final a in activators) a: callback,
  };

  /// "Ctrl+F", "/ or Ctrl+F", …
  String get keys => activators.map(describeActivator).join('  or  ');
}

/// A mouse gesture, listed with the shortcuts (nothing to bind).
class MouseHelp {
  const MouseHelp(this.gesture, this.label);

  final String gesture;
  final String label;
}

String describeActivator(ShortcutActivator activator) {
  // Typed characters, whatever the layout needs to type them (`/` is
  // Shift+7 on some).
  if (activator is CharacterActivator) {
    return [
      if (activator.control) 'Ctrl',
      if (activator.alt) 'Alt',
      activator.character,
    ].join('+');
  }
  final a = activator as SingleActivator;
  final key = switch (a.trigger) {
    LogicalKeyboardKey.escape => 'Esc',
    LogicalKeyboardKey.arrowLeft => '←',
    LogicalKeyboardKey.arrowRight => '→',
    LogicalKeyboardKey.arrowUp => '↑',
    LogicalKeyboardKey.arrowDown => '↓',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.tab => 'Tab',
    final k => k.keyLabel.length == 1 ? k.keyLabel.toUpperCase() : k.keyLabel,
  };
  return [
    if (a.control) 'Ctrl',
    if (a.alt) 'Alt',
    if (a.meta) 'Meta',
    if (a.shift) 'Shift',
    key,
  ].join('+');
}

/// Every keyboard shortcut in the app.
abstract final class AppKeys {
  // Anywhere (bound above the navigator, in AssetsExplorerApp).
  static const back = KeyBinding(
    'Back: close a dialog or page, leave a bundle',
    [SingleActivator(LogicalKeyboardKey.escape)],
  );
  static const importFolder = KeyBinding('Import a folder', [
    SingleActivator(LogicalKeyboardKey.keyI, control: true),
  ]);
  static const importArchive = KeyBinding('Import archives', [
    SingleActivator(LogicalKeyboardKey.keyO, control: true),
  ]);
  static const rescan = KeyBinding('Rescan the library', [
    SingleActivator(LogicalKeyboardKey.f5),
    SingleActivator(LogicalKeyboardKey.keyR, control: true),
  ]);
  static const settings = KeyBinding('Settings', [
    SingleActivator(LogicalKeyboardKey.comma, control: true),
  ]);
  static const help = KeyBinding('This help page', [
    SingleActivator(LogicalKeyboardKey.f1),
  ]);
  static const nextTab = KeyBinding('Next tab', [
    SingleActivator(LogicalKeyboardKey.tab, control: true),
  ]);
  static const previousTab = KeyBinding('Previous tab', [
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
  ]);
  static const closeTab = KeyBinding('Close the shown pack tab', [
    SingleActivator(LogicalKeyboardKey.keyW, control: true),
  ]);

  // Dashboard.
  static const dashboardSearch = KeyBinding('Search the library', [
    CharacterActivator('/'),
    SingleActivator(LogicalKeyboardKey.keyF, control: true),
  ]);
  static const leaveSearch = KeyBinding('Leave the search field', [
    SingleActivator(LogicalKeyboardKey.escape),
  ]);

  // Pack page.
  static const pinHeader = KeyBinding('Pin or unpin the header', [
    SingleActivator(LogicalKeyboardKey.keyH),
  ]);
  static const fileSearch = KeyBinding('Search this pack’s file names', [
    SingleActivator(LogicalKeyboardKey.keyF, control: true),
  ]);
  static const clearFileSearch = KeyBinding(
    'In the file search: clear it, then leave it',
    [SingleActivator(LogicalKeyboardKey.escape)],
  );
  static const focusPrevious = KeyBinding('Focus mode: previous animation', [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]);
  static const focusNext = KeyBinding('Focus mode: next animation', [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]);
  static const leaveFocus = KeyBinding('Leave focus mode', [
    SingleActivator(LogicalKeyboardKey.escape),
  ]);
  static const playStop = KeyBinding('Audio: play or stop the selected sound', [
    SingleActivator(LogicalKeyboardKey.space),
  ]);
  static const seekBack = KeyBinding('Audio: back 5 s while playing', [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]);
  static const seekForward = KeyBinding('Audio: forward 5 s while playing', [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]);
  static const framesUp = KeyBinding(
    'Edit dialog, Frames: next count that fits',
    [SingleActivator(LogicalKeyboardKey.arrowUp)],
  );
  static const framesDown = KeyBinding(
    'Edit dialog, Frames: previous count that fits',
    [SingleActivator(LogicalKeyboardKey.arrowDown)],
  );

  // Image viewer.
  static const viewerPrevious = KeyBinding('Previous image', [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]);
  static const viewerNext = KeyBinding('Next image', [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]);
}

/// The shortcut table as the Help page shows it, by where it works.
const shortcutSections = <(String, List<KeyBinding>)>[
  (
    'Anywhere',
    [
      AppKeys.back,
      AppKeys.importFolder,
      AppKeys.importArchive,
      AppKeys.rescan,
      AppKeys.settings,
      AppKeys.help,
      AppKeys.nextTab,
      AppKeys.previousTab,
      AppKeys.closeTab,
    ],
  ),
  ('Dashboard', [AppKeys.dashboardSearch, AppKeys.leaveSearch]),
  (
    'Pack page',
    [
      AppKeys.pinHeader,
      AppKeys.fileSearch,
      AppKeys.clearFileSearch,
      AppKeys.focusPrevious,
      AppKeys.focusNext,
      AppKeys.leaveFocus,
      AppKeys.playStop,
      AppKeys.seekBack,
      AppKeys.seekForward,
      AppKeys.framesUp,
      AppKeys.framesDown,
    ],
  ),
  ('Image viewer', [AppKeys.viewerPrevious, AppKeys.viewerNext]),
];

/// Mouse gestures the Help page lists next to the shortcuts.
const mouseHelp = [
  MouseHelp('Mouse back button', 'Same as Esc: back'),
  MouseHelp('Middle-click a pack', 'Open it in a new tab (behind this one)'),
  MouseHelp('Right-click a pack', 'Menu with "Open in new tab"'),
  MouseHelp('Middle-click a tab', 'Close it'),
  MouseHelp('Ctrl + wheel over a grid', 'Bigger or smaller thumbnails'),
  MouseHelp('Hover a dashboard tile', 'Play its animation'),
  MouseHelp(
    'Rest on the slim header bar',
    'Show the full header (after a moment)',
  ),
  MouseHelp('Click the Dashboard tab', 'Back to the dashboard from a pack'),
  MouseHelp('Click an animation card', 'Focus mode: dim and pause the others'),
  MouseHelp(
    'Wheel in the image viewer',
    'Zoom; drag to pan, double-click fits',
  ),
  MouseHelp('Wheel over the Frames field', 'Step through counts that fit'),
  MouseHelp('Wheel over the Edit preview', 'Zoom (−, +, reset on hover)'),
  MouseHelp('Ctrl / Shift-click images (Flat)', 'Select frames to combine'),
];
