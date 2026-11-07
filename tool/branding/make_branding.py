#!/usr/bin/env python3
"""Builds the Loot Silo branding assets from ../app_logos (read-only).

Run from the repo root:  python3 tool/branding/make_branding.py
Needs Pillow. Writes assets/branding/*.png, the Linux/macOS/Windows icons.
"""
import os
import sys

from PIL import Image, ImageDraw

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
# The wide logo: the right half of the transparent sheet. Specks of other
# art inside this box are dropped by [logo_wide].
WIDE = (720, 250, 1774, 700)


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


def logo_wide(sheet):
    crop = sheet.crop(WIDE)
    alpha = crop.getchannel('A').point(lambda a: 255 if a > 8 else 0)
    w, h = crop.size
    # Keep the longest run of non-empty columns and of rows: the logo.
    # A speck cut off by an empty column or row is other art.
    cols = longest_run([alpha.crop((x, 0, x + 1, h)).getbbox() is not None
                        for x in range(w)])
    rows = longest_run([alpha.crop((0, y, w, y + 1)).getbbox() is not None
                        for y in range(h)])
    return crop.crop((cols[0], rows[0], cols[1], rows[1]))


def longest_run(flags):
    """(start, end) of the longest run of True in [flags], end exclusive."""
    best, start = (0, 0), None
    for i, f in enumerate(flags + [False]):
        if f and start is None:
            start = i
        elif not f and start is not None:
            if i - start > best[1] - best[0]:
                best = (start, i)
            start = None
    return best


def save(img, name, size=None):
    if size:
        img = img.resize((size, size), Image.LANCZOS)
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    sheet = Image.open(os.path.join(SRC, 'LootSilo Game Asset Branding.png')).convert('RGB')
    wide_src = Image.open(
        os.path.join(SRC, 'a_clean_vector_3d_styled_game_tech_logo_image_on_a.png')
    ).convert('RGBA')

    full = icon_full(sheet)
    small = icon_small(sheet)
    save(full, 'icon_full.png', 512)
    save(full, 'icon_full_1024.png', 1024)
    save(small, 'icon_small.png', 64)
    for s in (16, 24, 32, 48, 64, 128, 256):
        save(small, f'icon_small_{s}.png', s)
    save(logo_wide(wide_src), 'logo_wide.png')

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
