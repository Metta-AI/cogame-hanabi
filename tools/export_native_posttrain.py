"""Validate native evidence using this game's engine, then return immutable file provenance."""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--replay", type=Path, required=True)
parser.add_argument("--trajectory", type=Path, required=True)
parser.add_argument("--game-log", type=Path, required=True)
parser.add_argument("--episode-id", required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="native-game-verifier-") as temporary:
    binary = Path(temporary) / "verify"
    subprocess.run([
        "nim", "c", "--path:src", "--nimcache:" + temporary + "/cache",
        "--out:" + str(binary), "tools/verify_native_posttrain.nim",
    ], cwd=source, check=True, stdout=subprocess.DEVNULL)
    report = json.loads(subprocess.check_output([
        str(binary), str(args.replay.resolve()), str(args.trajectory.resolve()), args.episode_id,
    ], cwd=source))
report.update(
    protocol="coworld.native-verification.v1",
    replay_sha256=hashlib.sha256(args.replay.read_bytes()).hexdigest(),
    trajectory_sha256=hashlib.sha256(args.trajectory.read_bytes()).hexdigest(),
)
print(json.dumps(report))
