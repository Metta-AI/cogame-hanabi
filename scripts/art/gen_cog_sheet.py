#!/usr/bin/env python3
"""Generate the Hanabi cog sheet with nano-banana (Gemini image generation).

One call, one sheet: four Softmax cogs in a row, each holding a fan of four
cards turned OUTWARD - the Hanabi pose - on a flat green backdrop, in the
four seat colours the chrome uses (seat 0 red, 1 blue, 2 green, 3 yellow).
The canonical cog render from coworld-ctf (`scripts/art/src_cvc/
agent_front.png`, itself a nano-banana render) is passed as an inline_data
part so the character design is anchored rather than reinvented.

    GEMINI_API_KEY=... python3 scripts/art/gen_cog_sheet.py

Writes scripts/art/source/cogs_sheet.png. Run split_cog_sheet.py afterwards
to key, split and pad it into data/soldier_<colour>_front.png. The key is
never printed, never written to a file and never passed as a URL parameter:
it is the `x-goog-api-key` header and nothing else.
"""
import base64
import json
import os
import urllib.request
from pathlib import Path

MODEL = "gemini-2.5-flash-image"
ENDPOINT = (f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{MODEL}:generateContent")
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "scripts" / "art" / "source" / "cogs_sheet.png"

PROMPT = """Using this robot character ("cog") as the exact character design reference, draw
FOUR of these cogs side by side in one row, evenly spaced, same size, full body, front-facing,
same clean cartoon rendering, each holding a small fan of four blank playing cards turned OUTWARD
away from itself (backs toward the cog, faces toward the viewer, cards blank).
Background: perfectly flat, solid, uniform pure bright green (#00FF00), no shadows, no gradients,
no floor - it will be chroma-keyed out.
FIRST cog: warm red (#e0523a) plating. SECOND cog: blue (#3f7cc4) plating.
THIRD cog: green (#45a85e) plating. FOURTH cog: yellow (#ddc531) plating.
The four cogs are identical apart from the plating colour. No text, no labels, no numbers."""


def main():
    reference = os.environ.get(
        "COG_REFERENCE",
        "/workspace/starters/coworld-ctf/scripts/art/src_cvc/agent_front.png")
    ref = base64.b64encode(Path(reference).read_bytes()).decode()
    body = {
        "contents": [{"parts": [
            {"inline_data": {"mime_type": "image/png", "data": ref}},
            {"text": PROMPT},
        ]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"],
                 "content-type": "application/json"})
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    part = next(p for p in payload["candidates"][0]["content"]["parts"]
                if "inlineData" in p)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(base64.b64decode(part["inlineData"]["data"]))
    print(f"{OUT.relative_to(ROOT)}: {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
