## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:hanabi-train-bridge tools/train_bridge.nim

import std/[json, os]
import hanabi/[llm, sim]

const OperatorPrompt = "Use public hints and your own card knowledge to build the fireworks safely."
const ActionSlots = HandSize * 2 + Seats * (Colours + 5)

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc visibleHands(game: Sim, seat: int): JsonNode =
  result = newJArray()
  for other in 0 ..< Seats:
    var cards = newJArray()
    for index in 0 ..< game.hands[other].size:
      let held = game.hands[other].cards[index]
      var negColours = newJArray()
      var negRanks = newJArray()
      for colour in 0 ..< Colours:
        negColours.add(%(if uint8(colour) in held.negColours: 1 else: 0))
      for rank in 1 .. 5:
        negRanks.add(%(if uint8(rank) in held.negRanks: 1 else: 0))
      cards.add(%*{
        "colour": (if other == seat: newJNull() else: %held.card.colour),
        "rank": (if other == seat: newJNull() else: %held.card.rank),
        "hint_colour": held.hintColour, "hint_rank": held.hintRank,
        "not_colours": negColours, "not_ranks": negRanks,
        "hinted_turn": held.hintedTurn
      })
    result.add(cards)

proc decision(game: Sim, id: int): JsonNode =
  let seat = game.turn mod Seats
  %*{
    "kind": "decision", "game": "hanabi", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.turn,
    "semantic_view": {
      "seat": seat, "turn": game.turn, "max_turns": game.config.maxTurns,
      "fireworks": game.fireworks, "hint_tokens": game.hintTokens,
      "fuses": game.fuses, "countdown": game.countdown,
      "deck_remaining": game.deck.len, "hands": game.visibleHands(seat),
      "discarded": game.view().discarded
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["action"]},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, id: int): JsonNode =
  let seat = game.turn mod Seats
  var values = newJArray()
  for other in 0 ..< Seats:
    values.add(%(if seat == other: 1 else: 0))
  for value in [game.turn, game.config.maxTurns, game.hintTokens,
      game.fuses, game.countdown, game.deck.len]:
    values.add(%value)
  for height in game.fireworks:
    values.add(%height)
  let view = game.view()
  for colour in 0 ..< Colours:
    for rank in 1 .. 5:
      values.add(%view.discarded[colour][rank])
  for other in 0 ..< Seats:
    values.add(%game.hands[other].size)
    for index in 0 ..< HandSize:
      let held = game.hands[other].cards[index]
      values.add(%(if other == seat or index >= game.hands[other].size:
        -1 else: held.card.colour))
      values.add(%(if other == seat or index >= game.hands[other].size:
        -1 else: held.card.rank))
      values.add(%held.hintColour)
      values.add(%held.hintRank)
      for colour in 0 ..< Colours:
        values.add(%(if uint8(colour) in held.negColours: 1 else: 0))
      for rank in 1 .. 5:
        values.add(%(if uint8(rank) in held.negRanks: 1 else: 0))
      values.add(%held.hintedTurn)
  var actions = newJArray()
  for slot in 1 .. HandSize:
    let move = Move(kind: akPlay, slot: slot, target: -1)
    actions.add(if game.illegalReason(move) == "": moveJson(move)
      else: newJNull())
  for slot in 1 .. HandSize:
    let move = Move(kind: akDiscard, slot: slot, target: -1)
    actions.add(if game.illegalReason(move) == "": moveJson(move)
      else: newJNull())
  for target in 0 ..< Seats:
    for colour in 0 ..< Colours:
      let move = Move(kind: akHint, target: target, hintKind: hkColour,
        value: colour)
      actions.add(if game.illegalReason(move) == "": moveJson(move)
        else: newJNull())
    for rank in 1 .. 5:
      let move = Move(kind: akHint, target: target, hintKind: hkRank,
        value: rank)
      actions.add(if game.illegalReason(move) == "": moveJson(move)
        else: newJNull())
  doAssert actions.len == ActionSlots
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: hanabi-train-bridge MANIFEST [standard|sprint]", 1)
  let variant = if args.len == 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      id = 0
      response = game.decision(id)
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      let teacher = game.scriptedAction(game.turn mod Seats, skConventions)
      response = %*{"response": $moveJson(teacher.move)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let parsed = parseDecision(game, action)
      let seat = game.turn mod Seats
      doAssert game.illegalReason(parsed.move) == ""
      game.applyMove(seat, parsed.move, parsed.note, parsed.banner)
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson()
        var scores = newJObject()
        var utilities = newJObject()
        let utility = 2.0 * outcome["score"].getInt().float / 25.0 - 1.0
        for slot in 0 ..< Seats:
          scores[$slot] = outcome["scores"][slot]
          utilities[$slot] = %utility
        observation = %*{"kind": "terminal", "scores": scores,
          "utilities": utilities}
      else:
        observation = game.decision(id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
