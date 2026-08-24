## Pure game rules for Hanabi. No IO, no networking, no LLM — the server,
## the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded 50-card deck, four hands of four
## cards nobody may look at, the five fireworks, the discard pile, the hint
## and fuse tokens, each seat's private notes and the append-only event log.
## Everything random is drawn from the seed at `initSim`, so a replay
## re-derives the episode from the recorded move events alone.
##
## The knowledge model (what a seat can prove about its own cards) lives on
## a small value-type `View` rather than on the whole `Sim`: the hint
## annotation and the scripted baselines probe hypothetical states dozens of
## times a turn, and copying the event log to do it would be absurd.

import std/[json, random, strutils, unicode], types

export types

const
  Seats* = 4
  HandSize* = 4
  Colours* = 5
  DeckSize* = 50
  ColourNames* = ["red", "yellow", "green", "blue", "white"]
  ColourLetters* = ["R", "Y", "G", "B", "W"]
  RankCounts* = [3, 2, 2, 2, 1]     ## copies of rank 1..5 per colour
  MaxHintTokens* = 8
  MaxFuses* = 3
  MinTurns* = 20
  MaxTurnsCap* = 120
  MaxNoteLen* = 400
  MaxBannerLen* = 80
  MaxLearnedLines* = 6
  MaxLearnedLen* = 90
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 20_000
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  Phase* = enum
    phTurn = "turn"     ## a seat owes a move
    phDone = "done"

  HeldCard* = object
    card*: Card
    hintColour*: int          ## -1 = no positive colour hint
    hintRank*: int            ## 0 = no positive rank hint
    negColours*: set[uint8]   ## colours a hint proved this card is NOT
    negRanks*: set[uint8]
    hintedTurn*: int          ## the last turn a hint touched it; -1 if never

  Hand* = object
    cards*: array[HandSize, HeldCard]  ## index 0 = slot 1 = the newest card
    size*: int

  CopyCounts* = array[Colours, array[6, int]]

  View* = object
    ## Everything the knowledge model needs, and nothing that costs anything
    ## to copy: the stacks, the discard pile as counts, the four hands.
    fireworks*: array[Colours, int]
    discarded*: CopyCounts
    hands*: array[Seats, Hand]

  Annotation* = object
    ## What the receiver of a hint can now infer — computed BEFORE the hint
    ## mutates anything, recorded on the event, re-derived by the viewer.
    touched*, untouched*: seq[int]
    learned*: seq[string]
    nowPlayable*, nowDead*, nowCritical*: seq[int]

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous cog aliases per seat
    deck*: seq[Card]               ## index 0 = next to draw
    hands*: array[Seats, Hand]
    fireworks*: array[Colours, int]
    discards*: seq[Card]
    hintTokens*, fuses*: int
    turn*, actor*, countdown*: int ## countdown -1 until the deck empties
    notes*: array[Seats, string]
    banners*: array[Seats, string]
    stat*: array[Seats, SeatStat]
    lastMove*: GameEvent           ## the move this state was produced by
    phase*: Phase
    done*: bool
    reason*: string                ## "complete" | "deadline"
    endReason*: string             ## perfect|strikeout|deckout|turnlimit|deadline
    events*: seq[GameEvent]

# ---- Small helpers ----------------------------------------------------------

proc blankHeld(): HeldCard =
  HeldCard(card: Card(colour: 0, rank: 0), hintColour: -1, hintRank: 0,
    hintedTurn: -1)

proc blankEvent*(kind: EventKind): GameEvent =
  GameEvent(kind: kind, turn: -1, seat: -1, slot: 0, target: -1,
    countdown: -1, card: Card(colour: 0, rank: 0))

proc colourIndex*(name: string): int =
  ## The deck-order index of a colour name, or -1.
  let want = name.strip().toLowerAscii()
  for index, colour in ColourNames:
    if colour == want:
      return index
  -1

proc cardName*(card: Card): string =
  if card.rank <= 0:
    return "(none)"
  ColourNames[card.colour] & " " & $card.rank

proc capLine*(text: string, limit: int): string =
  ## Cut on a RUNE boundary: a byte slice through a multi-byte character
  ## leaves invalid UTF-8 in the replay and breaks a strict JSON parser.
  result = text.strip()
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit - 1) & "…"

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the turn cap into the episode's limits. Idempotent: a config that
  ## already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.maxTurns = max(min(config.maxTurns, MaxTurnsCap), MinTurns)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.maxTurns, 1))
  result.sampled = true

proc buildDeck*(seed: int): seq[Card] =
  ## The standard 50: five colours in deck order, ranks 1..5 with the
  ## 3/2/2/2/1 multiset, shuffled by the single seed-derived stream.
  for colour in 0 ..< Colours:
    for rank in 1 .. 5:
      for duplicate in 0 ..< RankCounts[rank - 1]:
        result.add(Card(colour: colour, rank: rank))
  var rng = initRand(int64(seed) * 7919 + 17)
  rng.shuffle(result)

proc drawInto(sim: var Sim, seat: int) =
  ## Pops the deck's top card into slot 1, shifting the rest one slot higher.
  if sim.deck.len == 0 or sim.hands[seat].size >= HandSize:
    return
  let card = sim.deck[0]
  sim.deck.delete(0)
  var hand = sim.hands[seat]
  for index in countdown(hand.size, 1):
    hand.cards[index] = hand.cards[index - 1]
  hand.cards[0] = blankHeld()
  hand.cards[0].card = card
  hand.size += 1
  sim.hands[seat] = hand

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(HanabiError,
      "hanabi needs exactly " & $Seats & " players")
  if config.maxTurns < 4:
    raise newException(HanabiError, "maxTurns must be at least 4")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  result.deck = buildDeck(config.seed)
  for seat in 0 ..< Seats:
    for index in 0 ..< HandSize:
      result.hands[seat].cards[index] = blankHeld()
  result.hintTokens = MaxHintTokens
  result.fuses = MaxFuses
  result.countdown = -1
  result.turn = 0
  result.actor = 0
  result.phase = phTurn
  result.lastMove = blankEvent(evStart)
  ## Four rounds, seats 0..3, one card each; slot 1 is always the newest.
  for pass in 0 ..< HandSize:
    for seat in 0 ..< Seats:
      result.drawInto(seat)
  var start = blankEvent(evStart)
  start.text = "hanabi"
  start.seed = config.seed
  start.seats = Seats
  start.handSize = HandSize
  start.maxTurns = config.maxTurns
  result.addEvent(start)

