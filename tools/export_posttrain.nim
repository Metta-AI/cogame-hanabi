## Export complete Hanabi games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import hanabi/[sim, llm]

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
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let seat = sim.pendingSeats()[0]
      let teacher = sim.scriptedAction(seat, skConventions)
      var completion = moveJson(teacher.move)
      completion["note"] = %teacher.note
      completion["banner"] = %teacher.banner
      let parsed = parseDecision(sim, completion)
      doAssert sameMove(parsed.move, teacher.move)
      doAssert sim.illegalReason(parsed.move) == ""
      rows.add($(%*{
        "episode_id": "hanabi-" & variant & "-" & $seed,
        "seed": "hanabi-" & variant & "-" & $seed,
        "decision_id": sim.turn,
        "prompt": [
          {"role": "system", "content": systemPrompt(sim, seat)},
          {"role": "user", "content": userPrompt(sim, seat,
            OperatorPrompt)}
        ],
        "completion": [{"role": "assistant", "content": $completion}],
        "game": "hanabi",
        "action_schema_revision": "hanabi-move-v1"
      }))
      sim.applyMove(seat, parsed.move, parsed.note, parsed.banner, "scripted")
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": outcome["score"], "end_reason": outcome["endReason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "hanabi",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-conventions",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
