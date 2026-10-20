# Private language training

The hosted game owns language requests, prompt construction, reply normalization,
and action application. Five training rule presentations are available: canonical,
plain, numbered, questions, and reordered. Two presentations, heldout-briefing
and heldout-reference, are evaluation-only. Original rules, hidden-hand views,
legal moves, scoring, operator strategy, notes, and banners remain unchanged.

Set game configuration `promptVariant` and nonnegative `promptSeed`. Canonical
is the default. Mixed requires an explicit prompt seed and selects one of five
training rule presentations independently of the deck seed. Selection stays fixed
throughout the episode and retries. It never enters public replay.

The native Messages endpoint is `COWORLD_LLM_ENDPOINT`; set
`COWORLD_LLM_MODEL` to a registered `checkpoint/<artifact-sha256>` identity.
`COWORLD_LLM_TEMPERATURE` selects temperature from zero through one;
when absent, the provider default remains unchanged. Saved players and the
verified learner gateway must use the same sampling policy and token budgets.

For private hosted evidence, supply `COGAME_SAVE_TRAJECTORY_URI`,
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`.
The game records native attempts, retries, call identities, executed actions,
prompt selection, and hashes of the actual rendered messages.
Missing credentials or invalid replies produce fallbacks, excluded from model
learning targets. Unknown external actions are not teacher labels.

After syncing `nimby.lock`, commit the qualified source and run:

```sh
nim c --path:src --out:/tmp/export-posttrain tools/export_posttrain.nim
/tmp/export-posttrain /tmp/hanabi-private-candidates 10 1 standard mixed 3
python3 tests/test_training_corpus.py /tmp/hanabi-private-candidates
```

The exporter supports standard and sprint, uses ordinary sampled rules, requires
at least ten complete games, and rejects held-out wording. Mixed exports cycle
five wordings independently within training and validation. Episode IDs include
requested selection, resolved wording, and prompt seed to distinguish matched collections. The existing private complete-episode format retains
selected teacher decisions and the exact source revision. Every fifth seed goes
to validation; mode and wording replicas share seed families. Existing output
directories are rejected. The `hanabi-rules-v3` bank uses independent explanations of complete mechanics
and varies section order without introducing partner conventions. Canonical text and
reply syntax stay exact.


The persistent bridge accepts `MANIFEST [standard|sprint] [--language]`.
Reset commands accept `promptVariant`, `promptSeed`, and `split`;
training rejects held-out wording. Language mode retains normalized notes and
banners. Numeric mode retains the original 284 values and 48 action slots.
Run `python3 tools/test_prompt_games.py BRIDGE [ORIGINAL_BRIDGE]` for
complete-game comparisons.

The conventions teacher uses only the acting seat's private information.
Hidden own-card identities and deck order cannot influence its labels.
Candidate generation and deterministic tests do not establish stronger model
play or prevention of training collapse. Matched learning comparisons remain
unrun. Reinforcement learning requires actual sampled token IDs and draw-time
behavior probabilities from the owned serving engine; greedy outputs and
teacher labels do not provide them.
