#!/usr/bin/env python3
"""Turn the nano-banana cog sheet into the four seat sprites.

`scripts/art/source/cogs_sheet.png` is one nano-banana render
(`gemini-2.5-flash-image`, prompt in `scripts/art/README.md`) of four Softmax
cogs on a flat green backdrop, each holding a fan of four cards turned OUTWARD
— the Hanabi pose. Gemini returns no alpha and the "pure green" comes back as
*some* green with a tinted edge, so this script:

  1. takes the backdrop colour as the median of the image border,
  2. flood-fills the backdrop from the border only, so the green cog's own
     plating survives,
  3. splits the row on empty columns,
  4. crops, pads each cog to a square and resizes it to SIZE px.

Output: data/soldier_{red,blue,green,yellow}_front.png — the files
client/renderer.js draws at the left of each seat row. Colour order matches the
renderer's COLORS (seat 0 red, 1 blue, 2 green, 3 yellow).

    python3 scripts/art/split_cog_sheet.py
"""
from collections import deque
from pathlib import Path

from PIL import Image

ROLES = ["red", "blue", "green", "yellow"]
SIZE = 192
TOLERANCE = 60          # per-channel distance that still counts as backdrop
MIN_COLUMN_INK = 4      # opaque pixels needed for a column to be "not a gap"

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "scripts" / "art" / "source" / "cogs_sheet.png"
OUT_DIR = ROOT / "data"


def border_colour(image):
    width, height = image.size
    pixels = image.load()
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(height):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def knockout(image):
    """Flood-fill the backdrop inward from the border; everything else stays."""
    width, height = image.size
    pixels = image.load()
    key = border_colour(image)

    def is_key(x, y):
        r, g, b = pixels[x, y][:3]
        return (abs(r - key[0]) <= TOLERANCE and abs(g - key[1]) <= TOLERANCE
                and abs(b - key[2]) <= TOLERANCE)

    seen = bytearray(width * height)
    queue = deque()
    for x in range(width):
        for y in (0, height - 1):
            if is_key(x, y) and not seen[y * width + x]:
                seen[y * width + x] = 1
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if is_key(x, y) and not seen[y * width + x]:
                seen[y * width + x] = 1
                queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height and not seen[ny * width + nx]:
                if is_key(nx, ny):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    for y in range(height):
        row = y * width
        for x in range(width):
            if seen[row + x]:
                pixels[x, y] = (0, 0, 0, 0)
    return image


def column_spans(image):
    width, height = image.size
    alpha = image.split()[3].load()
    filled = []
    for x in range(width):
        ink = 0
        for y in range(height):
            if alpha[x, y] > 24:
                ink += 1
                if ink >= MIN_COLUMN_INK:
                    break
        filled.append(ink >= MIN_COLUMN_INK)
    spans = []
    start = None
    for x, has_ink in enumerate(filled):
        if has_ink and start is None:
            start = x
        elif not has_ink and start is not None:
            spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, width))
    return [span for span in spans if span[1] - span[0] > width // 40]


def square(image):
    bounds = image.getbbox()
    cropped = image.crop(bounds)
    side = max(cropped.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(cropped, ((side - cropped.width) // 2,
                           (side - cropped.height) // 2))
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    sheet = knockout(Image.open(SOURCE).convert("RGBA"))
    spans = column_spans(sheet)
    if len(spans) != len(ROLES):
        raise SystemExit(
            f"expected {len(ROLES)} cogs in the sheet, found {len(spans)}: {spans}")
    for role, (x0, x1) in zip(ROLES, spans):
        sprite = square(sheet.crop((x0, 0, x1, sheet.height)))
        path = OUT_DIR / f"soldier_{role}_front.png"
        sprite.save(path)
        print(f"{path.relative_to(ROOT)}: {sprite.width}x{sprite.height}")


if __name__ == "__main__":
    main()
