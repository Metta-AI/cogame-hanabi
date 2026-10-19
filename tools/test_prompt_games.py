"""Complete published games through production bridges, including private notes."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import TextIO, cast

ROOT = Path(__file__).resolve().parents[1]
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
WORDINGS = TRAIN + ["heldout-briefing", "heldout-reference"]


def play(binary, variant, wording, seed, language, prompt_seed=0, original=False):
    process = subprocess.Popen(
        [
            str(binary),
            str(ROOT / "coworld_manifest_template.json"),
            variant,
            *(["--language"] if language else []),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    stdin = cast(TextIO, process.stdin)
    stdout = cast(TextIO, process.stdout)

    def request(payload):
        stdin.write(json.dumps(payload) + "\n")
        stdin.flush()
        line = stdout.readline()
        assert line, process.poll()
        return json.loads(line)

    rows, systems = [], {}
    try:
        observation = request(
            {
                "kind": "reset",
                "players": 4,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "evaluation",
            }
        )
        while observation["kind"] == "decision":
            system, user = (message["content"] for message in observation["messages"])
            seat = observation["seat"]
            view = observation["semantic_view"]
            if not original:
                metadata = view.pop("prompt_template")
                assert metadata["bank"] == "hanabi-rules-v2"
                assert metadata["variant"] == (
                    TRAIN[prompt_seed % 5] if wording == "mixed" else wording
                )
                assert (
                    metadata["system_sha256"]
                    == hashlib.sha256(system.encode()).hexdigest()
                )
                assert (
                    metadata["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
                )
            assert all(
                card["colour"] is None and card["rank"] is None
                for card in view["hands"][seat]
            )
            if seat in systems:
                assert systems[seat] == system
            systems[seat] = system
            encoding = request({"kind": "encode"})
            assert len(encoding["values"]) == 284 and len(encoding["actions"]) == 48
            action = json.loads(request({"kind": "teacher"})["response"])
            if language:
                action.update(
                    note=f"Private mémoire {seat} turn {observation['turn']}",
                    banner="Fireworks!",
                )
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(action),
                }
            )
            assert result["kind"] == "accepted" and result["action"] == action
            rows.append((view, user, encoding, result["action"]))
            observation = result["observation"]
        assert observation["kind"] == "terminal" and rows and len(rows) <= 120
        assert len(set(observation["scores"].values())) == 1
        return rows, observation, systems
    finally:
        stdin.close()
        stdout.close()
        assert process.wait(timeout=10) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    count = 0
    for variant in ("standard", "sprint"):
        for language in (False, True):
            for seed in ("wording-1",):
                reference = play(binary, variant, "canonical", seed, language)
                count += 1
                if len(sys.argv) == 3 and not language:
                    assert reference == play(
                        Path(sys.argv[2]).resolve(),
                        variant,
                        "canonical",
                        seed,
                        False,
                        original=True,
                    )
                for wording in WORDINGS[1:]:
                    actual = play(binary, variant, wording, seed, language)
                    assert actual[:2] == reference[:2]
                    assert actual[2] != reference[2]
                    count += 1
                for prompt_seed in (4,):
                    actual = play(binary, variant, "mixed", seed, language, prompt_seed)
                    assert actual[:2] == reference[:2]
                    count += 1
    print(count, "complete games preserve hidden hands, notes, actions and outcomes")
