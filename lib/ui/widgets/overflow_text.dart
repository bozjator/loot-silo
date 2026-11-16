import 'package:flutter/material.dart';

import 'own_semantics_node.dart';

/// One line of text cut with an ellipsis; when it is cut, hovering shows
/// the whole text in a tooltip. The tooltip line has its own semantics
/// node ([OwnSemanticsNode]): these lines sit beside others that can have
/// one too.
class OverflowText extends StatelessWidget {
  const OverflowText(this.text, {super.key, this.style, this.tooltip});

  final String text;
  final TextStyle? style;

  /// Shown on hover whether or not the line is cut (a longer form of it).
  final String? tooltip;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final line = Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
      if (tooltip case final tip?) return _tip(tip, line);
      if (!constraints.hasBoundedWidth) return line;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final cut = painter.didExceedMaxLines;
      painter.dispose();
      return cut ? _tip(text, line) : line;
    },
  );

  static Widget _tip(String message, Widget line) => OwnSemanticsNode(
    child: Tooltip(message: message, child: line),
  );
}
