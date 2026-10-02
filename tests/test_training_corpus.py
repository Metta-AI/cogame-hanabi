"""Check complete private episodes and explicit teacher targets."""

import json
import stat
import sys
from pathlib import Path

output = Path(sys.argv[1])
manifest = json.loads((output / "manifest.json").read_text())
assert manifest["format"] == "coworld-private-complete-episodes-v1"
assert stat.S_IMODE(output.stat().st_mode) == 0o700
seen = {"train": set(), "validation": set()}
for run in manifest["runs"]:
    path = output / run["split"] / (run["episode_id"] + ".jsonl")
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(rows) == 1
    row = rows[0]
    assert row["episode"]["status"] == "completed"
    assert row["episode"]["source_revision"] == manifest["source_revision"]
    assert row["episode"]["outcome"] == run["results"]
    decisions = row["decisions"]
    assert decisions and decisions[-1]["terminal"]
    chosen = set(run["selected_decision_ids"])
    assert chosen
    actual = set()
    for decision in decisions:
        if decision["decision_id"] in chosen:
            selected = next(
                a
                for a in decision["attempts"]
                if a["attempt_id"] == decision["selected_attempt_id"]
            )
            assert selected["origin"] == "teacher"
            assert selected["policy"] == manifest["teacher_policy"]
            assert selected["parsed_action"] == decision["executed_action"]
            assert selected["prompt"]
            actual.add(decision["decision_id"])
    assert actual == chosen
    seen[run["split"]].add(run.get("game", manifest["game"]))
assert seen["train"] == seen["validation"]
print(
    "Complete episodes, private files, and selected teacher action joins passed:",
    len(manifest["runs"]),
)
