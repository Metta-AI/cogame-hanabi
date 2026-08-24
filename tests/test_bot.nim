## The scripted baselines must play whole episodes without ever proposing an
## illegal move — they are the no-credentials fallback (offline
## certification), the fallback for a rejected model reply, and fieldable
## policies. And the reply parser has to be tolerant in exactly the ways the
## design note lists, and strict everywhere else.

import std/[monotimes, strutils, times, unicode, unittest]
import hanabi/[llm, sim]

proc fixture(seed: int, maxTurns = 80): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTurns = maxTurns
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    let seat = result.pendingSeats()[0]
    let decision = scriptedAction(result, seat, kinds[seat])
    ## The proposal must be legal AS IS: the legal-move list is the rule.
    check result.illegalReason(decision.move).len == 0
    var found = false
    for move in result.legalMoves():
      if sameMove(move, decision.move):
        found = true
    check found
    check decision.note.len == 0
    check decision.banner.len == 0
    result.applyMove(seat, decision.move, "", "", "scripted")

suite "scripted baselines":
  test "both baselines play 200 seeded episodes legally and fast":
    var slowest = 0
    for seed in 1 .. 200:
      for kinds in [[skConventions, skConventions, skConventions,
          skConventions],
        [skCautious, skCautious, skCautious, skCautious],
        [skConventions, skCautious, skConventions, skCautious]]:
        let started = getMonoTime()
        let sim = playScripted(fixture(seed), kinds)
        let elapsed = (getMonoTime() - started).inMilliseconds.int
        slowest = max(slowest, elapsed)
        check sim.done
        check sim.reason == "complete"
        check sim.turn <= 80
    echo "slowest scripted episode: ", slowest, " ms"
    check slowest < 50

  test "cautious never misplays":
    var fusesLost = 0
    for seed in 1 .. 200:
      let sim = playScripted(fixture(seed),
        [skCautious, skCautious, skCautious, skCautious])
      fusesLost += MaxFuses - sim.fuses
      check sim.endReason != "strikeout"
    check fusesLost == 0

  test "conventions beats cautious and banks half the fireworks":
    var conventions = 0
    var cautious = 0
    for seed in 1 .. 50:
      conventions += playScripted(fixture(seed),
        [skConventions, skConventions, skConventions, skConventions]).score()
      cautious += playScripted(fixture(seed),
        [skCautious, skCautious, skCautious, skCautious]).score()
    let meanConventions = conventions / 50
    let meanCautious = cautious / 50
    echo "mean score: conventions ", meanConventions, ", cautious ",
      meanCautious
    check meanConventions > meanCautious
    check meanConventions >= 12.0

  test "decideAll with no credentials is exactly the scripted decision":
    let config = fixture(3, maxTurns = 40)
    let client = newLlmClient(config)
    ## No ANTHROPIC_API_KEY and no Bedrock endpoint in the test environment:
    ## the client is disabled, so no request is ever built.
    check client.disabled
    var sim = initSim(config)
    var turns = 0
    while not sim.done and turns < 12:
      let seats = sim.pendingSeats()
      check seats.len == 1
      let seat = seats[0]
      let scripted = [skNone, skCautious, skNone, skCautious]
      let decisions = client.decideAll(sim, seats, @["be bold", "", "", ""],
        @scripted)
      check decisions.len == 1
      let kind = if scripted[seat] == skNone: skConventions else: scripted[seat]
      check sameMove(decisions[0].move, scriptedAction(sim, seat, kind).move)
      check decisions[0].origin == "scripted"
      sim.applyMove(seat, decisions[0].move, "", "", "scripted")
      turns += 1
    check turns == 12

