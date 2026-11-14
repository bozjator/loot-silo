import 'package:flutter/material.dart';

/// Whether close buttons (a dialog's, a tab's) go on the left, as on macOS,
/// where window close buttons sit top left and Safari's tabs close on the
/// left. Read from the theme rather than `Platform`, so tests (and a debug
/// run on Linux) can show the macOS layout by setting `ThemeData.platform` or
/// `debugDefaultTargetPlatformOverride`.
bool closeOnLeft(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.macOS;

/// A dialog header's padding. The header starts with text ([text] before it)
/// and ends with the close button (8 after it). On macOS the close button
/// moves to the start, so the start gets 8; the end then holds the header's
/// last other button (8), or, when the header is only a title and the close
/// button ([titleOnly]), the title ([text]).
EdgeInsets dialogHeaderPadding(
  BuildContext context, {
  required double text,
  double top = 8,
  double bottom = 8,
  bool titleOnly = false,
}) => closeOnLeft(context)
    ? EdgeInsets.fromLTRB(8, top, titleOnly ? text : 8, bottom)
    : EdgeInsets.fromLTRB(text, top, 8, bottom);

/// The close (X) button in a dialog's header; see [closeOnLeft] for which end
/// of the header it goes on.
class DialogCloseButton extends StatelessWidget {
  const DialogCloseButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('dialog-close'),
    tooltip: 'Close',
    icon: const Icon(Icons.close),
    onPressed: () => Navigator.of(context).pop(),
  );
}
