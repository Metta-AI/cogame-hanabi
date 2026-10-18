"""Check complete private candidate games; independent review owns training admission."""

import hashlib
import json
import stat
import sys
from pathlib import Path

output = Path(sys.argv[1])
manifest = json.loads((output / "manifest.json").read_text())
assert manifest["format"] == "coworld-private-candidates-v1"
assert manifest["review_required"]
assert stat.S_IMODE(output.stat().st_mode) == 0o700
assert not (output / "train").exists() and not (output / "validation").exists()
path = output / "trajectories.jsonl"
assert stat.S_IMODE(path.stat().st_mode) == 0o600
rows = [json.loads(line) for line in path.read_text().splitlines()]
episodes = {row["episode_id"]: row for row in rows if row["event_type"] == "episode"}
decisions = {}
for row in rows:
    if row["event_type"] == "decision":
        decisions.setdefault(row["episode_id"], []).append(row)
assert len(episodes) == len(manifest["runs"]) >= 10
for run in manifest["runs"]:
    episode = episodes[run["episode_id"]]
    assert episode["status"] == "completed"
    assert episode["seed_family"] == "hanabi-" + str(run["seed"])
    assert episode["source_revision"] == manifest["source_revision"]
    assert episode["outcome"] == run["results"]
    turns = decisions[run["episode_id"]]
    assert len(turns) == run["decisions"] and turns[-1]["terminal"]
    for row in turns:
        (attempt,) = row["attempts"]
        assert attempt["origin"] == "teacher" and attempt["accepted"]
        assert attempt["policy"] == manifest["teacher_policy"]
        assert row["executed_action"] == attempt["parsed_action"]
        (metadata,) = row["observation"]["prompt_attempts"]
        assert metadata["attempt_id"] == attempt["attempt_id"]
        for message in attempt["prompt"]:
            assert (
                metadata["prompt_template"][message["role"] + "_sha256"]
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
print(len(episodes), "complete private candidate games and actual teacher joins PASS")
