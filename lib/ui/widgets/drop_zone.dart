import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

/// Accepts files dragged in from the desktop and shows a hint while
/// something hovers.
class DropZone extends StatefulWidget {
  const DropZone({
    super.key,
    required this.onDrop,
    required this.child,
    this.enabled,
  });

  final ValueChanged<List<String>> onDrop;

  /// Whether it takes drops now; always when null. Every drop target on
  /// screen gets every drop, also one under another page.
  final bool Function()? enabled;
  final Widget child;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) {
        if (widget.enabled?.call() ?? true) setState(() => _hovering = true);
      },
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        if (!(widget.enabled?.call() ?? true)) return;
        widget.onDrop([for (final f in details.files) f.path]);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering)
            IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.85),
                  border: Border.all(color: scheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.file_download,
                        size: 64,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Drop archives or folders to import',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
