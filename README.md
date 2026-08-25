# Hanabi

**Hanabi** for the Softmax Coworld platform, forked from
[cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip) (parley →
babel → bullwhip lineage). Four cogs hold four cards each, **facing out** —
everyone can see them except their owner — and build five colour-ordered
firework stacks out of a seeded 50-card deck (five colours, ranks
`1 1 1 2 2 3 3 4 4 5`). On your turn you do exactly one of three things:

- **play** a card from a slot (right rank for its stack, or a misplay that
  burns one of three fuses),
- **discard** one, which returns a hint token (illegal at 8 tokens),
- spend one of the eight **hint** tokens to tell another seat every card of
  one colour or one rank they hold.

Three misplays end the game; so does finishing all five fireworks; and when
the last card is drawn every seat — including the one who drew it — takes
one more turn. **The score is the sum of the five stacks, 0..25, and it is
the same number for every seat.** Fully cooperative, partially observed, and
the whole skill is the theory of mind around hints: what did that hint mean,
and what does your partner think it meant? A hint is the only channel
between you — there is no chat.

**The game is LLM-driven and a policy is just a prompt.** Hanabi is
turn-based, so on seat `turn mod 4`'s turn the game server sends that seat's
policy prompt plus its observation — the three partners' hands face-up, its
**own hand as knowledge only** (positive hints, negative information, the
candidate set, `knownPlayable`/`knownDead`, the chop), the fireworks, the
discard pile, the tokens, the whole public move log and an enumerated list
of every legal move — to Claude, and Claude answers with one JSON object
copied from that list (plus an optional private `note` and a
spectator-only `banner`). One request per turn, one retry on a rejected
reply, then the scripted fallback. Player containers exist only to deliver
their prompt over the websocket.

Two built-in **scripted baselines** — `conventions` (play what you can
prove, save a partner's last copy off its chop, otherwise give the hint that
makes the most cards newly playable, otherwise discard your chop) and
`cautious` (never misplays, never gambles) — play any seat that registers as
scripted, and every seat when no LLM credentials are available, so episodes
and offline certification always complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy
display names never reach any prompt or player frame, so nobody can
meta-game "that seat is the champion". The spectator and replay viewers map
the aliases back to policy names; results are reported under policy names.

**Reading the league:** every seat gets the team's score, so head-to-head
Elo can never separate two champions — they tie in every episode they share.
The ranking signal is the **mean score over episodes** on the division
leaderboard, which differs because each champion plays different deals and
different partner mixes (the round-robin seats each champion with the
scripted fillers, with the other champion and with copies of itself — the
resident/visitor cross-play the ad-hoc-teamwork benchmark asks for).
`contributions` (cards a seat banked minus its misplays) is reported for
display only and is never ranked.

The episode ends `complete` — with `endReason` `perfect`, `strikeout`,
`deckout` or `turnlimit` — or `deadline` when the episode clock stops play
between turns (the score is the stacks as they stand).

## Layout

- `src/hanabi.nim` — entrypoint (Coworld runtime contract, live episode server)
- `src/hanabi/sim.nim` — pure rules: the seeded deck and deal, the numbered
  turn resolution, the knowledge/candidate model, the hint annotation,
  endings, the FNV-1a digest and the replay re-derivation; shared by the
  server, the tests and the wasm viewer
- `src/hanabi/llm.nim` — Claude client (one request per turn, one retry,
  then the fallback) + the two scripted baselines
- `src/hanabi/server.nim` — mummy HTTP/WS server (player, global)
- `src/hanabi_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — the inherited bullwhip chrome (`chrome.css` byte for byte plus
  one appended Hanabi block) around this game's table renderer
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`); the same
  Nim rules re-derive every frame in the browser
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `tools/ci/` — the CI harness: the raw-docker episode smoke, the viewer
  load test, the worst-case renderer fixture and the release policy set
- `data/` — the felt, the font (Rajdhani, OFL) and the four seat cogs
- `scripts/art/` — the nano-banana source sheet and the split script that
  produced those cogs
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim              # the rules
nim r -d:release --path:src tests/test_bot.nim   # baselines + reply parsing
nim r --path:src tests/test_prompt.nim           # redaction
nim r --path:src tests/test_replay.nim           # end to end + strict UTF-8
nim r --path:src tests/test_viewer.nim           # chrome invariants
nim c -d:release -o:bin/hanabi src/hanabi.nim
nim c -d:release -o:bin/hanabi-player src/hanabi_player.nim
nim c --hints:off -d:emscripten replay-viewer/hanabi_replay.nim  # wasm viewer
```

A full containerised episode (one game container plus one player container
per seat, exactly the certification fixture's seat mix) is what CI runs:

```bash
docker build --platform=linux/amd64 -t coworld-hanabi:ci .
./tools/ci/docker_smoke.sh coworld-hanabi:ci
```

Export `ANTHROPIC_API_KEY` for real Claude play; omit it and every seat
plays its scripted baseline.

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put hanabi anthropic_api_key <keyfile>   # hosted Claude
```

## Fielding a policy

```bash
uv run coworld upload-policy <hanabi image> --name my-hanabi \
  --run /bin/hanabi-player \
  --secret-env PLAYER_PROMPT="Your conventions, in words."
```

Or field a scripted baseline: same image, `--env PLAYER_SCRIPTED=conventions`
or `--env PLAYER_SCRIPTED=cautious`.

The two pages worth reading before you write a prompt are
`game.docs.pages` in `coworld_manifest_template.json`: **rules.md** (the
deck, the deal, slot numbering, the three actions and the numbered turn
resolution) and **hints-and-knowledge.md** (the candidate model, what your
observation contains and what it can never contain, the reply schema, and
the two baselines' algorithms).
