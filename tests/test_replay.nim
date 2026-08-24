## End to end: a whole episode, the artifacts it writes, and the promise
## that the replay bytes alone re-derive the same game — including every
## hint annotation and the final digest — in strict UTF-8.

import std/[json, os, sets, unicode, unittest]
import hanabi/[llm, sim]

proc fixture(seed: int, maxTurns = 80): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTurns = maxTurns
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "Policy" & $index))
    result.tokens.add("t" & $index)

proc longRunes(count: int): string =
  for index in 0 ..< count:
    result.add("é")

proc playEpisode(config: GameConfig, withText = false): Sim =
  ## A scripted episode. With `withText`, every turn carries a multi-byte
  ## note and banner truncated exactly at the caps, so the replay bytes are
  ## the worst case a strict parser can be handed.
  result = initSim(config)
  let note = cleanText(longRunes(700), MaxNoteLen)
  let banner = cleanText(longRunes(700), MaxBannerLen)
  while not result.done:
    let seat = result.pendingSeats()[0]
    let kind = if seat mod 2 == 0: skConventions else: skCautious
    let decision = scriptedAction(result, seat, kind)
    if withText:
      result.applyMove(seat, decision.move, note, banner, "llm")
    else:
      result.applyMove(seat, decision.move, "", "", "scripted")

const ReasonValues = ["complete", "deadline"]
const EndReasonValues = ["perfect", "strikeout", "deckout", "turnlimit",
  "deadline"]

suite "artifacts":
  test "an episode writes results and a replay that parse strictly":
    let config = fixture(21)
    let sim = playEpisode(config, withText = true)
    check sim.done
    let results = sim.resultsJson()
    var policyNames: seq[string]
    for player in config.players:
      policyNames.add(player.name)
    let replay = sim.replayJson(results, policyNames)

    let dir = getTempDir() / "hanabi-test-replay"
    createDir(dir)
    defer: removeDir(dir)
    let resultsPath = dir / "results.json"
    let replayPath = dir / "replay.json"
    writeFile(resultsPath, $results)
    writeFile(replayPath, $replay)

    ## Strict: raw bytes must be valid UTF-8 AND parse as JSON. A byte cut
    ## through a multi-byte character would pass a browser and fail here.
    let rawResults = readFile(resultsPath)
    let rawReplay = readFile(replayPath)
    check rawResults.validateUtf8() == -1
    check rawReplay.validateUtf8() == -1
    let reread = parseJson(rawReplay)
    check reread["protocol"].getStr() == "hanabi.replay.v1"
    check reread["config"]["seed"].getInt() == config.seed
    check reread["config"]["maxTurns"].getInt() == config.maxTurns
    check reread["names"].len == Seats
    check reread["policyNames"].len == Seats
    check reread["results"]["scores"].len == Seats

    ## Every recorded note and banner is capped on a rune boundary.
    var sawText = false
    for node in reread["events"]:
      if node{"kind"}.getStr() != "move":
        continue
      let text = node{"text"}.getStr()
      let banner = node{"banner"}.getStr()
      if text.len > 0:
        sawText = true
        check text.runeLen == MaxNoteLen
        check text.validateUtf8() == -1
      if banner.len > 0:
        check banner.runeLen == MaxBannerLen
        check banner.validateUtf8() == -1
    check sawText

suite "re-derivation":
  test "the replay re-derives every turn, annotation and digest":
    for seed in 1 .. 20:
      let config = fixture(seed)
      let live = playEpisode(config)
      let frames = replayMatch(config, live.events)
      check frames.len == live.events.len + 1
      check $frames[^1].frameJson() == $live.frameJson()
      check frames[^1].digest() == live.digest()
      check frames[^1].done
      check frames[^1].reason == live.reason
      check frames[^1].endReason == live.endReason
      ## The digest recorded in the end event is the one re-derivation gets.
      let final = live.events[^1]
      check final.kind == evEnd
      check final.digest == frames[^1].digest()
      ## Every recorded hint annotation is re-derived identically.
      var hints = 0
      for index, event in live.events:
        if event.kind != evMove or event.action != "hint":
          continue
        hints += 1
        let before = frames[index]
        let annotation = before.annotate(moveFromEvent(event))
        check annotation.touched == event.touched
        check annotation.untouched == event.untouched
        check annotation.learned == event.learned
        check annotation.nowPlayable == event.nowPlayable
        check annotation.nowDead == event.nowDead
        check annotation.nowCritical == event.nowCritical
      check hints > 0

  test "a tampered annotation is rejected, not quietly redrawn":
    let config = fixture(4)
    let live = playEpisode(config)
    var events = live.events
    var touchedOne = false
    for index, event in events:
      if event.kind == evMove and event.action == "hint" and not touchedOne:
        touchedOne = true
        events[index].nowPlayable = @[1, 2, 3, 4]
    check touchedOne
    expect HanabiError:
      discard replayMatch(config, events)
    ## And a tampered digest is caught too.
    var digestEvents = live.events
    digestEvents[^1].digest = "0000000000000000"
    expect HanabiError:
      discard replayMatch(config, digestEvents)

  test "a deadline stop is honoured by the re-derivation":
    let config = fixture(6)
    var sim = initSim(config)
    for turn in 0 ..< 9:
      let seat = sim.pendingSeats()[0]
      sim.applyMove(seat, scriptedAction(sim, seat, skConventions).move,
        "", "", "scripted")
    sim.endEarly()
    let frames = replayMatch(config, sim.events)
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check frames[^1].endReason == "deadline"
    check frames[^1].turn == 9
    check frames.len == sim.events.len + 1

