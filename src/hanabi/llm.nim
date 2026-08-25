## Claude-backed decision making for Hanabi. Each seat's policy is just a
## prompt: the game server composes the seat's view (the partners' hands,
## its own hand as knowledge only, the public log, the enumerated legal
## moves, its notes) plus that seat's prompt and asks Claude what it does.
##
## Hanabi is TURN-BASED: seat `turn mod 4` acts alone and its observation
## depends on the move made on the turn before, so decisions cannot be
## batched. The starter's batching code is kept unchanged anyway —
## `pendingSeats` returns a one-element seq, so `decideAll` issues
## `curly.makeRequests` with a batch of ONE and the retry path, the parsing
## and the fallback are the same code on a shorter list.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, os, strutils, times, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The hosted Bedrock sidecar caps 30 requests a minute per episode and a
  ## throttle cascades, so consecutive requests START at least this far
  ## apart. A turn is one request (two with a retry), so this bounds the
  ## episode at 30/minute by construction whatever the latency.
  MinRequestSpacingSeconds* = 2.0
  ## Caps on the fields a reply may carry, in RUNES.
  MaxActionLen* = 12
  MaxTargetLen* = 24
  MaxHintFieldLen* = 8
  MaxRejectLen* = 200

type
  ScriptKind* = enum
    skNone = "none"
    skConventions = "conventions"
    skCautious = "cautious"

  Decision* = object
    move*: Move
    note*: string       ## private to the seat, fed back next turn
    banner*: string     ## spectator-only, never read by any seat
    origin*: string     ## llm | retry | fallback | scripted
    reject*: string     ## why the model's reply was refused, if it was

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock
                          ## picks from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    lastRequestAt: float  ## start of the most recent batch, for the floor
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"conventions" play the
  ## convention-following bot, "cautious" the never-misplays bot, anything
  ## else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "conventions", "convention": skConventions
  of "cautious", "careful": skCautious
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "hanabi llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. The config "model" field is NOT consulted
  ## here: it applies to the direct-Anthropic transport only, and the
  ## haiku-first ordering below is a shared-capacity decision that trumps
  ## per-game preference.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first. `claude-sonnet-4-6` is
  ## deliberately absent: it times out on every hosted sidecar call and
  ## turns one throttle into a fallback cascade (cogame-raid, 2026-08-23).
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "hanabi llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "hanabi llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "hanabi llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "hanabi llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------
#
# Both are pure functions of the sim and the acting seat, both are
# deterministic, and neither ever proposes a move outside `legalMoves`.

proc actsIn(seat, other: int): int =
  (other - seat + Seats) mod Seats

proc hintKey(seat: int, move: Move, primary: int): (int, int, int, int, int) =
  ## Tie-breaks, in order: the primary score, then the seat acting soonest,
  ## then rank before colour, then the lower rank / earlier colour, then the
  ## lower seat index.
  (primary, actsIn(seat, move.target),
    (if move.hintKind == hkRank: 0 else: 1), move.value, move.target)

