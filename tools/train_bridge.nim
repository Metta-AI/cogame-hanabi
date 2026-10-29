## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:hanabi-train-bridge tools/train_bridge.nim

import std/[json, os]
import hanabi/[llm, sim, training, prompts]

const OperatorPrompt = "Use public hints and your own card knowledge to build the fireworks safely."
var selection: PromptSelection
var languageMode = false

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
  let system = systemPrompt(game, seat, selection)
  let user = userPrompt(game, seat, OperatorPrompt)
  %*{
    "kind": "decision", "game": "hanabi", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.turn,
    "semantic_view": {
      "prompt_template": selection.promptMetadata(system, user),
      "seat": seat, "turn": game.turn, "max_turns": game.config.maxTurns,
      "fireworks": game.fireworks, "hint_tokens": game.hintTokens,
      "fuses": game.fuses, "countdown": game.countdown,
      "deck_remaining": game.deck.len, "hands": game.visibleHands(seat),
      "discarded": game.view().discarded
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["action"]},
    "typed_question": newJNull(),
    "inference_mode": (if languageMode: %"text_action" else: newJNull())
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
  if args.len notin 1 .. 3:
    quit("usage: hanabi-train-bridge MANIFEST [standard|sprint] [--language]", 1)
  let variant = if args.len >= 2: args[1] else: "standard"
  if args.len == 3:
    doAssert args[2] == "--language"
    languageMode = true
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var id = 0
  var auditScenario: JsonNode
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      selection = promptSelection(request)
      if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        doAssert request.hasKey("split") and
          request["split"].getStr() in ["evaluation", "validation", "test"],
          "held-out wording requires an explicit evaluation split"
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      id = 0
      # Private split audit only: never attach hidden state to a decision.
      var cards = newJArray()
      for hand in game.hands:
        for index in 0 ..< hand.size:
          cards.add(%*[hand.cards[index].card.colour, hand.cards[index].card.rank])
      for card in game.deck:
        cards.add(%*[card.colour, card.rank])
      let family = %*{"initial_cards": cards}
      auditScenario = %*{"protocol": "coworld.native-scenario-audit.v1",
        "game": "hanabi", "seed": request["seed"].getStr(),
        "engine_seed": game.config.seed, "family": family}
      response = game.decision(id)
    of "audit_scenario":
      if getEnv("METTA_SCENARIO_AUDIT") != "1":
        response = %*{"kind": "error", "reason": "scenario audit is disabled"}
      elif auditScenario.isNil:
        response = %*{"kind": "error", "reason": "reset is required before scenario audit"}
      else:
        response = auditScenario
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      let explicit = request.hasKey("policy")
      if explicit and request["policy"].kind != JString:
        response = %*{"kind": "error", "reason": "teacher policy must be a string"}
      else:
        let selected = if explicit: request["policy"].getStr() else: "conventions"
        if selected notin ["conventions", "cautious", "reckless"]:
          response = %*{"kind": "error", "reason": "unknown teacher policy"}
        else:
          let teacher = case selected
            of "cautious": game.scriptedAction(game.turn mod Seats, skCautious)
            # legalMoves is the same public list shown to this seat. Its first
            # action plays slot one, without inspecting that card's identity.
            of "reckless": Decision(move: game.legalMoves()[0], origin: "scripted", policy: "scripted-reckless")
            else: game.scriptedAction(game.turn mod Seats, skConventions)
          response = %*{"response": $(if languageMode: teacher.decisionAction() else: moveJson(teacher.move))}
          if explicit:
            response["policy"] = %selected
            response["decision_id"] = %id
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      var action: JsonNode
      var parsed: Decision
      let seat = game.turn mod Seats
      try:
        action = parseJson(request["response"].getStr())
        parsed = parseDecision(game, action)
        let reason = game.illegalReason(parsed.move)
        if reason.len > 0:
          raise newException(HanabiError, reason)
      except CatchableError as error:
        response = %*{"kind": "rejected", "reason": error.msg,
          "observation": game.decision(id)}
        stdout.writeLine($response)
        stdout.flushFile()
        continue
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
      response = %*{"kind": "accepted", "action": (if languageMode: parsed.decisionAction() else: action),
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
