import 'package:flutter/material.dart';

/// Hand cursor over enabled controls, arrow when disabled. Flutter's desktop
/// default is the arrow everywhere; this app shows the hand on anything
/// clickable.
const clickCursor = WidgetStateMouseCursor.clickable;

/// [theme] with [clickCursor] for every control that reads its cursor from
/// the theme. [InkWell] and chips don't; pass `mouseCursor: clickCursor`
/// there, and use [deleteIcon] for chips that only delete.
ThemeData withClickCursors(ThemeData theme) {
  const button = ButtonStyle(mouseCursor: clickCursor);
  return theme.copyWith(
    iconButtonTheme: const IconButtonThemeData(style: button),
    filledButtonTheme: const FilledButtonThemeData(style: button),
    textButtonTheme: const TextButtonThemeData(style: button),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: button),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: button),
    segmentedButtonTheme: const SegmentedButtonThemeData(style: button),
    menuButtonTheme: const MenuButtonThemeData(style: button),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      mouseCursor: clickCursor,
    ),
    checkboxTheme: const CheckboxThemeData(mouseCursor: clickCursor),
    radioTheme: const RadioThemeData(mouseCursor: clickCursor),
    switchTheme: const SwitchThemeData(mouseCursor: clickCursor),
    popupMenuTheme: const PopupMenuThemeData(mouseCursor: clickCursor),
    listTileTheme: const ListTileThemeData(mouseCursor: clickCursor),
    tabBarTheme: const TabBarThemeData(mouseCursor: clickCursor),
  );
}

/// A chip delete icon with the hand cursor; a chip without an `onPressed`
/// or `onSelected` would otherwise show the arrow over its delete button.
const Widget deleteIcon = MouseRegion(
  cursor: SystemMouseCursors.click,
  child: Icon(Icons.clear, size: 18),
);