suite "reply parsing":
  proc parsed(sim: Sim, text: string): Decision =
    parseDecision(sim, extractJsonObject(text))

  test "the tolerated shapes all normalise to the same move":
    var sim = initSim(fixture(5))
    sim.hands[1].cards[0].card = Card(colour: 0, rank: 3)   ## a red 3
    sim.hands[1].cards[1].card = Card(colour: 2, rank: 1)
    sim.hands[1].cards[2].card = Card(colour: 3, rank: 4)
    sim.hands[1].cards[3].card = Card(colour: 4, rank: 2)
    let want = Move(kind: akHint, target: 1, hintKind: hkColour, value: 0)
    check sameMove(sim.parsed(
      """{"action":"hint","target":1,"hintType":"colour","hintValue":"red"}"""
      ).move, want)
    check sameMove(sim.parsed(
      """{"action":"hint","target":1,"hintType":"color","hintValue":"r"}"""
      ).move, want)
    check sameMove(sim.parsed("""{"move":"hint 1 red"}""").move, want)
    check sameMove(sim.parsed(
      """{"action":"hint","target":"""" & sim.names[1] &
      """","hint":"red"}""").move, want)
    ## A markdown fence, and a valid object followed by prose.
    check sameMove(sim.parsed("```json\n{\"action\":\"play\",\"slot\":2}\n```")
      .move, Move(kind: akPlay, slot: 2, target: -1))
    check sameMove(sim.parsed(
      """{"action": "play", "slot": "2"} — I think that is the red 1."""
      ).move, Move(kind: akPlay, slot: 2, target: -1))
    check sameMove(sim.parsed("""{"move":"play 3"}""").move,
      Move(kind: akPlay, slot: 3, target: -1))
    ## number/rank spellings and a numeric rank value.
    let rank = Move(kind: akHint, target: 1, hintKind: hkRank, value: 3)
    check sameMove(sim.parsed(
      """{"action":"hint","target":1,"hintType":"number","hintValue":3}"""
      ).move, rank)
    check sameMove(sim.parsed("""{"move":"hint 1 3"}""").move, rank)
    ## Discards need a token back first, but they parse either way.
    check sameMove(sim.parsed("""{"action":"discard","slot":4}""").move,
      Move(kind: akDiscard, slot: 4, target: -1))

  test "notes and banners are capped on rune boundaries":
    var sim = initSim(fixture(5))
    var long = ""
    for index in 0 ..< 700:
      long.add("é")
    let decision = sim.parsed("""{"action":"play","slot":1,"note":"""" &
      long & """","banner":"""" & long & """"}""")
    check decision.note.runeLen == MaxNoteLen
    check decision.banner.runeLen == MaxBannerLen
    check decision.note.validateUtf8() == -1
    check decision.banner.validateUtf8() == -1
    check cleanText(long, MaxNoteLen).runeLen == MaxNoteLen
    check cleanText(long, MaxBannerLen).runeLen == MaxBannerLen
    ## Newlines never survive into a banner.
    let multi = sim.parsed(
      """{"action":"play","slot":1,"banner":"one\ntwo"}""")
    check multi.banner == "one two"

  test "everything else is rejected with a reason":
    var sim = initSim(fixture(5))
    expect HanabiError:
      discard sim.parsed("""{"action":"ponder","slot":1}""")
    expect HanabiError:
      discard sim.parsed("""{"note":"no action here"}""")
    expect HanabiError:
      discard sim.parsed("I would play slot 1, I think.")
    expect HanabiError:
      discard sim.parsed("""{"action":"hint","target":0,"hint":"puce"}""")
    ## Parseable but illegal: the legal-move list is what refuses these.
    check sim.illegalReason(sim.parsed(
      """{"action":"play","slot":0}""").move).len > 0
    check sim.illegalReason(sim.parsed(
      """{"action":"play","slot":9}""").move).len > 0
    check sim.illegalReason(sim.parsed(
      """{"action":"hint","target":0,"hintType":"rank","hintValue":1}"""
      ).move).len > 0                                   ## self-hint
    check sim.hintTokens == MaxHintTokens
    check sim.illegalReason(sim.parsed(
      """{"action":"discard","slot":1}""").move).len > 0  ## 8 tokens
    ## An empty hint: nobody at this table holds a green card.
    var empty = initSim(fixture(5))
    for slot in 1 .. HandSize:
      empty.hands[1].cards[slot - 1].card = Card(colour: 0, rank: slot)
    let move = empty.parsed(
      """{"action":"hint","target":1,"hintType":"colour","hintValue":"green"}"""
      ).move
    check empty.illegalReason(move).len > 0
    check "at least one card" in empty.illegalReason(move)

  test "PLAYER_SCRIPTED values map to the two baselines":
    check parseScriptKind("1") == skConventions
    check parseScriptKind("true") == skConventions
    check parseScriptKind("conventions") == skConventions
    check parseScriptKind("cautious") == skCautious
    check parseScriptKind("careful") == skCautious
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone
