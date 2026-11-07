import 'package:flutter/material.dart';

/// Padding around a pack page tab's toolbar (view options left, controls
/// right): the same in every tab, so switching tabs doesn't move anything.
const tabToolbarPadding = EdgeInsets.fromLTRB(16, 4, 16, 0);

/// The toolbar row's height: the thumbnail slider's, the tallest control.
/// Tabs without a slider (Audio) get the same height, so their view toggle
/// sits where the Images tab's does.
const tabToolbarHeight = 48.0;

/// Space between a tab's toolbar and the first row of its content.
const tabContentGap = 4.0;

/// The toolbar row at the top of the Animations, Images and Audio tabs.
class TabToolbar extends StatelessWidget {
  const TabToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: tabToolbarPadding,
    child: SizedBox(
      height: tabToolbarHeight,
      child: Row(children: children),
    ),
  );
}
