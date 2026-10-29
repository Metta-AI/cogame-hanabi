"""Complete native games with explicit seat-visible teachers; no model learning."""

import json
import sys
from pathlib import Path

from metta_training.game import Terminal
from metta_training.session import GameBridge

binary = Path(sys.argv[1]).resolve()
manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
policies = ("conventions", "cautious", "reckless")
for seed in (
    "hanabi-sustained-20261027-29",
    "hanabi-sustained-20261027-15",
    "teacher-profiles-system",
):
    for policy in policies:
        with GameBridge(
            [str(binary), str(manifest), "standard", "--language"]
        ) as bridge:
            observation = bridge.reset(seed, 4)
            decisions = 0
            while not isinstance(observation, Terminal):
                default = json.loads(bridge.request({"kind": "teacher"}))
                assert set(default) == {"response"}
                selected = json.loads(
                    bridge.request({"kind": "teacher", "policy": "conventions"})
                )
                assert selected == {
                    "response": default["response"],
                    "policy": "conventions",
                    "decision_id": observation.decision_id,
                }
                for invalid in ("invalid", "", None, True, 4):
                    reply = json.loads(
                        bridge.request({"kind": "teacher", "policy": invalid})
                    )
                    assert reply["kind"] == "error"
                    assert json.loads(bridge.request({"kind": "teacher"})) == default
                reply = json.loads(
                    bridge.request({"kind": "teacher", "policy": policy})
                )
                assert set(reply) == {"response", "policy", "decision_id"}
                assert (
                    reply["policy"] == policy
                    and reply["decision_id"] == observation.decision_id
                )
                if policy == "reckless":
                    assert json.loads(reply["response"])["action"] == "play"
                action = (
                    reply["response"] if observation.seat == 0 else default["response"]
                )
                result = bridge.step(observation.decision_id, action)
                assert result.kind == "accepted"
                observation = result.observation
                decisions += 1
            assert 0 < decisions <= 200
            print(
                json.dumps(
                    {
                        "seed": seed,
                        "policy": policy,
                        "accepted": decisions,
                        "scores": observation.scores,
                    }
                )
            )
