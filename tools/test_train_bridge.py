"""Exercise both certified Hanabi variants without exposing the acting hand."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

for variant in ("standard", "sprint"):
    for seed in ("test-1", "test-2"):
        with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
            observation = bridge.reset(seed, 4)
            decisions = 0
            while not isinstance(observation, Terminal):
                seat = observation.seat
                hands = observation.semantic_view["hands"]
                assert all(
                    card["colour"] is None and card["rank"] is None
                    for card in hands[seat]
                )
                for other in range(4):
                    if other != seat:
                        assert all(card["colour"] is not None for card in hands[other])
                encoding = DecisionEncoding.model_validate_json(
                    bridge.request({"kind": "encode"})
                )
                assert len(encoding.values) == 284
                assert len(encoding.actions) == 48
                for slot in range(4):
                    assert encoding.values[
                        41 + seat * 61 + slot * 15 : 43 + seat * 61 + slot * 15
                    ] == [
                        -1,
                        -1,
                    ]
                action = json.loads(bridge.teacher())
                assert encoding.action_for(encoding.indices_for(action)) == action
                observation = bridge.step(
                    observation.decision_id, json.dumps(action)
                ).observation
                decisions += 1
            assert 1 <= decisions <= (80 if variant == "standard" else 48)
            assert len(set(observation.scores.values())) == 1
            assert len(set(observation.utilities.values())) == 1
            assert -1 <= next(iter(observation.utilities.values())) <= 1
            print(variant, seed, decisions, observation.scores, observation.utilities)
