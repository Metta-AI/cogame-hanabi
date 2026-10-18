## Export authoritative private language episodes; numeric bridges stay separate.
import std/[json, os, osproc, strutils]
import bitworld/decision_trajectory
import hanabi/[sim, llm, training, prompts]

const OperatorPrompt = "Use public hints and your own card knowledge to build the fireworks safely."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "standard"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  doAssert selection.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference}, "held-out wording is evaluation only"
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
  var events: seq[string]
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats: runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    let episodeId = "hanabi-" & variant & "-" & $seed & "-" & $selection.selectedVariant
    let trajectory = newDecisionTrajectory(episodeId, "hanabi-" & $seed,
      "hanabi", "source-" & sourceRevision, sourceRevision)
    while not sim.done:
      let before = sim
      let seat = sim.pendingSeats()[0]
      let teacher = sim.scriptedAction(seat, skConventions)
      let parsed = parseDecision(sim, teacher.decisionAction())
      doAssert sameMove(parsed.move, teacher.move) and sim.illegalReason(parsed.move) == ""
      sim.applyMove(seat, parsed.move, parsed.note, parsed.banner, "scripted")
      trajectory.recordAppliedDecision(before, seat, teacher, teacher,
        OperatorPrompt, sim.done, selection)
    doAssert sim.reason == "complete" and sim.turn > 0
    let outcome = sim.resultsJson()
    writePrivate(output / (episodeId & ".replay.json"),
      $sim.replayJson(outcome, @["teacher-0", "teacher-1", "teacher-2", "teacher-3"]))
    outcome["prompt_selection"] = selection.selectionMetadata()
    var participants = newJObject()
    for seat in 0 ..< outcome["scores"].len:
      participants[$seat] = %*{"score": outcome["scores"][seat]}
    trajectory.finish(esCompleted, outcome, participants)
    events.add(trajectory.eventsJsonl().strip())
    runs.add(%*{"episode_id": episodeId, "seed": seed, "decisions": sim.turn,
      "results": outcome, "score": outcome["score"], "end_reason": outcome["endReason"]})
  writePrivate(output / "trajectories.jsonl", events.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{"schema_version": "1",
    "format": "coworld-private-candidates-v1", "game": "hanabi",
    "review_required": true, "prompt_selection": selection.selectionMetadata(),
    "variant": variant, "source_revision": sourceRevision,
    "teacher_policy": "scripted-conventions", "operator_prompt": OperatorPrompt,
    "runs": runs}) & "\n")
  echo "complete episodes=", games
