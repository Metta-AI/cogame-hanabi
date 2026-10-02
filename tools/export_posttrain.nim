## Export authoritative private language episodes; numeric bridges stay separate.
import std/[json, os, osproc, strutils]
import bitworld/decision_trajectory
import hanabi/[sim, llm, training]

const OperatorPrompt = "Use public hints and your own card knowledge to build the fireworks safely."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "standard"
  doAssert games >= 10 and firstSeed >= 1 and variant in Variants
  doAssert not dirExists(output) and not fileExists(output)
  doAssert execProcess("git status --porcelain").strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats: runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    let episodeId = "hanabi-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "hanabi-" & $seed,
      "hanabi", "source-" & sourceRevision, sourceRevision)
    var selectedDecisionIds: seq[string]
    while not sim.done:
      let before = sim
      selectedDecisionIds.add("hanabi-" & $sim.turn)
      let seat = sim.pendingSeats()[0]
      let teacher = sim.scriptedAction(seat, skConventions)
      let parsed = parseDecision(sim, teacher.decisionAction())
      doAssert sameMove(parsed.move, teacher.move) and sim.illegalReason(parsed.move) == ""
      sim.applyMove(seat, parsed.move, parsed.note, parsed.banner, "scripted")
      trajectory.recordAppliedDecision(before, seat, teacher, teacher,
        OperatorPrompt, sim.done)
    doAssert sim.reason == "complete" and sim.turn > 0
    let outcome = sim.resultsJson()
    var participants = newJObject()
    for seat in 0 ..< outcome["scores"].len:
      participants[$seat] = %*{"score": outcome["scores"][seat]}
    trajectory.finish(esCompleted, outcome, participants)
    let split = if seed mod 5 == 0: "validation" else: "train"
    trajectory.writeCompleteEpisode(output / split / (episodeId & ".jsonl"))
    runs.add(%*{"episode_id": episodeId, "seed": seed, "split": split, "decisions": sim.turn,
      "selected_decision_ids": selectedDecisionIds, "results": outcome, "score": outcome["score"], "end_reason": outcome["endReason"]})
  writeFile(output / "manifest.json", pretty(%*{"schema_version": "1",
    "format": "coworld-private-complete-episodes-v1", "game": "hanabi",
    "variant": variant, "source_revision": sourceRevision,
    "teacher_policy": "scripted-conventions", "operator_prompt": OperatorPrompt,
    "runs": runs}) & "\n")
  echo "complete episodes=", games
