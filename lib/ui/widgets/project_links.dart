import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../version.dart';
import '../cursors.dart';

/// Opens a web link; tests swap it so no browser opens.
final urlLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => launchUrl,
);

/// "Star the project on GitHub" and "Download it on itch.io", with the link
/// on the site's name only (Settings → About and the end of Help).
class ProjectLinks extends StatelessWidget {
  const ProjectLinks({super.key, this.textAlign = TextAlign.start});

  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: textAlign == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start,
    children: [
      _LinkLine(
        before: 'Star the project on ',
        link: 'GitHub',
        url: appGitHubUrl,
        textAlign: textAlign,
      ),
      const SizedBox(height: 4),
      _LinkLine(
        before: 'Download it on ',
        link: 'itch.io',
        url: appItchUrl,
        textAlign: textAlign,
      ),
    ],
  );
}

class _LinkLine extends ConsumerWidget {
  const _LinkLine({
    required this.before,
    required this.link,
    required this.url,
    required this.textAlign,
  });

  final String before;
  final String link;
  final String url;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return Text.rich(
      textAlign: textAlign,
      TextSpan(
        style: style,
        children: [
          TextSpan(text: before),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: InkWell(
              key: ValueKey('link:$link'),
              mouseCursor: clickCursor,
              onTap: () => ref.read(urlLauncherProvider)(Uri.parse(url)),
              child: Text(
                link,
                style: style?.copyWith(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
