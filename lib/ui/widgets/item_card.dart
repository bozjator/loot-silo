import 'package:flutter/material.dart';

import '../cursors.dart';
import 'favorite_star.dart';

/// Height of an [ItemCard]'s footer (title and details line), for the
/// grid delegates.
const itemCardFooter = 64.0;

/// One file in a detail page grid: the animation and image cards share it.
///
/// A [stage] over a footer with a title and a details line. Clicking focuses
/// the card ([focused] draws a border and grows it a little, [dimmed] fades
/// the others). On hover, [actions] overlay the footer's right end, the star
/// shows in the stage's top-right corner (always when [starred]) and
/// [leading] in the top-left (always with [showLeading]). [badge] sits in
/// the top-left corner whenever there is no [leading] shown.
class ItemCard extends StatefulWidget {
  const ItemCard({
    super.key,
    required this.path,
    required this.stage,
    required this.title,
    required this.details,
    required this.onTap,
    this.focused = false,
    this.dimmed = false,
    this.selected = false,
    this.starred = false,
    this.onToggleStar,
    this.actions = const [],
    this.leading,
    this.showLeading = false,
    this.badge,
    this.stagePadding = 8,
  });

  /// Pack-relative path: the footer's tooltip and the star's key.
  final String path;

  /// The picture; told whether the card is hovered (animations play then).
  final Widget Function(bool hover) stage;
  final String title;
  final String details;
  final VoidCallback onTap;
  final bool focused;
  final bool dimmed;

  /// Picked for a multi-file action: a border, without focus.
  final bool selected;
  final bool starred;

  /// None: no star.
  final VoidCallback? onToggleStar;

  /// Hover icons, all [CardIconButton] sized.
  final List<Widget> actions;
  final Widget? leading;
  final bool showLeading;
  final Widget? badge;
  final double stagePadding;

  @override
  State<ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<ItemCard> {
  var _hover = false;

  Widget _disc(Widget child) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
    shape: const CircleBorder(),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const duration = Duration(milliseconds: 200);
    final showLeading =
        widget.leading != null && (_hover || widget.showLeading);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        duration: duration,
        opacity: widget.dimmed ? 0.35 : 1,
        child: AnimatedScale(
          duration: duration,
          scale: widget.focused ? 1.04 : 1,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: widget.focused || widget.selected
                  ? BorderSide(color: scheme.primary, width: 2)
                  : BorderSide.none,
            ),
            child: InkWell(
              mouseCursor: clickCursor,
              onTap: widget.onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Padding(
                            padding: EdgeInsets.all(widget.stagePadding),
                            child: widget.stage(_hover),
                          ),
                          if (showLeading)
                            Positioned(
                              top: 2,
                              left: 2,
                              child: _disc(widget.leading!),
                            )
                          else if (widget.badge case final badge?)
                            Positioned(top: 6, left: 6, child: badge),
                          if (widget.onToggleStar case final toggle?
                              when _hover || widget.starred)
                            Positioned(
                              top: 2,
                              right: 2,
                              child: _disc(
                                FavoriteStar(
                                  key: ValueKey('star:${widget.path}'),
                                  starred: widget.starred,
                                  onPressed: toggle,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: itemCardFooter,
                    child: _footer(theme, scheme),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Title and details; the icons overlay them only while hovered, so the
  /// title gets the full width the rest of the time.
  Widget _footer(ThemeData theme, ColorScheme scheme) => Stack(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
        child: Tooltip(
          message: widget.path,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                widget.details,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      // Hidden (and not clickable) until hovered; clicks on the title
      // focus the card.
      Positioned(
        top: 0,
        right: 2,
        bottom: 0,
        child: IgnorePointer(
          ignoring: !_hover,
          child: AnimatedOpacity(
            key: const ValueKey('card-icons'),
            duration: const Duration(milliseconds: 150),
            opacity: _hover ? 1 : 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    scheme.surfaceContainerLow.withValues(alpha: 0),
                    scheme.surfaceContainerLow,
                  ],
                  stops: const [0, 0.2],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.actions,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// A card's hover icon: every one has this size.
class CardIconButton extends StatelessWidget {
  const CardIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: 18,
    visualDensity: VisualDensity.compact,
    color: color,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
