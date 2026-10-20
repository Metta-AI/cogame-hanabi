## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "hanabi-rules-v3"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, identity: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & identity & " of four cogs playing Hanabi, a fully cooperative card game."
  of pvPlain: "In Hanabi, a fully cooperative card game for four cogs, you are " & identity & "."
  of pvNumbered: "1. Your identity: " & identity & ". 2. Four cogs play Hanabi. 3. This card game is fully cooperative."
  of pvQuestions: "Who are you? " & identity & ". What are you playing? Hanabi, a fully cooperative card game for four cogs."
  of pvReordered: "Four cogs play the fully cooperative card game Hanabi. You are " & identity & "."
  of pvHeldoutBriefing: "Your role is " & identity & " in Hanabi: a fully cooperative card game played by four cogs."
  of pvHeldoutReference: "Game: Hanabi. Players: four cogs. Mode: fully cooperative card game. Your identity: " & identity & "."
  of pvMixed: raise newException(ValueError, "mixed must resolve")

proc rulesBriefing*(selection: PromptSelection): string =
  let deck = "There are 50 cards: red, yellow, green, blue, and white each contain three 1s, " &
    "two 2s, two 3s, two 4s, and one 5. Five color stacks start at zero and must grow in " &
    "strict rank order from 1 through 5. Discards are public. Start with eight hint tokens " &
    "(also the maximum) and three fuses."
  let knowledge = "Hold four outward-facing cards: partners see yours, you see theirs, and you " &
    "cannot see your own. Slots run left to right, 1..4, newest first and oldest last. " &
    "After a card leaves, draw into slot 1 and shift the remaining cards to higher slots. " &
    "Once the deck is empty, no replacement is drawn and your hand shrinks."
  let moves = "Choose exactly one action per turn. PLAY a slot: if its rank is next for its " &
    "color stack, advance that stack; completing rank 5 restores one hint token if below " &
    "eight. Otherwise discard the misplayed card and burn a fuse. DISCARD a slot to " &
    "restore one hint token; discarding at eight tokens is illegal. HINT another seat " &
    "about a color or rank for one token: mark every matching card, with unmarked cards " &
    "providing negative information too. A hint must touch something, cannot target you, " &
    "and requires a remaining token."
  let communication = "Hints are the only communication with partners. There is no chat; " &
    "other players never read your written text."
  let ending = "End immediately on the third misplay or on completing all five stacks. " &
    "Drawing the last card grants each seat exactly one further turn, including its " &
    "drawer. The turn limit also ends play."
  let scoring = "Every seat receives the same score: the sum of the five stack heights, " &
    "from 0 to 25. Higher is better; success is shared by all players."
  case selection.selectedVariant
  of pvPlain:
    result = deck & "\n\n" & knowledge & "\n\n" & moves & "\n\n" & communication & "\n\n" & ending & "\n\n" & scoring
  of pvNumbered:
    result = """1. Shared task and equipment
All four seats earn the same total, the sum of the five firework heights from 0 to 25; aim higher together. Each color starts at zero and accepts ranks 1 through 5 in that order. The 50-card deck has red, yellow, green, blue, and white; each color has three ones, two each of twos, threes, and fours, and one five. Discarded cards are public. Begin with eight hint tokens, which is the cap, and three fuses.
2. Hands and information
Your four cards face your partners, not you. You can see their cards but not your own. Slots 1..4 go left to right from newest to oldest. A card leaving your hand is replaced in slot 1 while survivors shift to higher slots. After the deck runs out, replacements stop and hands get smaller.
3. One move per turn
PLAY chooses a slot: the next rank for its color advances that firework; a successful five refunds a hint token if fewer than eight remain. Any other play discards the card and consumes a fuse. DISCARD chooses a slot and refunds one hint, but is forbidden at eight tokens. HINT spends one token on another seat's color or rank, identifying every matching card and excluding that attribute from all unmarked cards. Hints require a token and at least one match; self-hints are forbidden.
4. Communication and finish
Hints are your only way to communicate with partners. There is no chat, and partners never see your written text. The third misplay or five completed stacks ends play immediately. Once the final card is drawn, all seats get one additional turn, including the drawer. Reaching the turn limit also ends the game."""
  of pvQuestions:
    result = """What are we building?
Five fireworks, one in each of red, yellow, green, blue, and white. Stacks begin at zero and accept ranks strictly from 1 to 5. Everyone receives their combined height as the same 0..25 score, so a higher team total benefits every seat. Of the 50 cards, each color supplies three rank-1 cards, two of ranks 2, 3, and 4, and a single rank 5. Discards are visible. The initial resources are three fuses and eight hint tokens; eight is also the hint limit.
What do I know about my hand?
You hold four cards facing outward: partners see your identities while you see theirs, never your own. Left-to-right slots 1..4 put the newest card first and the oldest last. Whenever a card leaves, its replacement enters at slot 1 and the survivors move toward higher slot numbers. An exhausted deck supplies no replacements, so the hand shrinks.
Which move can I make?
Take exactly one action. PLAY a slot to try its card: a rank immediately following its color's stack advances it, and finishing a five returns a hint if the pool is below eight. A failed play discards that card and loses a fuse. DISCARD a slot to recover one hint, only if the pool is below eight. HINT a different seat about one color or rank by paying one hint token. It must match at least one card, marks all matches, and gives negative information about every unmarked card. You need a token and cannot hint yourself.
Can I explain my intentions?
Only through hints. Chat is unavailable, and no partner reads your written text.
When is scoring final?
Immediately after a third misplay or all five completed stacks. The last draw instead starts one final turn for every seat, including the player who drew it. The turn limit is another stopping condition."""
  of pvReordered:
    result = """TEAM RESULT AND STOPPING
Your score is identical to every partner's: add the five stack heights for a total between 0 and 25. Higher totals are better for everyone. Play stops immediately when the third fuse is burned by a misplay or all five stacks are complete. Drawing the deck's last card leaves one more turn for each seat, drawer included. A reached turn limit also stops play.
ACTIONS AND COMMUNICATION
On a turn, choose one action. A PLAY names a slot; the card must be the next rank in its color to advance that stack. Finishing rank 5 restores one hint, capped at eight. An incorrect play discards the card and burns a fuse. A DISCARD removes a slot's card and restores one hint; it is illegal when eight hints remain. A HINT costs one token and tells another seat a color or rank present in its hand. Every match must be marked, and unmarked cards rule out that color or rank. No token, no match, or a self-target makes a hint illegal. Hints alone carry communication: there is no chat and partners cannot read your text.
WHAT YOU SEE
Four cards face away from you, exposing them to partners; you see partner hands but not your own identities. Slots are 1..4, left to right, with newest first and oldest last. After removal, insert the next drawn card into slot 1 and shift survivors toward larger slots. With the deck empty, draw nothing and let the hand shrink. The discard pile is public.
STARTING MATERIAL
There are 50 cards over red, yellow, green, blue, and white. Each color contains three 1s, two 2s, two 3s, two 4s, and one 5. Its stack starts at zero and must be built in rank order 1, 2, 3, 4, 5. Start with three fuses and the full eight-token hint pool."""
  of pvHeldoutBriefing:
    result = """You and your partners share a single objective: raise the total height of five fireworks. Everyone gets that same total, from 0 to 25. Red, yellow, green, blue, and white each have a stack beginning at zero, built strictly from rank 1 through rank 5. The deck contains 50 cards: per color, three copies of 1, two copies each of 2, 3, and 4, and one copy of 5. Discards are public. You begin with three fuses and eight hint tokens, the maximum token supply.

Your information is asymmetric. Partners can read your four outward-facing cards, while you can read theirs but cannot see your own. Positions 1..4 run left to right, newest to oldest. A departing card makes room for a draw at position 1, shifting the others to larger numbers. If no cards remain in the deck, there is no draw and your hand becomes smaller.

Each turn permits one move. Playing a slot succeeds only when its card is the next rank for that color's stack. Success at rank 5 refunds a hint token unless eight are already available. Failure sends the played card to the discard pile and uses a fuse. Discarding a slot deliberately refunds one hint and is prohibited at eight hints. Giving a hint spends a token to identify every card of a chosen color or rank in another seat's hand. It must identify something, cannot target yourself, and also tells the receiver that unmarked cards lack that attribute.

Coordinate entirely through hints: there is no chat and your written words are never shown to partners. Three misplays or completion of all five stacks ends the episode immediately. When the last card is drawn, every seat has exactly one subsequent turn, including that card's drawer. Play also ends at the turn limit."""
  of pvHeldoutReference:
    result = """Information reference: Each seat holds four outward-facing cards. You observe partners' card identities, partners observe yours, and your own identities are hidden from you. Slots 1 through 4 read left to right, newest before oldest. Removing a card causes a replacement draw into slot 1 and shifts remaining cards toward higher indices; an empty deck means no replacement and a smaller hand. Discards are public.
Move reference: Exactly one action is taken per turn. PLAY selects a slot, adding its card to its color stack only if the rank is the next required one. A correctly completed five replenishes one hint up to the eight-token ceiling. Misplays discard the card and consume one fuse. DISCARD selects a slot and replenishes one hint, but cannot be used at the ceiling. HINT consumes one available token and names a color or rank for another seat. It must mark at least one card and all matching cards; every unmarked card yields negative information. The acting seat is never a legal hint recipient.
Material reference: The 50-card deck comprises red, yellow, green, blue, and white. For each color the rank multiplicities are 1: three; 2, 3, 4: two each; 5: one. Five stacks start at zero and grow in strict ascending rank order from 1 to 5. Starting resources are eight hints and three fuses, with hints capped at eight.
Team reference: Hints are the sole communication channel, with no chat and no partner access to written text. All seats receive the sum of stack heights, a shared 0..25 score to maximize.
End reference: Stop immediately upon the third misplay or completion of all five stacks. After the last draw, allow precisely one more turn per seat, including its drawer. The turn limit can also terminate play."""
  of pvCanonical, pvMixed:
    raise newException(ValueError, "alternate wording must resolve")
