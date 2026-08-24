# Board art

The four seat cogs in `data/` are **nano-banana renders** (Gemini
`gemini-2.5-flash-image`), not procedural rigs and not the starter's
borrowed sprites: one sheet, four Softmax cogs in the chrome's seat colours,
each holding a fan of four cards turned **outward** — the Hanabi pose, so a
spectator can tell at board scale what this game is even with every label
hidden.

```
scripts/art/gen_cog_sheet.py     one API call -> source/cogs_sheet.png
scripts/art/source/cogs_sheet.png the committed render (the prompt is in the
                                  generator, so the asset is reproducible)
scripts/art/split_cog_sheet.py   key -> split -> pad -> data/soldier_*.png
```

```bash
GEMINI_API_KEY=… python3 scripts/art/gen_cog_sheet.py   # regenerate the sheet
python3 scripts/art/split_cog_sheet.py                  # re-cut the sprites
```

The character design reference passed to the model is coworld-ctf's
`scripts/art/src_cvc/agent_front.png`, the canonical front-on Softmax cog
(itself a nano-banana render), so the style is anchored rather than
reinvented. Gemini returns no alpha and paints "pure green" as *some* green
with a tinted edge, so `split_cog_sheet.py` takes the backdrop colour as the
median of the image border and flood-fills inward from the border only —
which is why the green cog's own plating survives the key.

Outputs, in the renderer's `COLORS` order (seat 0 red, 1 blue, 2 green,
3 yellow), 192 px square with alpha:

```
data/soldier_red_front.png
data/soldier_blue_front.png
data/soldier_green_front.png
data/soldier_yellow_front.png
```

`data/arena_floor.png` (the felt, tinted dark green by the renderer) and
`data/font.ttf` (Rajdhani SemiBold, SIL OFL — see `data/FONT_LICENSE.txt`)
are inherited from the bullwhip/coworld-ctf lineage unchanged. **No key is
ever printed, written to a file, passed as a URL parameter or committed.**
