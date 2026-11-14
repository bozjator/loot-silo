import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether the primary shortcut modifier is Cmd (macOS) rather than Ctrl.
///
/// Read from [defaultTargetPlatform] rather than `Platform`, so tests (with
/// `TargetPlatformVariant`) and a debug run on Linux (with
/// `debugDefaultTargetPlatformOverride`, which the theme follows too) get
/// the macOS keys. Not from the theme: activators and scroll physics have
/// no `BuildContext`, and the labels must name the keys that work.
bool get primaryIsCmd => defaultTargetPlatform == TargetPlatform.macOS;

/// The primary modifier's name in labels and tooltips: "Cmd" or "Ctrl".
String get primaryKey => primaryIsCmd ? 'Cmd' : 'Ctrl';

/// Whether the primary modifier (Cmd on macOS, else Ctrl) is held.
bool get primaryPressed => primaryIsCmd
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;

/// [trigger] with the primary modifier (see [primaryIsCmd]): Ctrl, or Cmd
/// on macOS.
class PrimaryActivator with Diagnosticable implements ShortcutActivator {
  const PrimaryActivator(this.trigger);

  final LogicalKeyboardKey trigger;

  /// The concrete activator for the current platform.
  SingleActivator get resolved =>
      SingleActivator(trigger, control: !primaryIsCmd, meta: primaryIsCmd);

  @override
  Iterable<LogicalKeyboardKey> get triggers => [trigger];

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      resolved.accepts(event, state);

  @override
  String debugDescribeKeys() => resolved.debugDescribeKeys();
}

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

  /// "Ctrl+F", "/ or Ctrl+F", … (Cmd on macOS; see [primaryIsCmd]).
  String get keys => activators.map(describeActivator).join('  or  ');
}

/// A mouse gesture, listed with the shortcuts (nothing to bind).
class MouseHelp {
  const MouseHelp(this.gesture, this.label);

  final String gesture;
  final String label;
}

String describeActivator(ShortcutActivator activator) {
  if (activator is PrimaryActivator) activator = activator.resolved;
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
    if (a.alt) primaryIsCmd ? 'Option' : 'Alt',
    if (a.meta) primaryIsCmd ? 'Cmd' : 'Meta',
    if (a.shift) 'Shift',
    key,
  ].join('+');
}

/// Every keyboard shortcut in the app.
abstract final class AppKeys {
  // Anywhere (bound above the navigator, in LootSiloApp).
  static const back = KeyBinding('Back: close a dialog or page', [
    SingleActivator(LogicalKeyboardKey.escape),
  ]);
  static const importFolder = KeyBinding('Import a folder', [
    PrimaryActivator(LogicalKeyboardKey.keyI),
  ]);
  static const importArchive = KeyBinding('Import archives', [
    PrimaryActivator(LogicalKeyboardKey.keyO),
  ]);
  static const rescan = KeyBinding('Rescan the library', [
    SingleActivator(LogicalKeyboardKey.f5),
    PrimaryActivator(LogicalKeyboardKey.keyR),
  ]);
  static const settings = KeyBinding('Settings', [
    PrimaryActivator(LogicalKeyboardKey.comma),
  ]);
  static const help = KeyBinding('This help page', [
    SingleActivator(LogicalKeyboardKey.f1),
  ]);
  // Ctrl+Tab on macOS too, as in Safari and Finder.
  static const nextTab = KeyBinding('Next tab', [
    SingleActivator(LogicalKeyboardKey.tab, control: true),
  ]);
  static const previousTab = KeyBinding('Previous tab', [
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
  ]);
  static const closeTab = KeyBinding('Close the shown pack tab', [
    PrimaryActivator(LogicalKeyboardKey.keyW),
  ]);

  // Dashboard.
  static const dashboardSearch = KeyBinding('Search the library', [
    CharacterActivator('/'),
    PrimaryActivator(LogicalKeyboardKey.keyF),
  ]);
  static const leaveSearch = KeyBinding('Leave the search field', [
    SingleActivator(LogicalKeyboardKey.escape),
  ]);