# ---- The knowledge model (on a cheap value type) ----------------------------

proc view*(sim: Sim): View =
  result.fireworks = sim.fireworks
  result.hands = sim.hands
  for card in sim.discards:
    result.discarded[card.colour][card.rank] += 1

proc isPlayable*(view: View, colour, rank: int): bool =
  rank >= 1 and rank <= 5 and view.fireworks[colour] + 1 == rank

proc isDeadIdent*(view: View, colour, rank: int): bool =
  ## Already played, or unreachable because every copy of some lower rank
  ## the stack still needs is in the discard pile.
  if view.fireworks[colour] >= rank:
    return true
  for below in view.fireworks[colour] + 1 ..< rank:
    if view.discarded[colour][below] >= RankCounts[below - 1]:
      return true
  false

proc tableCopies*(view: View, colour, rank: int): int =
  ## Copies still somewhere in play — in a hand or in the deck.
  result = RankCounts[rank - 1] - view.discarded[colour][rank]
  if view.fireworks[colour] >= rank:
    result -= 1
  if result < 0:
    result = 0

proc isCriticalIdent*(view: View, colour, rank: int): bool =
  ## The last copy of a card that can still be played.
  (not view.isDeadIdent(colour, rank)) and view.tableCopies(colour, rank) == 1

iterator hintOptions*(view: View, seat, slot: int): Card =
  ## Everything the hints alone (positive and negative) leave open. No card
  ## counting — this is the input to the counting pass, not its output. An
  ## iterator, not a seq: the annotation and the baselines walk this dozens
  ## of times a turn and an allocation each time is the whole cost.
  let held = view.hands[seat].cards[slot - 1]
  for colour in 0 ..< Colours:
    if (held.hintColour < 0 or colour == held.hintColour) and
        uint8(colour) notin held.negColours:
      for rank in 1 .. 5:
        if (held.hintRank == 0 or rank == held.hintRank) and
            uint8(rank) notin held.negRanks:
          yield Card(colour: colour, rank: rank)

proc hintCandidates*(view: View, seat, slot: int): seq[Card] =
  for card in view.hintOptions(seat, slot):
    result.add(card)

type Basis* = object
  ## Copies of every card the holder can see or prove, once, so the
  ## candidate pass is a lookup rather than a rescan.
  seen*: CopyCounts
  singles*: array[HandSize, Card]   ## own slots already pinned by hints alone

proc basisFor*(view: View, holder: int): Basis =
  for colour in 0 ..< Colours:
    for rank in 1 .. 5:
      var seen = view.discarded[colour][rank]
      if view.fireworks[colour] >= rank:
        seen += 1
      result.seen[colour][rank] = seen
  for other in 0 ..< Seats:
    if other == holder:
      continue
    for slot in 1 .. view.hands[other].size:
      let card = view.hands[other].cards[slot - 1].card
      if card.rank >= 1:
        result.seen[card.colour][card.rank] += 1
  for slot in 1 .. view.hands[holder].size:
    var only = Card(colour: 0, rank: 0)
    var count = 0
    for card in view.hintOptions(holder, slot):
      only = card
      count += 1
      if count > 1:
        break
    if count == 1:
      result.singles[slot - 1] = only
      result.seen[only.colour][only.rank] += 1

proc remainingCopies*(view: View, holder, colour, rank, exceptSlot: int): int =
  ## Copies of (colour, rank) the holder cannot see: total, minus the
  ## fireworks, minus the discard pile, minus the other seats' hands, minus
  ## its own cards that are already a singleton BY HINTS ALONE. One pass, no
  ## fixpoint — the inference boundary is deliberate (see docs/plans).
  let basis = view.basisFor(holder)
  result = RankCounts[rank - 1] - basis.seen[colour][rank]
  if exceptSlot >= 1 and exceptSlot <= HandSize and
      basis.singles[exceptSlot - 1].rank == rank and
      basis.singles[exceptSlot - 1].colour == colour:
    result += 1
  if result < 0:
    result = 0

iterator candidateOptions*(view: View, basis: Basis, seat, slot: int): Card =
  ## The hint-consistent options that card counting has not ruled out.
  let own = basis.singles[slot - 1]
  for card in view.hintOptions(seat, slot):
    var left = RankCounts[card.rank - 1] - basis.seen[card.colour][card.rank]
    if own.rank == card.rank and own.colour == card.colour:
      left += 1                     ## this very card is not evidence of itself
    if left > 0:
      yield card

proc candidatesWith*(view: View, basis: Basis, seat, slot: int): seq[Card] =
  for card in view.candidateOptions(basis, seat, slot):
    result.add(card)

proc candidates*(view: View, seat, slot: int): seq[Card] =
  view.candidatesWith(view.basisFor(seat), seat, slot)

type SlotFacts* = object
  ## The three predicates in ONE pass over the candidate set.
  count*: int
  playable*, dead*, critical*: bool

proc slotFacts*(view: View, basis: Basis, seat, slot: int): SlotFacts =
  var only = Card(colour: 0, rank: 0)
  result.playable = true
  result.dead = true
  for card in view.candidateOptions(basis, seat, slot):
    result.count += 1
    only = card
    if not view.isPlayable(card.colour, card.rank):
      result.playable = false
    if not view.isDeadIdent(card.colour, card.rank):
      result.dead = false
  if result.count == 0:
    result.playable = false
    result.dead = false
  elif result.count == 1:
    result.critical = view.isCriticalIdent(only.colour, only.rank)

proc knownPlayableWith*(view: View, basis: Basis, seat, slot: int): bool =
  view.slotFacts(basis, seat, slot).playable

