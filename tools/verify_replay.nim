## Reconstruct a complete saved game through the production rules and event checks.
import std/[json, os]
import hanabi/sim

let replay = parseFile(paramStr(1))
var config = defaultGameConfig()
config.maxTurns = replay["config"]["maxTurns"].getInt()
config.seed = replay["config"]["seed"].getInt()
config.sampled = true
for name in replay["policyNames"]:
  config.players.add(PlayerConfig(name: name.getStr()))
var events: seq[GameEvent]
for node in replay["events"]:
  events.add(eventFromJson(node))
let frames = replayMatch(config, events)
let final = frames[^1]
doAssert final.done and final.reason == "complete"
doAssert final.score() == replay["results"]["score"].getInt()
doAssert final.endReason == replay["results"]["endReason"].getStr()
doAssert events[^1].digest == final.digest()
echo "verified ", final.turn, " turns and final digest"
