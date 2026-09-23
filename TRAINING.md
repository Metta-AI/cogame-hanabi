# Metta post-training data

The native simulator and published `conventions` policy export supervised
examples for both certified Hanabi variants:

```sh
nimby sync nimby.lock
for variant in standard sprint; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/hanabi-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
games. Every row contains the acting seat's hosted system and user prompts
and a `conventions` move accepted by the game's reply parser and legal-move
rule. Parsed moves drive the simulator. Whole games stay in one split. The
manifest records source revision, variant, team score, end reason, and row
counts. Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/hanabi-standard \
  --output /tmp/hanabi-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games yielded 512 training and 125 validation examples for
standard, and 384 training and 96 validation examples for sprint. All 1,117
examples fit the Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum
was 3,115. One CPU optimizer step per variant with a local tiny model verifies
the Metta post-training path. These examples distill the scripted teacher;
they do not establish stronger league play.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/hanabi-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/hanabi-train-bridge
```

Both certified variants expose 284 numeric observation values and 48 fixed
move slots. The simulator's legality rule masks unavailable plays, discards,
and hints. Numeric and semantic observations hide the acting seat's card
identities while retaining public cards, hints, fireworks, and discards. The
`conventions` policy supplies opponents and teacher labels. Terminal scores
remain the native shared team score; training utilities give every seat the
same signed value, `2 * team_score / 25 - 1`, so cooperative episodes yield
a learning signal. Hosted prompts remain available to post-training.