proc knownDeadWith*(view: View, basis: Basis, seat, slot: int): bool =
  view.slotFacts(basis, seat, slot).dead

proc knownCriticalWith*(view: View, basis: Basis, seat, slot: int): bool =
  view.slotFacts(basis, seat, slot).critical

proc knownPlayable*(view: View, seat, slot: int): bool =
  view.knownPlayableWith(view.basisFor(seat), seat, slot)

proc knownDead*(view: View, seat, slot: int): bool =
  view.knownDeadWith(view.basisFor(seat), seat, slot)

proc knownCritical*(view: View, seat, slot: int): bool =
  ## The holder can prove the identity AND that it is the last copy.
  view.knownCriticalWith(view.basisFor(seat), seat, slot)

proc chopSlot*(view: View, seat: int): int =
  ## The highest-numbered slot carrying no positive hint; failing that the
  ## highest-numbered known-dead slot; failing that the oldest card. A
  ## derived quantity, not a rule — nothing forces a seat to discard it.
  let size = view.hands[seat].size
  if size == 0:
    return 0
  for slot in countdown(size, 1):
    let held = view.hands[seat].cards[slot - 1]
    if held.hintColour < 0 and held.hintRank == 0:
      return slot
  let basis = view.basisFor(seat)
  for slot in countdown(size, 1):
    if view.knownDeadWith(basis, seat, slot):
      return slot
  size

proc hintTouches*(view: View, target: int, kind: HintKind, value: int):
    seq[int] =
  for slot in 1 .. view.hands[target].size:
    let card = view.hands[target].cards[slot - 1].card
    let matches =
      if kind == hkColour: card.colour == value
      else: card.rank == value
    if matches:
      result.add(slot)

# Sim-level conveniences; each builds a view, so a hot loop should hold one.
proc isPlayable*(sim: Sim, colour, rank: int): bool =
  rank >= 1 and rank <= 5 and sim.fireworks[colour] + 1 == rank
proc discardedCopies*(sim: Sim, colour, rank: int): int =
  for card in sim.discards:
    if card.colour == colour and card.rank == rank:
      result += 1
proc isDeadIdent*(sim: Sim, colour, rank: int): bool =
  sim.view().isDeadIdent(colour, rank)
proc tableCopies*(sim: Sim, colour, rank: int): int =
  sim.view().tableCopies(colour, rank)
proc isCriticalIdent*(sim: Sim, colour, rank: int): bool =
  sim.view().isCriticalIdent(colour, rank)
proc candidates*(sim: Sim, seat, slot: int): seq[Card] =
  sim.view().candidates(seat, slot)
proc knownPlayable*(sim: Sim, seat, slot: int): bool =
  sim.view().knownPlayable(seat, slot)
proc knownDead*(sim: Sim, seat, slot: int): bool =
  sim.view().knownDead(seat, slot)
proc knownCritical*(sim: Sim, seat, slot: int): bool =
  sim.view().knownCritical(seat, slot)
proc chopSlot*(sim: Sim, seat: int): int =
  sim.view().chopSlot(seat)
proc hintTouches*(sim: Sim, target: int, kind: HintKind, value: int): seq[int] =
  sim.view().hintTouches(target, kind, value)

# ---- Queries ----------------------------------------------------------------

proc score*(sim: Sim): int =
  for colour in 0 ..< Colours:
    result += sim.fireworks[colour]

proc pendingSeats*(sim: Sim): seq[int] =
  ## Hanabi is turn-based: exactly one seat owes a move, or none once the
  ## episode is over. That single fact is what makes the game loop
  ## sequential while the starter's batching code stays untouched.
  if sim.done:
    return
  @[sim.turn mod Seats]

proc hintValueText*(kind: HintKind, value: int): string =
  if kind == hkColour: ColourNames[value] else: $value

proc illegalReason*(sim: Sim, move: Move): string =
  ## "" when the move is legal for the seat whose turn it is. This is the
  ## ONE legality rule: `legalMoves` enumerates exactly the moves for which
  ## this returns "", and the decision path quotes the reason in its retry.
  if sim.done:
    return "the episode is over"
  let seat = sim.turn mod Seats
  let size = sim.hands[seat].size
  case move.kind
  of akPlay:
    if move.slot < 1 or move.slot > size:
      return "slot " & $move.slot & ": you hold " & $size &
        " cards (slots 1.." & $size & ")"
  of akDiscard:
    if sim.hintTokens >= MaxHintTokens:
      return "discard is illegal at " & $MaxHintTokens & " hint tokens"
    if move.slot < 1 or move.slot > size:
      return "slot " & $move.slot & ": you hold " & $size &
        " cards (slots 1.." & $size & ")"
  of akHint:
    if sim.hintTokens < 1:
      return "no hint tokens left: hinting is illegal at 0"
    if move.target == seat:
      return "you cannot hint yourself"
    if move.target < 0 or move.target >= Seats:
      return "seat " & $move.target & " is not at this table"
    if move.hintKind == hkColour and
        (move.value < 0 or move.value >= Colours):
      return "there is no such colour"
    if move.hintKind == hkRank and (move.value < 1 or move.value > 5):
      return "ranks are 1..5"
    if sim.hintTouches(move.target, move.hintKind, move.value).len == 0:
      return "a hint must touch at least one card: " & sim.names[move.target] &
        " holds no " & hintValueText(move.hintKind, move.value) &
        (if move.hintKind == hkRank: "s" else: "")
  ""

proc legalMoves*(sim: Sim): seq[Move] =
  ## Every legal move for the seat whose turn it is, in a fixed order: plays
  ## by ascending slot, discards by ascending slot, then hints by ascending
  ## target, colour before rank, colours in deck order and ranks ascending.
  ## The list IS the legality rule: the prompt shows it, the validator
  ## accepts exactly it, and the baselines only ever choose from it.
  if sim.done:
    return
  let seat = sim.turn mod Seats
  let size = sim.hands[seat].size
  let view = sim.view()
  for slot in 1 .. size:
    result.add(Move(kind: akPlay, slot: slot, target: -1))
  if sim.hintTokens < MaxHintTokens:
    for slot in 1 .. size:
      result.add(Move(kind: akDiscard, slot: slot, target: -1))
  if sim.hintTokens >= 1:
    for target in 0 ..< Seats:
      if target == seat:
        continue
      for colour in 0 ..< Colours:
        if view.hintTouches(target, hkColour, colour).len > 0:
          result.add(Move(kind: akHint, target: target, hintKind: hkColour,
            value: colour))
      for rank in 1 .. 5:
        if view.hintTouches(target, hkRank, rank).len > 0:
          result.add(Move(kind: akHint, target: target, hintKind: hkRank,
            value: rank))

