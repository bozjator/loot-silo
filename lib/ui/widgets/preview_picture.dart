import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/animation_detector.dart';
import 'animated_sprite.dart';
import 'pixel_image.dart';

/// One of a pack's previews: a sprite sheet [anim] plays its frames, any
/// other file is shown as an image (GIFs and animated WebPs play).
class PreviewPicture extends StatelessWidget {
  const PreviewPicture({
    super.key,
    required this.packPath,
    required this.rel,
    this.anim,
    this.playing = true,
  });

  final String packPath;

  /// Relative to the pack.
  final String rel;

  /// The file's animation, when it is one (overrides applied).
  final SpriteAnim? anim;
  final bool playing;

  @override
  Widget build(BuildContext context) => switch (anim) {
    final a? when a.kind == AnimKind.sheet => AnimatedSprite(
      packPath: packPath,
      anim: a,
      playing: playing,
    ),
    _ => PixelImage(File(p.join(packPath, rel)), animate: playing),
  };
}