proc conventionsMove*(sim: Sim, seat: int): Move =
  ## The strong, convention-following partner a prompt has to beat. The
  ## first rule that fires wins.
  let view = sim.view()
  let moves = sim.legalMoves()
  if moves.len == 0:
    return Move(kind: akPlay, slot: 1, target: -1)
  let basis = view.basisFor(seat)

  ## 1. Play the lowest-numbered slot that is known playable.
  for slot in 1 .. view.hands[seat].size:
    if view.knownPlayableWith(basis, seat, slot):
      return Move(kind: akPlay, slot: slot, target: -1)

  ## 2. Save: the next seat to act is about to lose the last copy of a card.
  let next = (seat + 1) mod Seats
  if sim.hintTokens >= 1:
    let chop = view.chopSlot(next)
    if chop >= 1:
      let card = view.hands[next].cards[chop - 1].card
      if card.rank >= 1 and view.isCriticalIdent(card.colour, card.rank):
        let save = Move(kind: akHint, target: next, hintKind: hkRank,
          value: card.rank)
        if sim.illegalReason(save).len == 0:
          return save

  ## 3. Play-hint: the hint that makes the most of the receiver's cards
  ## NEWLY known-playable, at least one.
  var bestHint: Move
  var bestKey = (0, 0, 0, 0, 0)
  var haveHint = false
  for move in moves:
    if move.kind != akHint:
      continue
    let gained = view.annotateView(sim.names, move, sim.turn).nowPlayable.len
    if gained < 1:
      continue
    let key = hintKey(seat, move, -gained)
    if not haveHint or key < bestKey:
      bestKey = key
      bestHint = move
      haveHint = true
  if haveHint:
    return bestHint

  ## 4. Discard the chop (which already prefers a known-dead slot).
  if sim.hintTokens < MaxHintTokens:
    let chop = view.chopSlot(seat)
    if chop >= 1:
      return Move(kind: akDiscard, slot: chop, target: -1)

  ## 5. Stall hint: touch as little as possible, preferring the next seat.
  var haveStall = false
  var stall: Move
  var stallKey = (0, 0, 0, 0, 0, 0)
  for move in moves:
    if move.kind != akHint:
      continue
    let touched = view.hintTouches(move.target, move.hintKind, move.value).len
    let base = hintKey(seat, move, touched)
    let key = ((if move.target == next: 0 else: 1), base[0], base[1], base[2],
      base[3], base[4])
    if not haveStall or key < stallKey:
      stallKey = key
      stall = move
      haveStall = true
  if haveStall:
    return stall

  ## 6. Unreachable — kept so the function is total.
  moves[0]

proc cautiousMove*(sim: Sim, seat: int): Move =
  ## A deliberately simpler partner: the unfamiliar teammate of the
  ## cross-play story. It never misplays.
  let view = sim.view()
  let moves = sim.legalMoves()
  if moves.len == 0:
    return Move(kind: akPlay, slot: 1, target: -1)
  let basis = view.basisFor(seat)

  ## 1. Play only what it can name: a singleton candidate set that is
  ## playable right now.
  for slot in 1 .. view.hands[seat].size:
    let cards = view.candidatesWith(basis, seat, slot)
    if cards.len == 1 and view.isPlayable(cards[0].colour, cards[0].rank):
      return Move(kind: akPlay, slot: slot, target: -1)

  ## 2. Tell somebody the rank of a playable card they know nothing about.
  if sim.hintTokens >= 1:
    for step in 1 ..< Seats:
      let target = (seat + step) mod Seats
      for slot in 1 .. view.hands[target].size:
        let held = view.hands[target].cards[slot - 1]
        if held.hintColour >= 0 or held.hintRank > 0:
          continue
        if not view.isPlayable(held.card.colour, held.card.rank):
          continue
        let move = Move(kind: akHint, target: target, hintKind: hkRank,
          value: held.card.rank)
        if sim.illegalReason(move).len == 0:
          return move

  ## 3. Discard the chop.
  if sim.hintTokens < MaxHintTokens:
    let chop = view.chopSlot(seat)
    if chop >= 1:
      return Move(kind: akDiscard, slot: chop, target: -1)

  ## 4. Stall: the rank of the next seat's oldest card.
  for step in 1 ..< Seats:
    let target = (seat + step) mod Seats
    let size = view.hands[target].size
    if size == 0:
      continue
    let move = Move(kind: akHint, target: target, hintKind: hkRank,
      value: view.hands[target].cards[size - 1].card.rank)
    if sim.illegalReason(move).len == 0:
      return move

  moves[0]

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal; never notes or banners.
  result.origin = "scripted"
  result.move =
    if kind == skCautious: cautiousMove(sim, seat)
    else: conventionsMove(sim, seat)

# ---- Prompt building --------------------------------------------------------

