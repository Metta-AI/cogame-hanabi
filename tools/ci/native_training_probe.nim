## Actual native batched client, parser normalization, and authoritative apply.
import std/[json, options, os]
import bitworld/decision_trajectory
import hanabi/[llm, sim, training]

putEnv("COWORLD_LLM_ENDPOINT", paramStr(1))
putEnv("COWORLD_LLM_MODEL", "checkpoint/native-fixture")
putEnv("COWORLD_LLM_TEMPERATURE", "0")
var config = defaultGameConfig()
config.sampled = true
config.players = @[PlayerConfig(name: "a"), PlayerConfig(name: "b"),
  PlayerConfig(name: "c"), PlayerConfig(name: "d")]
config.tokens = @["a", "b", "c", "d"]
var game = initSim(config)
let before = game
let prompts = @["Exact private operator prompt", "", "", ""]
let scripts = @[skNone, skNone, skNone, skNone]
let decision = newLlmClient(config).decideAll(game, @[0], prompts, scripts)[0]
doAssert decision.nativeAttempts.len == 2
doAssert not decision.nativeAttempts[0].accepted
if paramStr(2) == "retry":
  doAssert decision.origin == "retry"
  doAssert decision.nativeAttempts[1].accepted
  doAssert sameMove(decision.move, Move(kind: akPlay, slot: 1, target: -1))
else:
  doAssert decision.origin == "fallback"
  doAssert not decision.nativeAttempts[1].accepted
for attempt in decision.nativeAttempts:
  doAssert attempt.platformCallId.isSome
  doAssert attempt.rawResponse.kind == JObject
  doAssert attempt.request["temperature"].getFloat() == 0
  doAssert attempt.latencyMs.isSome
  doAssert attempt.inputTokens.get() == 3
  doAssert attempt.outputTokens.get() == 2
game.applyMove(0, decision.move, decision.note, decision.banner, decision.origin)
let trajectory = newDecisionTrajectory("probe", "probe", "hanabi", "fixture", "fixture-source")
trajectory.recordAppliedDecision(before, 0, decision, decision, prompts[0], game.done)
trajectory.finish(esTruncated, game.resultsJson(), %*{})
echo trajectory.eventsJsonl()