suite "the event record":
  test "all three kinds round-trip through JSON":
    let config = fixture(8)
    let sim = playEpisode(config, withText = true)
    var kinds: HashSet[string]
    for event in sim.events:
      kinds.incl($event.kind)
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.turn == event.turn
      check back.seat == event.seat
      check back.action == event.action
      check back.slot == event.slot
      check back.card == event.card
      check back.target == event.target
      check back.hintType == event.hintType
      check back.hintValue == event.hintValue
      check back.touched == event.touched
      check back.untouched == event.untouched
      check back.learned == event.learned
      check back.nowPlayable == event.nowPlayable
      check back.nowDead == event.nowDead
      check back.nowCritical == event.nowCritical
      check back.outcome == event.outcome
      check back.fizzle == event.fizzle
      check back.hintTokens == event.hintTokens
      check back.fuses == event.fuses
      check back.deck == event.deck
      check back.countdown == event.countdown
      check back.score == event.score
      check back.origin == event.origin
      check back.scripted == event.scripted
      check back.text == event.text
      check back.banner == event.banner
      check back.endReason == event.endReason
      check back.fireworks == event.fireworks
      check back.digest == event.digest
      if event.kind == evStart:
        check back.seed == event.seed
        check back.seats == event.seats
        check back.handSize == event.handSize
        check back.maxTurns == event.maxTurns
    check kinds == ["start", "move", "end"].toHashSet()

  test "results.reason and results.endReason have no other values":
    var reasons: HashSet[string]
    var endReasons: HashSet[string]
    for seed in 1 .. 60:
      for maxTurns in [MinTurns, 80]:
        let sim = playEpisode(fixture(seed, maxTurns))
        let results = sim.resultsJson()
        reasons.incl(results["reason"].getStr())
        endReasons.incl(results["endReason"].getStr())
    var early = initSim(fixture(3))
    early.endEarly()
    reasons.incl(early.resultsJson()["reason"].getStr())
    endReasons.incl(early.resultsJson()["endReason"].getStr())
    for value in reasons:
      check value in ReasonValues
    for value in endReasons:
      check value in EndReasonValues
    ## Both documented endings really are producible.
    check "complete" in reasons
    check "deadline" in reasons
    check "deckout" in endReasons
    check "turnlimit" in endReasons
    check "deadline" in endReasons

suite "the frame the viewer reads":
  test "frames carry the whole table and the move that produced them":
    let config = fixture(12)
    let live = playEpisode(config)
    let frames = replayMatch(config, live.events)
    let frame = frames[6].frameJson()
    check frame["seats"].len == Seats
    check frame["fireworks"].len == Colours
    check frame["maxHintTokens"].getInt() == MaxHintTokens
    check frame["maxFuses"].getInt() == MaxFuses
    check frame["move"].kind == JObject
    check frame["log"].len == 1
    for seat in 0 ..< Seats:
      let hand = frame["seats"][seat]["hand"]
      check hand.len == HandSize
      for slot in 0 ..< hand.len:
        check hand[slot]["rank"].getInt() in 1 .. 5
        check hand[slot]["colour"].getStr() in ColourNames
        check hand[slot]["candidates"].getInt() >= 1
    ## Frame 0 is the deal, before any move.
    check frames[0].frameJson()["move"].kind == JNull
    check frames[0].frameJson()["turn"].getInt() == 0