  // Pack page.
  static const pinHeader = KeyBinding('Pin or unpin the header', [
    SingleActivator(LogicalKeyboardKey.keyH),
  ]);
  static const fileSearch = KeyBinding('Search this pack’s file names', [
    PrimaryActivator(LogicalKeyboardKey.keyF),
  ]);
  static const clearFileSearch = KeyBinding(
    'In the file search: clear it, then leave it',
    [SingleActivator(LogicalKeyboardKey.escape)],
  );
  static const focusPrevious = KeyBinding('Focus mode: previous card', [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]);
  static const focusNext = KeyBinding('Focus mode: next card', [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]);
  static const leaveFocus = KeyBinding('Leave focus mode', [
    SingleActivator(LogicalKeyboardKey.escape),
  ]);
  static const playStop = KeyBinding('Audio: play or stop the selected sound', [
    SingleActivator(LogicalKeyboardKey.space),
  ]);
  static const playAll = KeyBinding(
    'Audio: play all shown sounds in order, or stop',
    [SingleActivator(LogicalKeyboardKey.space, shift: true)],
  );
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
  static const viewerCopy = KeyBinding('Copy the shown image (Linux)', [
    PrimaryActivator(LogicalKeyboardKey.keyC),
  ]);

  // Model viewer.
  static const modelPrevious = KeyBinding('Previous model', [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]);
  static const modelNext = KeyBinding('Next model', [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]);
  static const turnLeft = KeyBinding('Turn the model left', [
    SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true),
  ]);
  static const turnRight = KeyBinding('Turn the model right', [
    SingleActivator(LogicalKeyboardKey.arrowRight, shift: true),
  ]);
  static const tiltUp = KeyBinding('Look from higher up', [
    SingleActivator(LogicalKeyboardKey.arrowUp),
    SingleActivator(LogicalKeyboardKey.arrowUp, shift: true),
  ]);
  static const tiltDown = KeyBinding('Look from lower down', [
    SingleActivator(LogicalKeyboardKey.arrowDown),
    SingleActivator(LogicalKeyboardKey.arrowDown, shift: true),
  ]);
  static const modelZoomIn = KeyBinding('Zoom in', [
    CharacterActivator('+'),
    CharacterActivator('='),
  ]);
  static const modelZoomOut = KeyBinding('Zoom out', [CharacterActivator('-')]);
  static const resetCamera = KeyBinding('Reset the camera', [
    CharacterActivator('0'),
  ]);

  // Material viewer.
  static const materialPrevious = KeyBinding('Previous material', [
    SingleActivator(LogicalKeyboardKey.arrowLeft),
  ]);
  static const materialNext = KeyBinding('Next material', [
    SingleActivator(LogicalKeyboardKey.arrowRight),
  ]);
  static const materialSphere = KeyBinding('Sphere', [CharacterActivator('1')]);
  static const materialPlane = KeyBinding('Plane', [CharacterActivator('2')]);
  static const materialTiled = KeyBinding('Tiled 3 × 3', [
    CharacterActivator('3'),
  ]);
  static const materialMap = KeyBinding('The picked map', [
    CharacterActivator('4'),
  ]);
  static const materialZoomIn = KeyBinding('Zoom in', [
    CharacterActivator('+'),
    CharacterActivator('='),
  ]);
  static const materialZoomOut = KeyBinding('Zoom out', [
    CharacterActivator('-'),
  ]);
  static const materialReset = KeyBinding('Reset the light, turn and zoom', [
    CharacterActivator('0'),
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
      AppKeys.playAll,
      AppKeys.seekBack,
      AppKeys.seekForward,
      AppKeys.framesUp,
      AppKeys.framesDown,
    ],
  ),
  (
    'Image viewer',
    [AppKeys.viewerPrevious, AppKeys.viewerNext, AppKeys.viewerCopy],
  ),
  (
    'Model viewer',
    [
      AppKeys.modelPrevious,
      AppKeys.modelNext,
      AppKeys.turnLeft,
      AppKeys.turnRight,
      AppKeys.tiltUp,
      AppKeys.tiltDown,
      AppKeys.modelZoomIn,
      AppKeys.modelZoomOut,
      AppKeys.resetCamera,
    ],
  ),
  (
    'Material viewer',
    [
      AppKeys.materialPrevious,
      AppKeys.materialNext,
      AppKeys.materialSphere,
      AppKeys.materialPlane,
      AppKeys.materialTiled,
      AppKeys.materialMap,
      AppKeys.materialZoomIn,
      AppKeys.materialZoomOut,
      AppKeys.materialReset,
    ],
  ),
];