proc sameMove*(a, b: Move): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of akPlay, akDiscard: a.slot == b.slot
  of akHint: a.target == b.target and a.hintKind == b.hintKind and
    a.value == b.value

proc moveText*(move: Move): string =
  ## The short printed form the reply parser also accepts.
  case move.kind
  of akPlay: "play " & $move.slot
  of akDiscard: "discard " & $move.slot
  of akHint: "hint " & $move.target & " " &
    hintValueText(move.hintKind, move.value)

proc moveJson*(move: Move): JsonNode =
  case move.kind
  of akPlay: %*{"action": "play", "slot": move.slot}
  of akDiscard: %*{"action": "discard", "slot": move.slot}
  of akHint: %*{
    "action": "hint",
    "target": move.target,
    "hintType": $move.hintKind,
    "hintValue": hintValueText(move.hintKind, move.value)
  }

# ---- Hint annotation --------------------------------------------------------

proc candidateText*(cards: seq[Card], listLimit = 4): string =
  if cards.len == 0:
    return "nothing"
  if cards.len > listLimit:
    return $cards.len & " possibilities"
  var parts: seq[string]
  for card in cards:
    parts.add(cardName(card))
  parts.join(", ")

proc markHint*(hand: var Hand, kind: HintKind, value, turn: int):
    tuple[touched, untouched: seq[int]] =
  ## A hint marks EVERY matching card positively and writes the negative on
  ## every other card in that hand — the untouched cards are informative too.
  for slot in 1 .. hand.size:
    let matches =
      if kind == hkColour: hand.cards[slot - 1].card.colour == value
      else: hand.cards[slot - 1].card.rank == value
    if matches:
      if kind == hkColour:
        hand.cards[slot - 1].hintColour = value
      else:
        hand.cards[slot - 1].hintRank = value
      hand.cards[slot - 1].hintedTurn = turn
      result.touched.add(slot)
    else:
      if kind == hkColour:
        hand.cards[slot - 1].negColours.incl(uint8(value))
      else:
        hand.cards[slot - 1].negRanks.incl(uint8(value))
      result.untouched.add(slot)

proc slotList*(slots: seq[int]): string =
  if slots.len == 0:
    return ""
  if slots.len == 1:
    return $slots[0]
  var parts: seq[string]
  for slot in slots[0 ..< slots.high]:
    parts.add($slot)
  parts.join(", ") & " and " & $slots[^1]

proc annotateView*(view: View, names: seq[string], move: Move, turn: int):
    Annotation =
  ## What a hint teaches its receiver, computed from the pre-hint state.
  if move.kind != akHint:
    return
  let target = move.target
  let size = view.hands[target].size
  let before = view.basisFor(target)
  var pre: array[HandSize, SlotFacts]
  for slot in 1 .. size:
    pre[slot - 1] = view.slotFacts(before, target, slot)
  var probe = view
  let marks = markHint(probe.hands[target], move.hintKind, move.value, turn)
  result.touched = marks.touched
  result.untouched = marks.untouched
  let after = probe.basisFor(target)
  for slot in 1 .. size:
    let facts = probe.slotFacts(after, target, slot)
    if facts.playable and not pre[slot - 1].playable:
      result.nowPlayable.add(slot)
    if facts.dead and not pre[slot - 1].dead:
      result.nowDead.add(slot)
    if facts.critical and not pre[slot - 1].critical:
      result.nowCritical.add(slot)
  let name = names[target]
  let value = hintValueText(move.hintKind, move.value)
  for slot in result.touched:
    if result.learned.len >= MaxLearnedLines - 1:
      break
    let what =
      if move.hintKind == hkColour: "is " & value
      else: "is a " & value
    result.learned.add(capLine(name & " slot " & $slot & " " & what &
      " (candidates: " &
      candidateText(probe.candidatesWith(after, target, slot)) & ")",
      MaxLearnedLen))
  if result.untouched.len > 0 and result.learned.len < MaxLearnedLines:
    let single = result.untouched.len == 1
    result.learned.add(capLine(name & (if single: " slot " else: " slots ") &
      slotList(result.untouched) & (if single: " is not " else: " are not ") &
      value & (if move.hintKind == hkRank: "s" else: ""), MaxLearnedLen))

proc annotate*(sim: Sim, move: Move): Annotation =
  sim.view().annotateView(sim.names, move, sim.turn)

# ---- Play -------------------------------------------------------------------

