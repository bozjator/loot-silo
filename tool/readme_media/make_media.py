#!/usr/bin/env python3
"""Turns the README media test's output into docs/media/ (M53).

Run from the repo root:

  tool/readme_media/make_media.sh   (runs both steps below)

or by hand:

  README_MEDIA=1 xvfb-run -a -s "-screen 0 1440x900x24" \\
    flutter test integration_test/readme_media_test.dart -d linux
  python3 tool/readme_media/make_media.py

Needs Pillow. Screenshots (screenshots/readme/*.png) become palette PNGs; each
frames/<name>/ folder (raw RGBA + frames.json with real capture times)
becomes <name>.gif at about 12 fps, at most 8 s and 3 MB.
"""
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'screenshots', 'readme')
OUT = os.path.join(ROOT, 'docs', 'media')

FPS = 12
MAX_SECONDS = 8.0
MAX_GIF_BYTES = 3 * 1024 * 1024
GIF_WIDTHS = (960, 800, 720, 640)


def screenshot(name):
    img = Image.open(os.path.join(SRC, name)).convert('RGB')
    # A UI with flat colours: 256 colours with dithering off look the same
    # and are a fraction of the size.
    pal = img.quantize(colors=256, method=Image.Quantize.MEDIANCUT,
                       dither=Image.Dither.NONE)
    path = os.path.join(OUT, name)
    pal.save(path, optimize=True)
    return path


def load_frames(folder):
    meta = json.load(open(os.path.join(folder, 'frames.json')))
    frames = []
    for i, m in enumerate(meta):
        raw = open(os.path.join(folder, f'{i:04d}.rgba'), 'rb').read()
        frames.append((m['t'], Image.frombytes('RGBA', (m['w'], m['h']), raw).convert('RGB')))
    return frames


def resample(frames):
    """Frames at a steady FPS from the real capture times, at most
    MAX_SECONDS long; each output frame is the latest capture before it."""
    if not frames:
        return []
    start = frames[0][0]
    end = min(frames[-1][0], start + MAX_SECONDS * 1000)
    out, i, t = [], 0, start
    while t <= end:
        while i + 1 < len(frames) and frames[i + 1][0] <= t:
            i += 1
        out.append(frames[i][1])
        t += 1000 / FPS
    return out


def save_gif(frames, path, width):
    h = round(frames[0].height * width / frames[0].width)
    scaled = [f.resize((width, h), Image.LANCZOS) for f in frames]
    # One palette for the whole GIF, from a strip of sample frames, so
    # colours don't flicker between frames.
    sample = Image.new('RGB', (width, h * min(6, len(scaled))))
    for k in range(min(6, len(scaled))):
        sample.paste(scaled[k * len(scaled) // min(6, len(scaled))], (0, h * k))
    palette = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    pal = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in scaled]
    pal[0].save(path, save_all=True, append_images=pal[1:],
                duration=round(1000 / FPS), loop=0, optimize=True, disposal=1)
    return os.path.getsize(path)


def gif(name):
    frames = resample(load_frames(os.path.join(SRC, 'frames', name)))
    path = os.path.join(OUT, name + '.gif')
    for width in GIF_WIDTHS:
        size = save_gif(frames, path, width)
        if size <= MAX_GIF_BYTES:
            return path, width, len(frames), size
    sys.exit(f'{name}.gif is still {size} bytes at {width} px')


def main():
    if not os.path.isdir(SRC):
        sys.exit(f'No {SRC}: run integration_test/readme_media_test.dart first.')
    os.makedirs(OUT, exist_ok=True)
    total = 0
    for name in sorted(os.listdir(SRC)):
        if name.endswith('.png'):
            path = screenshot(name)
            total += os.path.getsize(path)
            print(f'{name}: {os.path.getsize(path) // 1024} KB')
    frames_dir = os.path.join(SRC, 'frames')
    for name in sorted(os.listdir(frames_dir)) if os.path.isdir(frames_dir) else []:
        path, width, count, size = gif(name)
        total += size
        print(f'{name}.gif: {count} frames, {width} px, {size // 1024} KB')
    print(f'total {total / 1024 / 1024:.1f} MB')


if __name__ == '__main__':
    main()
