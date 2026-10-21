## The teacher receives the same information as its acting seat.
import std/unittest
import hanabi/[llm, sim]

suite "private Hanabi teacher":
  test "hidden own cards and deck order cannot change prompts or labels":
    for seed in 1 .. 30:
      var config = defaultGameConfig()
      config.seed = seed
      config.sampled = true
      config.players = @[PlayerConfig(name: "a"), PlayerConfig(name: "b"),
        PlayerConfig(name: "c"), PlayerConfig(name: "d")]
      config.tokens = @["a", "b", "c", "d"]
      let original = initSim(config)
      for seat in 0 ..< Seats:
        for cardIndex in 0 ..< original.deck.len:
          var changed = original
          changed.deck = newSeq[Card](original.deck.len)
          for index, value in original.deck: changed.deck[index] = value
          changed.deck[cardIndex] = original.hands[seat].cards[0].card
          changed.hands[seat].cards[0].card = original.deck[cardIndex]
          let samePrompt = userPrompt(changed, seat, "private policy") ==
            userPrompt(original, seat, "private policy")
          check samePrompt
          if seat != original.turn mod Seats: continue
          for kind in [skConventions, skCautious]:
            let expected = scriptedAction(original, seat, kind)
            let actual = scriptedAction(changed, seat, kind)
            check sameMove(actual.move, expected.move)
            check changed.illegalReason(actual.move) == ""