proc fnv1a64(data: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for ch in data:
    result = result xor uint64(ord(ch))
    result = result * 0x100000001b3'u64

proc digest*(sim: Sim): string =
  ## FNV-1a 64 over everything a re-derivation must reproduce exactly.
  var parts: seq[string]
  for colour in 0 ..< Colours:
    parts.add($sim.fireworks[colour])
  for card in sim.discards:
    parts.add($card.colour & ":" & $card.rank)
  parts.add("t" & $sim.hintTokens & "f" & $sim.fuses & "n" & $sim.turn &
    "c" & $sim.countdown & "d" & $sim.deck.len)
  for seat in 0 ..< Seats:
    for slot in 1 .. sim.hands[seat].size:
      let held = sim.hands[seat].cards[slot - 1]
      var negC, negR: string
      for value in 0'u8 .. 4'u8:
        if value in held.negColours:
          negC.add($value)
      for value in 1'u8 .. 5'u8:
        if value in held.negRanks:
          negR.add($value)
      parts.add($seat & "/" & $slot & "/" & $held.card.colour & ":" &
        $held.card.rank & "/" & $held.hintColour & ":" & $held.hintRank &
        "/" & negC & ":" & negR)
  toLowerAscii(toHex(fnv1a64(parts.join("|")), 16))

proc settle(sim: var Sim, reason, endReason: string) =
  sim.done = true
  sim.reason = reason
  sim.endReason = endReason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.turn = sim.turn
  event.text = reason
  event.endReason = endReason
  event.score = sim.score()
  for colour in 0 ..< Colours:
    event.fireworks.add(sim.fireworks[colour])
  event.hintTokens = sim.hintTokens
  event.fuses = sim.fuses
  event.deck = sim.deck.len
  event.countdown = sim.countdown
  event.digest = sim.digest()
  sim.addEvent(event)

proc logLine*(sim: Sim, event: GameEvent): string =
  ## One plain-English public line per turn. The seats read this in their
  ## observation; the viewer draws its own from the same event.
  if event.kind != evMove:
    return ""
  let actor = sim.names[event.seat]
  case event.action
  of "hint":
    let touched =
      if event.touched.len == 0: "nothing"
      elif event.touched.len == 1: "slot " & slotList(event.touched)
      else: "slots " & slotList(event.touched)
    result = actor & " tells " & sim.names[event.target] & " about " &
      event.hintValue & (if event.hintType == "rank": "s" else: "") &
      " (" & touched & ")"
  of "play":
    if event.outcome == "misplay":
      result = actor & " misplays the " & cardName(event.card) &
        " — fizzle, " & $event.fuses & " fuses left"
    else:
      result = actor & " plays the " & cardName(event.card) & " — " &
        ColourNames[event.card.colour] & " reaches " & $event.card.rank
  of "discard":
    result = actor & " discards the " & cardName(event.card)
  else:
    result = actor & " passes"
  if event.origin == "fallback":
    result.add(" (fallback)")

proc applyMove*(sim: var Sim, seat: int, move: Move, note = "", banner = "",
    origin = "llm") =
  ## The acting seat plays `move`. Raises HanabiError on anything illegal —
  ## the decision path has already checked the same rule against
  ## `legalMoves`, so this is the invariant enforced a second time. Steps
  ## 4..8 of the turn resolution.
  if sim.done:
    raise newException(HanabiError, "the episode is over")
  if seat != sim.turn mod Seats:
    raise newException(HanabiError,
      "it is not " & (if seat >= 0 and seat < Seats: sim.names[seat]
                      else: "seat " & $seat) & "'s turn")
  let reason = sim.illegalReason(move)
  if reason.len > 0:
    raise newException(HanabiError, reason)

  var event = blankEvent(evMove)
  event.turn = sim.turn
  event.seat = seat
  event.action = $move.kind
  event.origin = origin
  event.scripted = origin == "scripted" or origin == "fallback"

  var drew = false
  case move.kind
  of akHint:
    let hint = sim.annotate(move)
    sim.hintTokens -= 1
    discard markHint(sim.hands[move.target], move.hintKind, move.value,
      sim.turn)
    sim.stat[seat].hints += 1
    event.target = move.target
    event.hintType = $move.hintKind
    event.hintValue = hintValueText(move.hintKind, move.value)
    event.touched = hint.touched
    event.untouched = hint.untouched
    event.learned = hint.learned
    event.nowPlayable = hint.nowPlayable
    event.nowDead = hint.nowDead
    event.nowCritical = hint.nowCritical
    event.outcome = "hint"
  of akPlay, akDiscard:
    var hand = sim.hands[seat]
    let card = hand.cards[move.slot - 1].card
    for index in move.slot - 1 ..< hand.size - 1:
      hand.cards[index] = hand.cards[index + 1]
    hand.cards[hand.size - 1] = blankHeld()
    hand.size -= 1
    sim.hands[seat] = hand
    event.slot = move.slot
    event.card = card
    if move.kind == akPlay:
      if sim.isPlayable(card.colour, card.rank):
        sim.fireworks[card.colour] = card.rank
        sim.stat[seat].plays += 1
        event.outcome = "stack"
        if card.rank == 5:
          var line = "the " & ColourNames[card.colour] & " firework is finished"
          if sim.hintTokens < MaxHintTokens:
            sim.hintTokens += 1
            line.add(" — a hint token comes back")
          event.learned.add(capLine(line, MaxLearnedLen))
      else:
        sim.discards.add(card)
        sim.fuses -= 1
        sim.stat[seat].misplays += 1
        event.outcome = "misplay"
        event.fizzle = true
    else:
      sim.discards.add(card)
      sim.hintTokens = min(MaxHintTokens, sim.hintTokens + 1)
      sim.stat[seat].discards += 1
      event.outcome = "discarded"
    drew = true

  if event.outcome == "misplay" or event.outcome == "discarded":
    ## A card that left play for good is worth one line: it may have taken a
    ## whole colour's ceiling with it.
    let card = event.card
    if sim.tableCopies(card.colour, card.rank) == 0 and
        sim.fireworks[card.colour] < card.rank:
      event.learned.add(capLine("the last " & cardName(card) & " — " &
        ColourNames[card.colour] & " can never pass " & $(card.rank - 1),
        MaxLearnedLen))

  if drew:
    sim.drawInto(seat)

  ## Countdown: the seat that empties the deck arms it on its own turn, so
  ## every seat — including that one — gets exactly one more turn.
  if sim.deck.len == 0 and sim.countdown < 0:
    sim.countdown = Seats
  elif sim.countdown > 0:
    sim.countdown -= 1

  if note.len > 0:
    sim.notes[seat] = note
  sim.banners[seat] = banner
  if origin == "fallback":
    sim.stat[seat].fallbacks += 1
  event.text = sim.notes[seat]
  event.banner = banner
  event.hintTokens = sim.hintTokens
  event.fuses = sim.fuses
  event.deck = sim.deck.len
  event.countdown = sim.countdown
  event.score = sim.score()

  sim.lastMove = event
  sim.addEvent(event)
  let played = sim.turn + 1
  sim.turn = played
  sim.actor = played mod Seats

  ## End tests, in order.
  if sim.fuses == 0:
    sim.settle("complete", "strikeout")
  elif sim.score() == Colours * 5:
    sim.settle("complete", "perfect")
  elif sim.countdown == 0:
    sim.settle("complete", "deckout")
  elif played >= sim.config.maxTurns:
    sim.settle("complete", "turnlimit")

proc endEarly*(sim: var Sim) =
  ## Stop now, between turns. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode with
  ## the stacks as they stand always beats a long one that never lands.
  if sim.done:
    return
  sim.settle("deadline", "deadline")

# ---- Results ----------------------------------------------------------------

proc contribution*(sim: Sim, seat: int): int =
  ## Display only. Never summed into `scores`: paying a seat for its own
  ## plays is exactly the incentive that breaks a cooperative game.
  sim.stat[seat].plays - sim.stat[seat].misplays

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var contributions = newJArray()
  var plays = newJArray()
  var misplays = newJArray()
  var discards = newJArray()
  var hints = newJArray()
  var fallbacks = newJArray()
  var fireworks = newJArray()
  let team = sim.score()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes by POLICY name,
    ## not by the anonymous alias the seat played under. The score is the
    ## TEAM's, identical for every seat — this game is fully cooperative.
    names.add(%sim.config.players[seat].name)
    scores.add(%team)
    contributions.add(%sim.contribution(seat))
    plays.add(%sim.stat[seat].plays)
    misplays.add(%sim.stat[seat].misplays)
    discards.add(%sim.stat[seat].discards)
    hints.add(%sim.stat[seat].hints)
    fallbacks.add(%sim.stat[seat].fallbacks)
  for colour in 0 ..< Colours:
    fireworks.add(%sim.fireworks[colour])
  %*{
    "names": names,
    "scores": scores,
    "score": team,
    "fireworks": fireworks,
    "contributions": contributions,
    "plays": plays,
    "misplays": misplays,
    "discards": discards,
    "hints": hints,
    "fallbacks": fallbacks,
    "turns": sim.turn,
    "maxTurns": sim.config.maxTurns,
    "deckLeft": sim.deck.len,
    "endReason": sim.endReason,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc heldJson(view: View, basis: Basis, chop, seat, slot: int): JsonNode =
  let held = view.hands[seat].cards[slot - 1]
  var negColours = newJArray()
  for colour in 0 ..< Colours:
    if uint8(colour) in held.negColours:
      negColours.add(%ColourNames[colour])
  var negRanks = newJArray()
  for rank in 1 .. 5:
    if uint8(rank) in held.negRanks:
      negRanks.add(%rank)
  %*{
    "colour": ColourNames[held.card.colour],
    "rank": held.card.rank,
    "hintColour": (if held.hintColour >= 0: %ColourNames[held.hintColour]
                   else: newJString("")),
    "hintRank": held.hintRank,
    "negColours": negColours,
    "negRanks": negRanks,
    "knownPlayable": view.knownPlayableWith(basis, seat, slot),
    "knownDead": view.knownDeadWith(basis, seat, slot),
    "chop": chop == slot,
    "candidates": view.candidatesWith(basis, seat, slot).len,
    "hintedTurn": held.hintedTurn
  }

proc eventToJson*(event: GameEvent): JsonNode

proc frameJson*(sim: Sim): JsonNode =
  ## One object per timeline position; frames.len == events.len + 1. Frames
  ## are small (four hands of four), so every frame is complete — there is
  ## no keyframe/delta scheme.
  let view = sim.view()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let basis = view.basisFor(seat)
    let chop = view.chopSlot(seat)
    var hand = newJArray()
    for slot in 1 .. view.hands[seat].size:
      hand.add(view.heldJson(basis, chop, seat, slot))
    seats.add(%*{
      "name": sim.names[seat],
      "seat": seat,
      "color": seat,
      "acting": (not sim.done) and seat == sim.turn mod Seats,
      "hand": hand,
      "plays": sim.stat[seat].plays,
      "misplays": sim.stat[seat].misplays,
      "discards": sim.stat[seat].discards,
      "hints": sim.stat[seat].hints,
      "contribution": sim.contribution(seat),
      "banner": sim.banners[seat],
      "origin": (if sim.lastMove.kind == evMove and sim.lastMove.seat == seat:
                   sim.lastMove.origin else: ""),
      "fallbacks": sim.stat[seat].fallbacks
    })
  var fireworks = newJArray()
  for colour in 0 ..< Colours:
    fireworks.add(%sim.fireworks[colour])
  var discards = newJArray()
  for colour in 0 ..< Colours:
    for rank in 1 .. 5:
      let count = view.discarded[colour][rank]
      if count > 0:
        discards.add(%*{"colour": ColourNames[colour], "rank": rank,
          "count": count})
  var log = newJArray()
  if sim.lastMove.kind == evMove:
    log.add(%sim.logLine(sim.lastMove))
  %*{
    "seats": seats,
    "fireworks": fireworks,
    "discards": discards,
    "hintTokens": sim.hintTokens,
    "maxHintTokens": MaxHintTokens,
    "fuses": sim.fuses,
    "maxFuses": MaxFuses,
    "deck": sim.deck.len,
    "countdown": sim.countdown,
    "turn": sim.turn,
    "maxTurns": sim.config.maxTurns,
    "actor": (if sim.done: -1 else: sim.turn mod Seats),
    "score": sim.score(),
    "move": (if sim.lastMove.kind == evMove: eventToJson(sim.lastMove)
             else: newJNull()),
    "log": log,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason,
    "endReason": sim.endReason
  }

# ---- The seat's observation --------------------------------------------------

proc knowledgeText(view: View, basis: Basis, chop, seat, slot: int,
    own: bool): string =
  let held = view.hands[seat].cards[slot - 1]
  var parts: seq[string]
  var hints: seq[string]
  if held.hintColour >= 0:
    hints.add("colour " & ColourNames[held.hintColour])
  if held.hintRank > 0:
    hints.add("rank " & $held.hintRank)
  parts.add(if hints.len > 0: "hinted: " & hints.join(", ") else: "no hints")
  var negColours: seq[string]
  for colour in 0 ..< Colours:
    if uint8(colour) in held.negColours:
      negColours.add(ColourNames[colour])
  var negRanks: seq[string]
  for rank in 1 .. 5:
    if uint8(rank) in held.negRanks:
      negRanks.add($rank)
  if negColours.len > 0:
    parts.add("not colour: " & negColours.join(", "))
  if negRanks.len > 0:
    parts.add("not rank: " & negRanks.join(", "))
  if own:
    parts.add("candidates: " &
      candidateText(view.candidatesWith(basis, seat, slot), 6))
    if view.knownPlayableWith(basis, seat, slot):
      parts.add("PLAYABLE")
    if view.knownDeadWith(basis, seat, slot):
      parts.add("DEAD")
  if chop == slot:
    parts.add("CHOP")
  if held.hintedTurn >= 0:
    parts.add("last touched turn " & $held.hintedTurn)
  parts.join(" | ")

proc seatObservation*(sim: Sim, seat: int, operator = ""): string =
  ## Exactly what this seat may know, in words: the table, the partners'
  ## hands face-up, its OWN hand as knowledge only, the public log and the
  ## enumerated legal moves. Its own card identities, the deck, the other
  ## seats' notes and banners, the seed and every policy name are absent by
  ## construction — there is no code path that puts them here.
  let view = sim.view()
  let size = view.hands[seat].size
  var lines: seq[string]
  lines.add("Turn " & $sim.turn & " of " & $sim.config.maxTurns &
    " — your move. Score " & $sim.score() & "/25, hints " & $sim.hintTokens &
    "/" & $MaxHintTokens & ", fuses " & $sim.fuses & "/" & $MaxFuses &
    ", deck " & $sim.deck.len & ".")
  lines.add("You are " & sim.names[seat] & ", seat " & $seat & " of " &
    $Seats & ". Turn order is seat 0, 1, 2, 3, repeating.")
  lines.add("")
  var stacks: seq[string]
  for colour in 0 ..< Colours:
    stacks.add(ColourNames[colour] & " " & $sim.fireworks[colour])
  lines.add("FIREWORKS: " & stacks.join(", ") & ".")
  var piles: seq[string]
  for colour in 0 ..< Colours:
    for rank in 1 .. 5:
      let count = view.discarded[colour][rank]
      if count > 0:
        piles.add(ColourNames[colour] & " " & $rank & " x" & $count)
  lines.add("DISCARDS: " &
    (if piles.len > 0: piles.join(", ") else: "(none)") & ".")
  if sim.countdown >= 0:
    lines.add("DECK OUT: " & $sim.countdown & " turns left after this one.")
  lines.add("")
  lines.add("PARTNERS' HANDS (face-out: you see them, they do not; each " &
    "line also says what THAT seat knows about its own card):")
  for other in 0 ..< Seats:
    if other == seat:
      continue
    let acts = (other - seat + Seats) mod Seats
    let basis = view.basisFor(other)
    let chop = view.chopSlot(other)
    lines.add(sim.names[other] & " — seat " & $other & ", acts in " & $acts &
      (if acts == 1: " turn:" else: " turns:"))
    if view.hands[other].size == 0:
      lines.add("  (no cards)")
    for slot in 1 .. view.hands[other].size:
      lines.add("  slot " & $slot & ": " &
        cardName(view.hands[other].cards[slot - 1].card) & " | " &
        view.knowledgeText(basis, chop, other, slot, own = false))
  lines.add("")
  lines.add("YOUR HAND (you cannot see these cards; this is everything you " &
    "can prove about them):")
  if size == 0:
    lines.add("  (no cards)")
  else:
    let basis = view.basisFor(seat)
    let chop = view.chopSlot(seat)
    for slot in 1 .. size:
      lines.add("  slot " & $slot & ": " &
        view.knowledgeText(basis, chop, seat, slot, own = true))
  lines.add("")
  lines.add("MOVE LOG (public, every turn so far):")
  var logged = 0
  for event in sim.events:
    if event.kind != evMove:
      continue
    logged += 1
    lines.add("  T" & $event.turn & " " & sim.logLine(event))
  if logged == 0:
    lines.add("  (nothing yet — this is the first turn)")
  lines.add("")
  lines.add("YOUR NOTES FROM EARLIER TURNS:")
  lines.add(if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)")
  lines.add("")
  if operator.len > 0:
    lines.add(operator)
  lines.add("LEGAL MOVES (copy ONE of these objects exactly):")
  for index, move in sim.legalMoves():
    lines.add("  " & $(index + 1) & ". " & $moveJson(move))
  lines.join("\n")

proc replayJson*(sim: Sim, results: JsonNode, policyNames: seq[string]):
    JsonNode =
  ## The replay bytes, `hanabi.replay.v1`. Self-sufficient: the aliases, the
  ## policy names, the whole config INCLUDING the seed, every move with its
  ## revealed card and its annotation, every note and banner, and the
  ## results. Nothing but S3 is contacted to render it.
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policies = newJArray()
  for name in policyNames:
    policies.add(%name)
  var events = newJArray()
  for event in sim.events:
    events.add(eventToJson(event))
  %*{
    "protocol": "hanabi.replay.v1",
    "names": names,
    "policyNames": policies,
    "config": {
      "maxTurns": sim.config.maxTurns,
      "seed": sim.config.seed,
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc playerFrameJson*(sim: Sim, slot: int, started: bool): JsonNode =
  ## The `state` frame a player container receives, REDACTED to that seat:
  ## the observation is the only content, and it carries this seat's own
  ## hand as knowledge alone. No other seat's note or banner, no policy
  ## name, no seed and nothing derived from the deck order is in here — and
  ## there is no code path that could put one there, which
  ## tests/test_prompt.nim asserts against a crafted fixture.
  %*{
    "type": "state",
    "slot": slot,
    "name": sim.names[slot],
    "yourTurn": (not sim.done) and slot == sim.turn mod Seats,
    "turn": sim.turn,
    "maxTurns": sim.config.maxTurns,
    "observation": sim.seatObservation(slot),
    "score": sim.score(),
    "hintTokens": sim.hintTokens,
    "fuses": sim.fuses,
    "deck": sim.deck.len,
    "started": started,
    "done": sim.done,
    "reason": sim.reason
  }

# ---- Event JSON -------------------------------------------------------------

proc cardJson(card: Card): JsonNode =
  if card.rank <= 0:
    newJNull()
  else:
    %*{"colour": ColourNames[card.colour], "rank": card.rank}

proc intArray(values: seq[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc stringArray(values: seq[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  case event.kind
  of evStart:
    result["seed"] = %event.seed
    result["seats"] = %event.seats
    result["handSize"] = %event.handSize
    result["maxTurns"] = %event.maxTurns
    result["text"] = %event.text
  of evMove:
    result["turn"] = %event.turn
    result["seat"] = %event.seat
    result["action"] = %event.action
    result["slot"] = %event.slot
    result["card"] = cardJson(event.card)
    result["target"] = %event.target
    if event.hintType.len > 0:
      result["hintType"] = %event.hintType
      result["hintValue"] = %event.hintValue
      result["touched"] = intArray(event.touched)
      result["untouched"] = intArray(event.untouched)
    result["result"] = %event.outcome
    result["fizzle"] = %event.fizzle
    if event.learned.len > 0:
      result["learned"] = stringArray(event.learned)
    if event.nowPlayable.len > 0:
      result["nowPlayable"] = intArray(event.nowPlayable)
    if event.nowDead.len > 0:
      result["nowDead"] = intArray(event.nowDead)
    if event.nowCritical.len > 0:
      result["nowCritical"] = intArray(event.nowCritical)
    result["hintTokens"] = %event.hintTokens
    result["fuses"] = %event.fuses
    result["deck"] = %event.deck
    result["countdown"] = %event.countdown
    result["score"] = %event.score
    result["origin"] = %event.origin
    result["scripted"] = %event.scripted
    if event.text.len > 0:
      result["text"] = %event.text
    if event.banner.len > 0:
      result["banner"] = %event.banner
  of evEnd:
    result["turn"] = %event.turn
    result["text"] = %event.text
    result["endReason"] = %event.endReason
    result["score"] = %event.score
    result["fireworks"] = intArray(event.fireworks)
    result["hintTokens"] = %event.hintTokens
    result["fuses"] = %event.fuses
    result["deck"] = %event.deck
    result["countdown"] = %event.countdown
    result["digest"] = %event.digest

proc intSeq(node: JsonNode): seq[int] =
  if node.isNil or node.kind != JArray:
    return
  for value in node:
    result.add(value.getInt())

proc stringSeq(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray:
    return
  for value in node:
    result.add(value.getStr())

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    turn: node{"turn"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    action: node{"action"}.getStr(""),
    slot: node{"slot"}.getInt(0),
    target: node{"target"}.getInt(-1),
    hintType: node{"hintType"}.getStr(""),
    hintValue: node{"hintValue"}.getStr(""),
    touched: intSeq(node{"touched"}),
    untouched: intSeq(node{"untouched"}),
    learned: stringSeq(node{"learned"}),
    nowPlayable: intSeq(node{"nowPlayable"}),
    nowDead: intSeq(node{"nowDead"}),
    nowCritical: intSeq(node{"nowCritical"}),
    outcome: node{"result"}.getStr(""),
    fizzle: node{"fizzle"}.getBool(false),
    hintTokens: node{"hintTokens"}.getInt(0),
    fuses: node{"fuses"}.getInt(0),
    deck: node{"deck"}.getInt(0),
    countdown: node{"countdown"}.getInt(-1),
    score: node{"score"}.getInt(0),
    origin: node{"origin"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    banner: node{"banner"}.getStr(""),
    endReason: node{"endReason"}.getStr(""),
    fireworks: intSeq(node{"fireworks"}),
    digest: node{"digest"}.getStr(""),
    seed: node{"seed"}.getInt(0),
    seats: node{"seats"}.getInt(0),
    handSize: node{"handSize"}.getInt(0),
    maxTurns: node{"maxTurns"}.getInt(0)
  )
  let card = node{"card"}
  if not card.isNil and card.kind == JObject:
    result.card = Card(colour: max(0, colourIndex(card{"colour"}.getStr())),
      rank: card{"rank"}.getInt(0))

proc moveFromEvent*(event: GameEvent): Move =
  case event.action
  of "play": Move(kind: akPlay, slot: event.slot, target: -1)
  of "discard": Move(kind: akDiscard, slot: event.slot, target: -1)
  of "hint":
    let kind = if event.hintType == "rank": hkRank else: hkColour
    Move(kind: akHint, target: event.target, hintKind: kind,
      value: (if kind == hkColour: colourIndex(event.hintValue)
              else: (try: parseInt(event.hintValue) except ValueError: 0)))
  else:
    raise newException(HanabiError, "unknown action: " & event.action)

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the move events through the rules (the deck comes from the seed).
  ## frames[i] = the state after events[0..<i]. The re-derived hint
  ## annotations and the final digest must equal the recorded ones; a
  ## mismatch raises rather than silently drawing a different game.
  var sim = initSim(config)
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evMove:
      sim.applyMove(event.seat, moveFromEvent(event), event.text, event.banner,
        event.origin)
      let derived = sim.lastMove
      if derived.outcome != event.outcome or
          derived.touched != event.touched or
          derived.untouched != event.untouched or
          derived.learned != event.learned or
          derived.nowPlayable != event.nowPlayable or
          derived.nowDead != event.nowDead or
          derived.nowCritical != event.nowCritical:
        raise newException(HanabiError,
          "turn " & $event.turn & " does not match the seeded re-derivation")
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the moves alone.
        sim.settle(event.text, (if event.endReason.len > 0: event.endReason
                                else: event.text))
      if event.digest.len > 0 and event.digest != sim.digest():
        raise newException(HanabiError,
          "replay digest mismatch: recorded " & event.digest &
          ", re-derived " & sim.digest())
    result.add(sim)
