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
  PromptBankVersion* = "hanabi-rules-v2"

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
    result = "1. Components\n" & deck & "\n2. Information\n" & knowledge &
      "\n3. Turn choices\n" & moves & "\n4. Communication\n" & communication &
      "\n5. Ending\n" & ending & "\n6. Score\n" & scoring
  of pvQuestions:
    result = "What are we trying to achieve?\n" & scoring & "\nWhat can I know?\n" & knowledge &
      "\nWhat is on the table?\n" & deck & "\nWhat can I do?\n" & moves &
      "\nCan I talk to partners?\n" & communication & "\nWhen do we stop?\n" & ending
  of pvReordered:
    result = "TEAM SCORE\n" & scoring & "\nGAME END\n" & ending & "\nA TURN\n" & moves &
      "\nCOMMUNICATION\n" & communication & "\nHIDDEN INFORMATION\n" & knowledge & "\nCOMPONENTS\n" & deck
  of pvHeldoutBriefing:
    result = "Your information boundary is:\n" & knowledge & "\n" & communication &
      "\nThe shared objective is:\n" & scoring & "\nThe board and resources are:\n" & deck &
      "\nYour legal choices follow these rules:\n" & moves & "\nPlay concludes as follows:\n" & ending
  of pvHeldoutReference:
    result = "Action reference: " & moves & "\nResource reference: " & deck &
      "\nObservation reference: " & knowledge & "\nCommunication reference: " & communication &
      "\nScoring reference: " & scoring & "\nTermination reference: " & ending
  of pvCanonical, pvMixed:
    raise newException(ValueError, "alternate wording must resolve")
