import 'package:flutter/material.dart';

import '../cursors.dart';

/// Star toggle for a pack or a file: filled amber when starred.
class FavoriteStar extends StatelessWidget {
  const FavoriteStar({
    super.key,
    required this.starred,
    required this.onPressed,
    this.size = 18,
    this.compact = true,
    this.tight = false,
  });

  final bool starred;
  final VoidCallback onPressed;
  final double size;
  final bool compact;

  /// No padding around the star: the button is just the icon, so its
  /// edges line up with what is next to it.
  final bool tight;

  /// The filled star's colour.
  static const color = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: starred ? 'Remove from favorites' : 'Add to favorites',
    mouseCursor: clickCursor,
    iconSize: size,
    visualDensity: compact ? VisualDensity.compact : null,
    style: tight
        ? IconButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size.square(size),
            fixedSize: Size.square(size),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )
        : null,
    color: starred ? color : null,
    icon: Icon(starred ? Icons.star : Icons.star_border),
    onPressed: onPressed,
  );
}