/// Mouse gestures the Help page lists next to the shortcuts.
List<MouseHelp> get mouseHelp => [
  MouseHelp('Mouse back button', 'Same as Esc: back'),
  MouseHelp('Middle-click a pack', 'Open it in a new tab (behind this one)'),
  MouseHelp('Right-click a pack', 'Menu with "Open in new tab"'),
  MouseHelp('Middle-click a tab', 'Close it'),
  MouseHelp('$primaryKey + wheel over a grid', 'Bigger or smaller thumbnails'),
  MouseHelp('Click a size slider\'s end icon', 'One size smaller or larger'),
  MouseHelp('Hover a dashboard tile', 'Play its animation'),
  MouseHelp(
    'Rest on the slim header bar',
    'Show the full header (after a moment)',
  ),
  MouseHelp('Click the Dashboard tab', 'Back to the dashboard from a pack'),
  MouseHelp('Click a star', 'Add a pack or file to favorites, or remove it'),
  MouseHelp(
    'Click an animation, image, model or material card',
    'Focus mode: dim (and pause) the others',
  ),
  MouseHelp('Hover a model card', 'Turn the model slowly'),
  MouseHelp('Hover a sound card', 'Show its star and Show in file manager'),
  MouseHelp(
    'Click or drag a playing sound card\'s waveform',
    'Seek (sounds of 10 s or more)',
  ),
  MouseHelp(
    'Rest on a sound\'s format chip',
    'Its rate, channels, bit depth or bitrate',
  ),
  MouseHelp(
    'Click a model\'s format chip',
    'Draw that file (GLB, glTF, OBJ) or show it in the file manager',
  ),
  MouseHelp(
    'Click a map chip on a material card',
    'Show that map in the card (again: the picture)',
  ),
  MouseHelp(
    'Click a material\'s tool chip',
    'Show that file (MaterialX, Godot, Blender…) in the file manager',
  ),
  MouseHelp('Open image icon on a card', 'Show it in the image viewer'),
  MouseHelp(
    'Right-click a file card or row (or the viewer\'s picture)',
    'Copy as GIF to clipboard and Copy as GIF file (animations), Copy image '
        'to clipboard, Copy file, Copy path, Open, Open with…',
  ),
  MouseHelp(
    'Wheel in the image viewer',
    'Zoom (opens at 1:1); drag to pan, double-click fits',
  ),
  MouseHelp('Wheel over the Frames field', 'Step through counts that fit'),
  MouseHelp('$primaryKey + wheel over All previews', 'Fewer or more columns'),
  MouseHelp('Wheel over the Edit preview', 'Zoom (−, +, reset on hover)'),
  MouseHelp('$primaryKey / Shift-click images', 'Select frames to combine'),
  MouseHelp(
    'Double-click an image or animation card',
    'Open it in the image viewer',
  ),
  MouseHelp('Double-click a model card', 'Open it in the model viewer'),
  MouseHelp('Double-click a material card', 'Open it in the material viewer'),
  MouseHelp('Drag in the material viewer', 'Turn the light'),
  MouseHelp('Right- or middle-drag in the material viewer', 'Turn the sphere'),
  MouseHelp(
    'Wheel in the material viewer',
    'Zoom (the map: zoom and drag to pan)',
  ),
  MouseHelp('Click a map in the material viewer\'s strip', 'Show that map'),
  MouseHelp('Drag in the model viewer', 'Orbit around the model'),
  MouseHelp(
    'Right- or middle-drag in the model viewer',
    'Move the model (pan)',
  ),
  MouseHelp('Wheel or pinch in the model viewer', 'Zoom'),
  MouseHelp('Double-click in the model viewer', 'Reset the camera'),
];

/// The mouse back button, offered to the focused widget before the app
/// closes a page: in-page state (a focused card) is left first, as Esc does.
class BackIntent extends Intent {
  const BackIntent();
}

/// Takes the mouse back button ([BackIntent]) while [enabled].
class BackHandler extends StatelessWidget {
  const BackHandler({
    super.key,
    required this.enabled,
    required this.onBack,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {BackIntent: _BackAction(enabled, onBack)},
    child: child,
  );
}

class _BackAction extends Action<BackIntent> {
  _BackAction(this.enabled, this.onBack);

  final bool enabled;
  final VoidCallback onBack;

  @override
  bool isEnabled(BackIntent intent) => enabled;

  @override
  Object? invoke(BackIntent intent) {
    onBack();
    return true;
  }
}

/// Offers the mouse back button to the focused widget; true when it took
/// it.
bool offerBack() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context != null &&
      Actions.maybeInvoke(context, const BackIntent()) == true;
}
