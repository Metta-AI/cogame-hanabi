## The rules. Everything in here is a hand-built position or a seeded
## episode; nothing touches the network, the clock or the file system.

import std/[json, sets, tables, unittest]
import hanabi/[llm, sim]

proc fixtureConfig(maxTurns = 80, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.maxTurns = maxTurns
  result.seed = seed
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc handOf(sim: Sim, seat: int): seq[Card] =
  for slot in 1 .. sim.hands[seat].size:
    result.add(sim.hands[seat].cards[slot - 1].card)

proc put(sim: var Sim, seat: int, cards: openArray[Card]) =
  ## Replaces a whole hand with a hand-built one, knowledge cleared.
  sim.hands[seat].size = cards.len
  for index in 0 ..< HandSize:
    sim.hands[seat].cards[index] = HeldCard(card: Card(colour: 0, rank: 0),
      hintColour: -1, hintRank: 0, hintedTurn: -1)
  for index, card in cards:
    sim.hands[seat].cards[index].card = card

proc card(colour, rank: int): Card = Card(colour: colour, rank: rank)

## Colour indexes, in deck order.
const Red = 0
const Yellow = 1
const Green = 2
const Blue = 3
const White = 4

suite "the deck and the deal":
  test "the deck is the standard 50 cards":
    let deck = buildDeck(11)
    check deck.len == DeckSize
    var counts = initCountTable[(int, int)]()
    for card in deck:
      counts.inc((card.colour, card.rank))
    for colour in 0 ..< Colours:
      for rank in 1 .. 5:
        check counts[(colour, rank)] == RankCounts[rank - 1]
    check RankCounts == [3, 2, 2, 2, 1]

  test "the shuffle is seeded, reproducible and seed-sensitive":
    check buildDeck(7) == buildDeck(7)
    check buildDeck(7) != buildDeck(8)

  test "the deal gives four seats four cards, newest at slot 1, 34 left":
    let sim = initSim(fixtureConfig(seed = 3))
    check sim.deck.len == DeckSize - Seats * HandSize
    check sim.deck.len == 34
    let deck = buildDeck(3)
    for seat in 0 ..< Seats:
      check sim.hands[seat].size == HandSize
      ## Round r deals deck[r * 4 + seat] to `seat`, and each new card
      ## enters slot 1, so the LAST round dealt is slot 1.
      for round in 0 ..< HandSize:
        let slot = HandSize - round
        check sim.hands[seat].cards[slot - 1].card ==
          deck[round * Seats + seat]
    check sim.turn == 0
    check sim.hintTokens == MaxHintTokens
    check sim.fuses == MaxFuses
    check sim.countdown == -1
    check sim.events.len == 1
    check sim.events[0].kind == evStart
    check sim.events[0].seats == Seats
    check sim.events[0].handSize == HandSize
    check sim.pendingSeats() == @[0]

  test "a draw enters slot 1 and shifts the rest one slot higher":
    var sim = initSim(fixtureConfig(seed = 5))
    let before = sim.handOf(0)
    let top = sim.deck[0]
    sim.applyMove(0, Move(kind: akPlay, slot: 2, target: -1))
    let after = sim.handOf(0)
    check after.len == HandSize
    check after[0] == top
    check after[1] == before[0]
    check after[2] == before[2]
    check after[3] == before[3]
    check sim.deck.len == 33

  test "with an empty deck the hand shrinks and the slots renumber":
    var sim = initSim(fixtureConfig(seed = 5))
    let before = sim.handOf(0)
    sim.deck = @[]
    sim.applyMove(0, Move(kind: akPlay, slot: 2, target: -1))
    let after = sim.handOf(0)
    check after.len == HandSize - 1
    check after[0] == before[0]
    check after[1] == before[2]
    check after[2] == before[3]

suite "the three actions":
  test "a play advances a stack only on fireworks + 1":
    var sim = initSim(fixtureConfig(seed = 5))
    sim.put(0, [card(Red, 1), card(Red, 3), card(Green, 1), card(Blue, 4)])
    sim.deck = @[card(White, 1)]
    sim.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check sim.fireworks[Red] == 1
    check sim.fuses == MaxFuses
    check sim.lastMove.outcome == "stack"
    check sim.discards.len == 0
    ## Slot 1 is the drawn white 1; the red 3 is now slot 2.
    check sim.hands[0].cards[0].card == card(White, 1)
    check sim.hands[0].cards[1].card == card(Red, 3)

  test "a misplay burns a fuse and discards the card":
    var sim = initSim(fixtureConfig(seed = 5))
    sim.put(0, [card(Red, 3), card(Red, 1), card(Green, 1), card(Blue, 4)])
    sim.deck = @[card(White, 1)]
    sim.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check sim.fireworks[Red] == 0
    check sim.fuses == MaxFuses - 1
    check sim.lastMove.outcome == "misplay"
    check sim.lastMove.fizzle
    check sim.discards == @[card(Red, 3)]

  test "a completed firework refunds a hint token only below 8":
    var sim = initSim(fixtureConfig(seed = 5))
    sim.fireworks[Green] = 4
    sim.hintTokens = 5
    sim.put(0, [card(Green, 5), card(Red, 1), card(Green, 1), card(Blue, 4)])
    sim.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check sim.fireworks[Green] == 5
    check sim.hintTokens == 6
    var full = initSim(fixtureConfig(seed = 5))
    full.fireworks[Blue] = 4
    full.hintTokens = MaxHintTokens
    full.put(0, [card(Blue, 5), card(Red, 1), card(Green, 1), card(Blue, 4)])
    full.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check full.fireworks[Blue] == 5
    check full.hintTokens == MaxHintTokens

  test "a discard refunds a token and is illegal at 8":
    var sim = initSim(fixtureConfig(seed = 5))
    check sim.hintTokens == MaxHintTokens
    check sim.illegalReason(Move(kind: akDiscard, slot: 1, target: -1)).len > 0
    expect HanabiError:
      sim.applyMove(0, Move(kind: akDiscard, slot: 1, target: -1))
    for move in sim.legalMoves():
      check move.kind != akDiscard
    sim.hintTokens = 6
    let discarded = sim.hands[0].cards[2].card
    sim.applyMove(0, Move(kind: akDiscard, slot: 3, target: -1))
    check sim.hintTokens == 7
    check sim.discards == @[discarded]

  test "a hint costs a token and must touch something, never yourself":
    var sim = initSim(fixtureConfig(seed = 5))
    sim.put(0, [card(Red, 1), card(Red, 2), card(Green, 1), card(Blue, 4)])
    sim.put(1, [card(Red, 1), card(White, 2), card(Red, 3), card(Blue, 4)])
    check sim.illegalReason(Move(kind: akHint, target: 0, hintKind: hkRank,
      value: 1)).len > 0                       ## yourself
    check sim.illegalReason(Move(kind: akHint, target: 1, hintKind: hkColour,
      value: Green)).len > 0                   ## touches nothing
    check sim.illegalReason(Move(kind: akHint, target: 1, hintKind: hkColour,
      value: Red)).len == 0
    sim.applyMove(0, Move(kind: akHint, target: 1, hintKind: hkColour,
      value: Red))
    check sim.hintTokens == MaxHintTokens - 1
    check sim.lastMove.touched == @[1, 3]
    check sim.lastMove.untouched == @[2, 4]
    ## Every matching card is marked; every other card records the negative.
    check sim.hands[1].cards[0].hintColour == Red
    check sim.hands[1].cards[2].hintColour == Red
    check uint8(Red) in sim.hands[1].cards[1].negColours
    check uint8(Red) in sim.hands[1].cards[3].negColours
    check sim.hands[1].cards[0].hintedTurn == 0
    sim.hintTokens = 0
    check sim.illegalReason(Move(kind: akHint, target: 2, hintKind: hkRank,
      value: 4)).len > 0
    for move in sim.legalMoves():
      check move.kind != akHint

suite "knowledge":
  test "counting removes an identity every copy of which is visible":
    var sim = initSim(fixtureConfig(seed = 5))
    ## Seat 0 has a rank-1 hint on slot 1; the three red 1s are all in other
    ## hands, so red is impossible for it even though nothing said so.
    sim.put(0, [card(Yellow, 1), card(Green, 4), card(Blue, 4),
      card(White, 4)])
    sim.put(1, [card(Red, 1), card(Red, 1), card(Red, 1), card(White, 5)])
    sim.put(2, [card(Green, 2), card(Green, 3), card(Blue, 2), card(Blue, 3)])
    sim.put(3, [card(White, 2), card(White, 3), card(Yellow, 2),
      card(Yellow, 3)])
    discard markHint(sim.hands[0], hkRank, 1, 0)
    let cards = sim.candidates(0, 1)
    check cards.len > 0
    for candidate in cards:
      check candidate.rank == 1
      check candidate.colour != Red
    check sim.knownPlayable(0, 1)          ## every 1 is playable at 0/0/0/0/0

  test "knownDead, knownPlayable and the chop agree with hand-built spots":
    var sim = initSim(fixtureConfig(seed = 5))
    sim.fireworks = [3, 0, 0, 0, 0]
    sim.put(0, [card(Red, 1), card(Red, 5), card(Green, 1), card(Blue, 4)])
    discard markHint(sim.hands[0], hkColour, Red, 0)
    ## Slots 1 and 2 are known red; the red 1 and 2 are behind the stack.
    check sim.knownDead(0, 1) == false       ## red 4 or 5 are still alive
    sim.discards.add(card(Red, 4))
    sim.discards.add(card(Red, 4))
    ## Both red 4s are gone: red can never pass 3, so every red left is dead.
    check sim.knownDead(0, 1)
    check sim.knownDead(0, 2)
    ## Chop: the highest slot with no positive hint - slot 4 here.
    check sim.chopSlot(0) == 4
    ## Once every slot carries a hint, the chop is the highest known-dead one.
    discard markHint(sim.hands[0], hkRank, 1, 0)
    discard markHint(sim.hands[0], hkRank, 4, 0)
    check sim.chopSlot(0) == 2

  test "a known-playable card is one whose every candidate plays now":
    var sim = initSim(fixtureConfig(seed = 5))
    sim.fireworks = [1, 1, 1, 1, 1]
    sim.put(0, [card(Red, 2), card(Green, 4), card(Blue, 4), card(White, 4)])
    discard markHint(sim.hands[0], hkRank, 2, 0)
    check sim.knownPlayable(0, 1)
    check sim.knownDead(0, 1) == false
    check sim.knownCritical(0, 1) == false

suite "the countdown and the endings":
  test "the countdown arms at deck-out and ends the game four turns later":
    var sim = initSim(fixtureConfig(seed = 9))
    sim.deck = @[card(White, 5)]
    sim.hintTokens = 6
    ## Seat 0 draws the last card: the countdown arms on its own turn.
    sim.applyMove(0, Move(kind: akDiscard, slot: 4, target: -1))
    check sim.deck.len == 0
    check sim.countdown == Seats
    var turns = 0
    while not sim.done:
      let seat = sim.pendingSeats()[0]
      let decision = scriptedAction(sim, seat, skConventions)
      sim.applyMove(seat, decision.move, "", "", "scripted")
      turns += 1
    check turns == Seats
    check sim.endReason == "deckout"
    check sim.reason == "complete"

  test "strikeout, perfect, turnlimit and deadline each fire":
    var strike = initSim(fixtureConfig(seed = 9))
    strike.fuses = 1
    strike.put(0, [card(Red, 5), card(Red, 1), card(Green, 1), card(Blue, 4)])
    strike.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check strike.done
    check strike.endReason == "strikeout"
    check strike.reason == "complete"
    check strike.score() == 0

    var perfect = initSim(fixtureConfig(seed = 9))
    perfect.fireworks = [5, 5, 5, 5, 4]
    perfect.put(0, [card(White, 5), card(Red, 1), card(Green, 1),
      card(Blue, 4)])
    perfect.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check perfect.done
    check perfect.endReason == "perfect"
    check perfect.score() == 25

    var limit = initSim(fixtureConfig(maxTurns = MinTurns, seed = 9))
    while not limit.done:
      let seat = limit.pendingSeats()[0]
      let decision = scriptedAction(limit, seat, skConventions)
      limit.applyMove(seat, decision.move, "", "", "scripted")
    check limit.turn == MinTurns
    check limit.endReason == "turnlimit"
    check limit.reason == "complete"

    var early = initSim(fixtureConfig(seed = 9))
    early.fireworks = [2, 0, 1, 0, 0]
    early.endEarly()
    check early.done
    check early.reason == "deadline"
    check early.endReason == "deadline"
    check early.score() == 3
    check early.pendingSeats().len == 0
    check early.resultsJson()["reason"].getStr() == "deadline"

  test "a strikeout beats a perfect score in the end-test order":
    ## Both conditions true at once: the fuse test runs first.
    var sim = initSim(fixtureConfig(seed = 9))
    sim.fuses = 1
    sim.fireworks = [5, 5, 5, 5, 5]
    sim.put(0, [card(Red, 5), card(Red, 1), card(Green, 1), card(Blue, 4)])
    sim.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check sim.endReason == "strikeout"

suite "scoring":
  test "the score is the sum of the stacks and every seat gets it":
    var sim = initSim(fixtureConfig(seed = 9))
    sim.fireworks = [3, 2, 0, 5, 1]
    check sim.score() == 11
    sim.endEarly()
    let results = sim.resultsJson()
    check results["score"].getInt() == 11
    check results["scores"].len == Seats
    for seat in 0 ..< Seats:
      check results["scores"][seat].getInt() == 11
    check results["fireworks"].len == Colours
    check results["endReason"].getStr() == "deadline"

  test "contributions are display only and never the score":
    var sim = initSim(fixtureConfig(seed = 9))
    sim.put(0, [card(Red, 1), card(Red, 2), card(Green, 1), card(Blue, 4)])
    sim.applyMove(0, Move(kind: akPlay, slot: 1, target: -1))
    check sim.contribution(0) == 1
    let results = sim.resultsJson()
    check results["contributions"][0].getInt() == 1
    check results["scores"][0].getInt() == sim.score()

suite "legality is one rule":
  test "legalMoves matches a brute-force predicate and is never empty":
    ## An INDEPENDENT legality predicate, written from the rules table, over
    ## 200 seeded scripted episodes: the enumerated list must be exactly the
    ## set of moves this predicate accepts, at every state.
    proc bruteForce(sim: Sim): HashSet[string] =
      let seat = sim.turn mod Seats
      let size = sim.hands[seat].size
      for slot in 1 .. HandSize:
        if slot <= size:
          result.incl("play " & $slot)
          if sim.hintTokens <= MaxHintTokens - 1:
            result.incl("discard " & $slot)
      if sim.hintTokens >= 1:
        for target in 0 ..< Seats:
          if target == seat:
            continue
          for slot in 1 .. sim.hands[target].size:
            let held = sim.hands[target].cards[slot - 1].card
            result.incl("hint " & $target & " " & ColourNames[held.colour])
            result.incl("hint " & $target & " " & $held.rank)

    for seed in 1 .. 200:
      var sim = initSim(fixtureConfig(seed = seed))
      while not sim.done:
        let moves = sim.legalMoves()
        check moves.len > 0
        var printed: HashSet[string]
        for move in moves:
          printed.incl(moveText(move))
          check sim.illegalReason(move).len == 0
        check printed == bruteForce(sim)
        let seat = sim.pendingSeats()[0]
        let kind = if seat mod 2 == 0: skConventions else: skCautious
        let decision = scriptedAction(sim, seat, kind)
        sim.applyMove(seat, decision.move, "", "", "scripted")
      check sim.done
      check sim.reason == "complete"

suite "determinism":
  test "the same config twice gives the same digest":
    for seed in [1, 7, 42]:
      var a = initSim(fixtureConfig(seed = seed))
      var b = initSim(fixtureConfig(seed = seed))
      check a.digest() == b.digest()
      while not a.done:
        let seat = a.pendingSeats()[0]
        a.applyMove(seat, scriptedAction(a, seat, skConventions).move,
          "", "", "scripted")
        b.applyMove(seat, scriptedAction(b, seat, skConventions).move,
          "", "", "scripted")
      check a.digest() == b.digest()
    check initSim(fixtureConfig(seed = 1)).digest() !=
      initSim(fixtureConfig(seed = 2)).digest()

  test "sampleEpisode clamps once and is idempotent":
    var config = defaultGameConfig()
    config.maxTurns = 500
    config.turnDelayMs = 5000
    let once = sampleEpisode(config)
    check once.maxTurns == MaxTurnsCap
    check once.turnDelayMs <= PacingBudgetMs div once.maxTurns
    check once.sampled
    check sampleEpisode(once) == once
    var small = defaultGameConfig()
    small.maxTurns = 2
    check sampleEpisode(small).maxTurns == MinTurns