proc systemPrompt*(sim: Sim, seat: int): string =
  ## The mechanics, and nothing else. The system prompt teaches NO
  ## convention: reading an unfamiliar partner's convention is the thing
  ## being measured, so conventions belong in a policy's own prompt.
  "You are " & sim.names[seat] & ", seat " & $seat &
    " of four cogs playing Hanabi, a fully cooperative card game." &
    """

The deck: 50 cards, five colours (red, yellow, green, blue, white), each
with ranks 1 1 1 2 2 3 3 4 4 5 — three 1s, two each of 2, 3 and 4, and a
single 5.

Your hand: four cards, held FACING OUT. Everyone else can see your cards;
YOU CANNOT. You can see everyone else's. Slots are numbered 1..4 left to
right, slot 1 is the newest card and the highest-numbered slot the oldest.
When a card leaves your hand you draw a new one into slot 1 and the others
shift one slot higher; once the deck is empty nothing is drawn and your hand
gets shorter.

The table: five firework stacks, one per colour, each starting at 0 and
built strictly 1, 2, 3, 4, 5. A public discard pile. EIGHT hint tokens
(maximum 8) and THREE fuses.

On your turn you do exactly ONE of three things:
- PLAY a card from a slot. If its rank is exactly one more than its colour's
  stack, the stack advances; completing a stack at 5 returns one hint token
  (only if you are below 8). Otherwise it is a MISPLAY: the card is
  discarded and one fuse burns.
- DISCARD a card from a slot, which returns one hint token. Illegal at 8
  tokens.
- Spend one hint token to tell ANOTHER seat about one colour or one rank.
  The hint marks EVERY card of that colour or rank in their hand, and they
  learn just as much from which cards it did not mark. A hint that would
  touch nothing is illegal, and so is hinting yourself or hinting with no
  tokens left.

The only channel between you and your partners is a hint. There is no chat,
and nothing you write is read by anyone else at the table.

The end: three misplays end the game immediately; so does completing all
five fireworks. When the last card is drawn every seat, including the one
who drew it, takes exactly one more turn. The game also stops at the turn
limit.

Your SCORE is the sum of the five stack heights, 0 to 25, and it is the SAME
number for every seat — you win or lose together. Higher is better.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }. Copy one entry from
the LEGAL MOVES list exactly, and you may add "note" (at most 400
characters, private to you, you will see it again next turn) and "banner"
(at most 80 characters, shown to spectators only — your partners never see
it)."""

