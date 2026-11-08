#!/usr/bin/env python3
"""Builds the Loot Silo branding assets from ../app_logos (read-only).

Sources: icon_full_centered.png (the app icon) and app-title-with-slogan.png
(the name and slogan). Run from the repo root:
    python3 tool/branding/make_branding.py
Needs Pillow. Writes assets/branding/*.png and the Linux/macOS/Windows icons.
"""
import os
import shutil
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, '..', 'app_logos')
OUT = os.path.join(ROOT, 'assets', 'branding')

ICON = 'icon_full_centered.png'
TITLE = 'app-title-with-slogan.png'


def trimmed(img):
    """[img] cut to its content: pixels more than faintly opaque (alpha > 8),
    so stray anti-aliasing doesn't widen the box."""
    return img.crop(img.getchannel('A').point(lambda a: 255 if a > 8 else 0).getbbox())


def square_canvas(img):
    """[img] centred on a transparent square canvas."""
    side = max(img.size)
    out = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    out.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
    return out


def logo_readme(icon, title, height=320):
    """The app's logo lockup, as AppLogo draws it: the app icon, then the
    "LootSilo" title with the slogan, [TITLE_SCALE] of the icon's height.
    Transparent, trimmed to its content."""
    gap = round(height * GAP_SCALE)
    th = round(height * TITLE_SCALE)
    tw = round(title.width * th / title.height)
    out = Image.new('RGBA', (height + gap + tw, height), (0, 0, 0, 0))
    i = icon.resize((height, height), Image.LANCZOS)
    out.paste(i, (0, 0), i)
    t = title.resize((tw, th), Image.LANCZOS)
    out.paste(t, (height + gap, (height - th) // 2), t)
    return trimmed(out)


# AppLogo's proportions (lib/ui/widgets/branding.dart): the title is this
# share of the icon's height, after a gap of this share.
TITLE_SCALE = 0.78
GAP_SCALE = 0.1


def save(img, name, size=None):
    if size:
        img = img.resize((size, size), Image.LANCZOS)
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    full = square_canvas(trimmed(Image.open(os.path.join(SRC, ICON)).convert('RGBA')))
    title = trimmed(Image.open(os.path.join(SRC, TITLE)).convert('RGBA'))
    save(full, 'icon_full.png', 512)
    save(full, 'icon_full_1024.png', 1024)
    save(full, 'icon_small.png', 64)
    for s in (16, 24, 32, 48, 64, 128, 256):
        save(full, f'icon_small_{s}.png', s)
    save(title, 'title_slogan.png')
    save(logo_readme(full, title), 'logo_readme.png')

    def best(size):
        return full.resize((size, size), Image.LANCZOS)

    linux = os.path.join(ROOT, 'linux', 'runner', 'resources')
    os.makedirs(linux, exist_ok=True)
    best(256).save(os.path.join(linux, 'app_icon.png'))

    best(256).save(
        os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico'),
        sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)],
        append_images=[best(s) for s in (16, 24, 32, 48, 64, 128)],
    )

    mac = os.path.join(ROOT, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    if os.path.isdir(mac):
        for s in (16, 32, 64, 128, 256, 512, 1024):
            best(s).save(os.path.join(mac, f'app_icon_{s}.png'))
    print('done', file=sys.stderr)


if __name__ == '__main__':
    main()
