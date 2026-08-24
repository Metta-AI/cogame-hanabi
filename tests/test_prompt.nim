## Redaction. A seat may know the table, its partners' hands and everything
## hints have told it about its OWN cards — and nothing else. This test
## builds a position whose seat-0 identities appear nowhere else on the
## table and asserts that none of those strings can reach that seat's
## observation or its player frame, on the same code path the socket uses.

import std/[json, strutils, unittest]
import hanabi/[llm, sim]

const SecretSeed = 987654321

proc fixture(): GameConfig =
  result = defaultGameConfig()
  result.seed = SecretSeed
  result.maxTurns = 80
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "SecretPolicyName" & $index))
    result.tokens.add("secret-token-" & $index)

proc card(colour, rank: int): Card = Card(colour: colour, rank: rank)

proc put(sim: var Sim, seat: int, cards: openArray[Card]) =
  sim.hands[seat].size = cards.len
  for index in 0 ..< HandSize:
    sim.hands[seat].cards[index] = HeldCard(card: card(0, 0), hintColour: -1,
      hintRank: 0, hintedTurn: -1)
  for index, value in cards:
    sim.hands[seat].cards[index].card = value

## Seat 0 holds three unique 5s that no other seat holds and that this
## fixture strips out of the deck, so each of these strings can only ever
## reach the text by leaking seat 0's own hand. (Its fourth card is a red 3,
## deliberately NOT unique: a rank hint narrows that slot's candidate set to
## the five 3s, and listing them is knowledge the seat is entitled to.)
const OwnIdentities = ["white 5", "yellow 5", "green 5"]

proc crafted(): Sim =
  result = initSim(fixture())
  result.put(0, [card(4, 5), card(1, 5), card(2, 5), card(0, 3)])
  result.put(1, [card(0, 1), card(0, 2), card(2, 3), card(3, 4)])
  result.put(2, [card(2, 1), card(3, 2), card(1, 3), card(0, 4)])
  result.put(3, [card(3, 1), card(1, 2), card(1, 4), card(2, 4)])
  ## The deck must not hold the seat-0 identities either — remove every 5
  ## so nothing downstream can reveal one.
  var deck: seq[Card]
  for value in result.deck:
    if value.rank != 5:
      deck.add(value)
  result.deck = deck
  ## Give the table some history: a hint, a play, a discard and a hint back.
  result.applyMove(0, Move(kind: akHint, target: 1, hintKind: hkRank,
    value: 1), "my private note about slot 1", "seat 0 banner", "llm")
  result.applyMove(1, Move(kind: akPlay, slot: 1, target: -1),
    "seat 1 private note", "seat 1 banner", "llm")
  result.hintTokens = 6
  result.applyMove(2, Move(kind: akDiscard, slot: 4, target: -1),
    "seat 2 private note", "seat 2 banner", "llm")
  result.applyMove(3, Move(kind: akHint, target: 0, hintKind: hkRank,
    value: 3), "seat 3 private note", "seat 3 banner", "llm")

suite "the seat's observation":
  test "it never contains the seat's own card identities":
    let sim = crafted()
    let text = sim.seatObservation(0, operatorBlock("my operator prompt"))
    for identity in OwnIdentities:
      check identity notin text
    ## The frame the player socket actually sends carries the same text and
    ## nothing else about the hand.
    let frame = sim.playerFrameJson(0, true)
    let observation = frame["observation"].getStr()
    for identity in OwnIdentities:
      check identity notin observation
    check $frame notin ["", "null"]
    for identity in OwnIdentities:
      check identity notin $frame

  test "it does contain the knowledge, the partners, the log and the moves":
    let sim = crafted()
    let text = sim.seatObservation(0, operatorBlock("my operator prompt"))
    check "YOUR HAND" in text
    check "PARTNERS' HANDS" in text
    check "MOVE LOG" in text
    check "LEGAL MOVES" in text
    check "my operator prompt" in text
    check "my private note about slot 1" in text
    ## Seat 3 told seat 0 about 3s: one slot carries the positive hint, the
    ## other three carry the negative, and every one shows its candidate set
    ## without ever naming the card.
    check "hinted: rank 3" in text
    check "not rank: 3" in text
    check "candidates:" in text
    check "possibilities" in text
    ## Every partner card is printed face-up, with its own knowledge.
    check "red 1" in text or "red 2" in text
    check sim.names[1] in text
    check sim.names[2] in text
    check sim.names[3] in text
    ## The public log carries the revealed identity of what was played.
    check "plays the" in text or "discards the" in text

  test "it leaks no other seat's note or banner, no policy name, no seed":
    let sim = crafted()
    let text = sim.seatObservation(0, operatorBlock("my operator prompt"))
    for other in 1 ..< Seats:
      check ("seat " & $other & " private note") notin text
      check ("seat " & $other & " banner") notin text
    check "seat 0 banner" notin text     ## banners are spectator-only
    for player in sim.config.players:
      check player.name notin text
    check $SecretSeed notin text
    for token in sim.config.tokens:
      check token notin text
    ## Nothing derived from the deck order: the next card is invisible.
    check cardName(sim.deck[0]) notin
      text.split("MOVE LOG")[0].split("PARTNERS' HANDS")[0]

suite "the legal-move list is the legality rule":
  test "every printed entry parses back into a legal move, and vice versa":
    var sim = crafted()
    sim.hintTokens = 5                       ## make discards legal too
    let text = sim.seatObservation(sim.turn mod Seats)
    let moves = sim.legalMoves()
    check moves.len > 0
    ## Every legal move is printed, exactly as the object to copy.
    for move in moves:
      check $moveJson(move) in text
    ## Every printed entry parses back into a legal move.
    var printed = 0
    for line in text.split('\n'):
      let start = line.find('{')
      if start < 0 or "action" notin line:
        continue
      printed += 1
      let decision = parseDecision(sim, extractJsonObject(line[start .. ^1]))
      check sim.illegalReason(decision.move).len == 0
      var found = false
      for move in moves:
        if sameMove(move, decision.move):
          found = true
      check found
    check printed == moves.len
