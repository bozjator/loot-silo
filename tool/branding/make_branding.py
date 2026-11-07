#!/usr/bin/env python3
"""Builds the Loot Silo branding assets from ../app_logos (read-only).

Run from the repo root:  python3 tool/branding/make_branding.py
Needs Pillow and the Flutter SDK's Roboto (Apache License 2.0), found through
FLUTTER_ROOT or the `flutter` on PATH. Writes assets/branding/*.png and the
Linux/macOS/Windows icons.
"""
import os
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, '..', 'app_logos')
OUT = os.path.join(ROOT, 'assets', 'branding')

# The app icon: the left rounded square of the branding sheet (measured on
# the 1774×887 source: edges at x 71–662, y 121–737, corner radius ~120).
SQUARE = (71, 121, 663, 738)
RADIUS = 120
# A square around the silo (inside the icon, above its text), for the
# small icon.
SILO = (191, 127, 593, 529)
# The README logo's colours: a warm gold name and a mid-grey slogan, each
# with a dark outline, so both read on GitHub's white and near-black
# (#0d1117) backgrounds.
NAME_FILL = (255, 196, 61, 255)
SLOGAN_FILL = (139, 149, 165, 255)
OUTLINE = (20, 24, 36, 255)


def rounded_mask(size, radius, inset=1.0, scale=4):
    """An anti-aliased rounded-rectangle mask, [inset] px inside the edge."""
    w, h = size
    big = Image.new('L', (w * scale, h * scale), 0)
    i = inset * scale
    ImageDraw.Draw(big).rounded_rectangle(
        (i, i, w * scale - 1 - i, h * scale - 1 - i),
        radius=radius * scale,
        fill=255,
    )
    return big.resize((w, h), Image.LANCZOS)


def square_canvas(img):
    """[img] centred on a transparent square canvas."""
    side = max(img.size)
    out = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    out.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
    return out


def icon_full(sheet):
    crop = sheet.crop(SQUARE).convert('RGBA')
    crop.putalpha(rounded_mask(crop.size, RADIUS))
    return square_canvas(crop)


def icon_small(sheet):
    """The silo zoomed in on its own rounded square, without the text: a
    square crop of the art around the silo (its real background, so no
    seams), ending above the "LootSilo" text (which starts at y 533)."""
    crop = sheet.crop(SILO).convert('RGBA')
    w = SQUARE[2] - SQUARE[0]
    crop.putalpha(rounded_mask(crop.size, RADIUS * crop.width / w))
    return crop


def roboto(weight):
    """The Flutter SDK's Roboto-<weight>.ttf."""
    root = os.environ.get('FLUTTER_ROOT')
    if not root and shutil.which('flutter'):
        root = os.path.dirname(os.path.dirname(os.path.realpath(shutil.which('flutter'))))
    if not root:
        sys.exit('Set FLUTTER_ROOT (Roboto comes from the Flutter SDK).')
    return os.path.join(root, 'bin', 'cache', 'artifacts', 'material_fonts',
                        f'Roboto-{weight}.ttf')


def logo_readme(small, scale=2):
    """The app's logo lockup, as AppLogo draws it: the app icon's silo, then
    "Loot Silo" over the slogan. Transparent, trimmed to its content."""
    icon_side = 160 * scale
    gap = 28 * scale
    name_font = ImageFont.truetype(roboto('Bold'), 92 * scale)
    slogan_font = ImageFont.truetype(roboto('Medium'), 34 * scale)
    stroke = 3 * scale
    name, slogan = 'Loot Silo', 'Your game assets. At a glance.'

    def box(text, font, st):
        l, t, r, b = font.getbbox(text, stroke_width=st)
        return l, t, r - l, b - t

    nl, nt, nw, nh = box(name, name_font, stroke)
    sl, stp, sw, sh = box(slogan, slogan_font, scale)
    line_gap = 14 * scale
    text_h = nh + line_gap + sh
    height = max(icon_side, text_h)
    width = icon_side + gap + max(nw, sw)
    out = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    out.paste(small.resize((icon_side, icon_side), Image.LANCZOS),
              (0, (height - icon_side) // 2), small.resize((icon_side, icon_side), Image.LANCZOS))
    draw = ImageDraw.Draw(out)
    x = icon_side + gap
    y = (height - text_h) // 2
    draw.text((x - nl, y - nt), name, font=name_font, fill=NAME_FILL,
              stroke_width=stroke, stroke_fill=OUTLINE)
    draw.text((x - sl, y + nh + line_gap - stp), slogan, font=slogan_font,
              fill=SLOGAN_FILL, stroke_width=scale, stroke_fill=OUTLINE)
    return out.crop(out.getbbox())


def save(img, name, size=None):
    if size:
        img = img.resize((size, size), Image.LANCZOS)
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    sheet = Image.open(os.path.join(SRC, 'LootSilo Game Asset Branding.png')).convert('RGB')

    full = icon_full(sheet)
    small = icon_small(sheet)
    save(full, 'icon_full.png', 512)
    save(full, 'icon_full_1024.png', 1024)
    save(small, 'icon_small.png', 64)
    for s in (16, 24, 32, 48, 64, 128, 256):
        save(small, f'icon_small_{s}.png', s)
    save(logo_readme(small), 'logo_readme.png')

    # Platform icons: the small variant up to 64 px, the full one above.
    def best(size):
        return (small if size <= 64 else full).resize((size, size), Image.LANCZOS)

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
