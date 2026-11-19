import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/animation_detector.dart';
import 'animated_sprite.dart';
import 'pixel_image.dart';

/// One of a pack's previews: a sprite sheet [anim] plays its frames, any
/// other file is shown as an image (GIFs and animated WebPs play), fitted
/// in the box or, with [fill], filling it.
class PreviewPicture extends StatelessWidget {
  const PreviewPicture({
    super.key,
    required this.packPath,
    required this.rel,
    this.anim,
    this.playing = true,
    this.fill = false,
  });

  final String packPath;

  /// Relative to the pack.
  final String rel;

  /// The file's animation, when it is one (overrides applied).
  final SpriteAnim? anim;
  final bool playing;

  /// An image covers the whole box, cropped at the sides it overflows, in
  /// whole-pixel steps up so pixel art stays crisp. Sprite sheets always
  /// fit: a cropped frame would cut the character.
  final bool fill;

  /// Whether it fills its box: [fill] and not a sprite sheet. Callers drop
  /// their inset around it then.
  bool get fills => fill && anim?.kind != AnimKind.sheet;

  @override
  Widget build(BuildContext context) => switch (anim) {
    final a? when a.kind == AnimKind.sheet => AnimatedSprite(
      packPath: packPath,
      anim: a,
      playing: playing,
    ),
    _ when fill => PixelImage(
      File(p.join(packPath, rel)),
      animate: playing,
      fit: BoxFit.cover,
      scale: (s) => s >= 1 ? s.ceilToDouble() : s,
    ),
    _ => PixelImage(File(p.join(packPath, rel)), animate: playing),
  };
}
