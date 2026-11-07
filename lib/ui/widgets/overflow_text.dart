import 'package:flutter/material.dart';

/// One line of text cut with an ellipsis; when it is cut, hovering shows
/// the whole text in a tooltip.
class OverflowText extends StatelessWidget {
  const OverflowText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

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
      return cut ? Tooltip(message: text, child: line) : line;
    },
  );
}