proc operatorBlock*(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  result = sim.seatObservation(seat, operatorBlock(prompt))
  result.add("\n\nReply with ONLY one JSON object copied from LEGAL MOVES, " &
    "optionally with \"note\" (at most " & $MaxNoteLen &
    " characters, private to you) and \"banner\" (at most " & $MaxBannerLen &
    " characters, spectators only).")

# ---- Reply parsing ----------------------------------------------------------

proc headRunes(text: string, limit: int): string =
  ## The head of an untrusted string, cut on a RUNE boundary. A byte slice
  ## through a multi-byte character leaves invalid UTF-8 in the retry prompt
  ## and on stdout; cleanText only re-cuts strings longer than its cap, so a
  ## short-but-broken head would pass straight through it.
  if text.runeLen <= limit: text else: text.runeSubStr(0, limit)

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked: a byte
  ## slice through a multi-byte character leaves invalid UTF-8 in the replay
  ## and breaks a strict JSON parser.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the FIRST balanced {...} object out of a model reply, tolerating
  ## a UTF-8 BOM, markdown fences and trailing prose. parseJson alone raises
  ## "EOF expected" on a valid object followed by a sentence, which would
  ## burn the single retry on a reply that was already good enough.
  var body = text.strip()
  if body.len >= 3 and body[0 .. 2] == "\xEF\xBB\xBF":
    body = body[3 .. ^1].strip()
  if body.startsWith("```"):
    let firstBreak = body.find('\n')
    if firstBreak >= 0:
      body = body[firstBreak + 1 .. ^1]
    let fence = body.rfind("```")
    if fence >= 0:
      body = body[0 ..< fence]
    body = body.strip()
  let start = body.find('{')
  if start < 0:
    let head = headRunes(body, 160)
    raise newException(HanabiError, "no JSON object in response: " &
      head.replace("\n", " "))
  var depth = 0
  var inString = false
  var escaped = false
  var stop = -1
  for index in start ..< body.len:
    let ch = body[index]
    if inString:
      if escaped:
        escaped = false
      elif ch == '\\':
        escaped = true
      elif ch == '"':
        inString = false
      continue
    case ch
    of '"': inString = true
    of '{': depth += 1
    of '}':
      depth -= 1
      if depth == 0:
        stop = index
    else: discard
    if stop >= 0:
      break
  if stop < 0:
    raise newException(HanabiError, "unbalanced JSON object in response")
  parseJson(body[start .. stop])

proc intFrom(node: JsonNode): int =
  ## An integer, a numeric string, or a rounded float; -1 when it is none of
  ## those (every caller range-checks anyway).
  if node.isNil:
    return -1
  case node.kind
  of JInt: node.getInt()
  of JFloat: int(node.getFloat())
  of JString:
    let text = node.getStr().strip()
    try: parseInt(text) except ValueError: -1
  else: -1

proc seatFrom(sim: Sim, node: JsonNode): int =
  ## A seat index, or a table alias (case-insensitive).
  if node.isNil:
    return -1
  if node.kind == JString:
    let text = cleanText(node.getStr(), MaxTargetLen).toLowerAscii()
    for seat, name in sim.names:
      if name.toLowerAscii() == text:
        return seat
    return intFrom(node)
  intFrom(node)

proc hintKindFrom(text: string): int =
  ## 0 = colour, 1 = rank, -1 = neither.
  case cleanText(text, MaxHintFieldLen).toLowerAscii()
  of "colour", "color", "suit": 0
  of "rank", "number", "value": 1
  else: -1

proc colourFrom(text: string): int =
  let want = cleanText(text, MaxHintFieldLen).toLowerAscii()
  let full = colourIndex(want)
  if full >= 0:
    return full
  if want.len == 1:
    for index, letter in ColourLetters:
      if letter.toLowerAscii() == want:
        return index
  -1

proc hintFromValue(target: int, raw: string, kind: int): Move =
  ## `kind` is 0 colour, 1 rank, -1 "infer from the shape of the value".
  let text = cleanText(raw, MaxHintFieldLen).strip()
  var wantRank = kind == 1
  if kind < 0:
    wantRank = text.len > 0 and text[0] in {'0' .. '9'}
  if wantRank:
    var rank = -1
    try: rank = parseInt(text) except ValueError: rank = -1
    if rank < 1 or rank > 5:
      raise newException(HanabiError, "a rank hint is 1..5, not \"" & text & "\"")
    return Move(kind: akHint, target: target, hintKind: hkRank, value: rank)
  let colour = colourFrom(text)
  if colour < 0:
    raise newException(HanabiError,
      "\"" & text & "\" is not one of red, yellow, green, blue, white")
  Move(kind: akHint, target: target, hintKind: hkColour, value: colour)

proc parseShortMove(sim: Sim, text: string): Move =
  ## {"move": "play 2"} / {"move": "discard 4"} / {"move": "hint 2 red"}.
  let parts = text.strip().toLowerAscii().split({' ', ',', ':'})
  var words: seq[string]
  for part in parts:
    if part.len > 0:
      words.add(part)
  if words.len == 0:
    raise newException(HanabiError, "empty move")
  case cleanText(words[0], MaxActionLen)
  of "play", "discard":
    if words.len < 2:
      raise newException(HanabiError, words[0] & " needs a slot")
    var slot = -1
    try: slot = parseInt(words[1]) except ValueError: slot = -1
    Move(kind: (if words[0] == "play": akPlay else: akDiscard), slot: slot,
      target: -1)
  of "hint", "tell", "clue":
    if words.len < 3:
      raise newException(HanabiError, "a hint needs a target and a value")
    let target = seatFrom(sim, %words[1])
    hintFromValue(target, words[2], -1)
  else:
    raise newException(HanabiError,
      "\"" & cleanText(words[0], MaxActionLen) &
      "\" is not play, discard or hint")

proc parseDecision*(sim: Sim, payload: JsonNode): Decision =
  ## Normalises a reply into the canonical move, or raises HanabiError with
  ## a reason specific enough to put in the retry prompt. Legality is NOT
  ## checked here — `legalMoves` is the one rule and the caller applies it.
  result.note = cleanText(payload{"note"}.getStr(), MaxNoteLen)
  result.banner = cleanText(payload{"banner"}.getStr(), MaxBannerLen)
    .replace("\n", " ").replace("\r", " ")
  let short = payload{"move"}
  if not short.isNil and short.kind == JString:
    result.move = parseShortMove(sim, short.getStr())
    return
  let actionNode = payload{"action"}
  if actionNode.isNil or actionNode.kind != JString:
    raise newException(HanabiError,
      "no \"action\" in the reply: it must be play, discard or hint")
  let action = cleanText(actionNode.getStr(), MaxActionLen).toLowerAscii()
  case action
  of "play", "discard":
    let slot = intFrom(payload{"slot"})
    result.move = Move(kind: (if action == "play": akPlay else: akDiscard),
      slot: slot, target: -1)
  of "hint", "tell", "clue":
    let target = seatFrom(sim, payload{"target"})
    if target < 0 or target >= Seats:
      raise newException(HanabiError,
        "\"target\" must be a seat number or a table name")
    var kind = -1
    let typeNode = payload{"hintType"}
    if not typeNode.isNil and typeNode.kind == JString:
      kind = hintKindFrom(typeNode.getStr())
      if kind < 0:
        raise newException(HanabiError,
          "\"hintType\" must be \"colour\" or \"rank\"")
    var value = payload{"hintValue"}
    if value.isNil:
      value = payload{"hint"}
    if value.isNil:
      raise newException(HanabiError,
        "a hint needs \"hintValue\": a colour name or a rank 1..5")
    let raw =
      if value.kind == JString: value.getStr()
      elif value.kind == JInt: $value.getInt()
      else: $value
    result.move = hintFromValue(target, raw, kind)
  else:
    raise newException(HanabiError,
      "\"" & action & "\" is not play, discard or hint")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a HanabiError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next turn.
  if error.len > 0:
    raise newException(HanabiError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = headRunes(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(HanabiError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(HanabiError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = headRunes(response.body, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(HanabiError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(HanabiError, "anthropic error " & $response.code &
      ": " & headRunes(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(HanabiError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens":
    let head = headRunes(result, 160).replace("\n", " ")
    if '{' notin result:
      raise newException(HanabiError, "reply cut off at max_tokens before " &
        "any JSON: " & head)
    ## The object started but the cap landed inside it. Name the cap as the
    ## cause here, so a log line separates a truncated reply from a model
    ## that genuinely emitted malformed JSON.
    try:
      discard extractJsonObject(result)
    except CatchableError:
      raise newException(HanabiError, "reply cut off at max_tokens " &
        "mid-JSON: " & head)

proc spaceRequests(client: LlmClient) =
  ## Hold consecutive request STARTS MinRequestSpacingSeconds apart.
  let wait = client.lastRequestAt + MinRequestSpacingSeconds - epochTime()
  if wait > 0.0:
    sleep(int(wait * 1000))
  client.lastRequestAt = epochTime()

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order — for Hanabi that list is
  ## always the single seat whose turn it is, so this is one request, at
  ## most one retry, then the scripted fallback. Never raises: any failure
  ## falls back to the `conventions` baseline so the episode always
  ## advances. `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  var rejects = newSeq[string](seats.len)
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skConventions else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was rejected: " &
          cleanText(rejects[index], MaxRejectLen) &
          ". Reply with ONLY one JSON object copied from the LEGAL MOVES " &
          "list.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    client.spaceRequests()
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var decision = parseDecision(sim, extractJsonObject(text))
        ## The legal-move list IS the rule: reject anything outside it here
        ## so the retry can quote exactly what was wrong.
        let reason = sim.illegalReason(decision.move)
        if reason.len > 0:
          raise newException(HanabiError, reason)
        decision.origin = if attempt == 0: "llm" else: "retry"
        result[index] = decision
      except CatchableError as error:
        echo "hanabi llm: seat ", seat, " attempt ", attempt, " rejected: ",
          error.msg
        rejects[index] = error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "hanabi llm: seat ", seat, " falling back to the conventions baseline"
    result[index] = scriptedAction(sim, seat, skConventions)
    result[index].origin = "fallback"
    result[index].reject = cleanText(rejects[index], MaxRejectLen)
