import std/[json, strutils]

type
  HanabiError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    maxTurns*: int        ## hard cap on turns played
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Card* = object
    ## colour 0..4 in deck order, rank 1..5. rank 0 means "no card".
    colour*, rank*: int

  ActionKind* = enum
    akPlay = "play"
    akDiscard = "discard"
    akHint = "hint"

  HintKind* = enum
    hkColour = "colour"
    hkRank = "rank"

  Move* = object
    kind*: ActionKind
    slot*: int          ## play/discard: 1-based slot
    target*: int        ## hint: the receiving seat
    hintKind*: HintKind ## hint: colour or rank
    value*: int         ## hint: colour index (hkColour) or rank (hkRank)

  SeatStat* = object
    plays*, misplays*, discards*, hints*, fallbacks*: int

  EventKind* = enum
    evStart = "start"
    evMove = "move"
    evEnd = "end"

  GameEvent* = object
    ## One flat record per logged moment. `start` opens the log, `move` is
    ## one turn, `end` closes the episode; nothing else is recorded, and the
    ## per-turn state is re-derived rather than stored.
    kind*: EventKind
    turn*: int            ## move: the turn; end: turns played; start: -1
    seat*: int            ## move: the acting seat; -1 otherwise
    action*: string       ## move: play | discard | hint
    slot*: int            ## move play/discard: 1-based slot; 0 otherwise
    card*: Card           ## move play/discard: the revealed card (rank 0 = none)
    target*: int          ## move hint: the receiving seat; -1 otherwise
    hintType*: string     ## move hint: colour | rank
    hintValue*: string    ## move hint: a colour name or a rank numeral
    touched*: seq[int]    ## move hint: slots the hint marked
    untouched*: seq[int]  ## move hint: the receiver's other slots
    learned*: seq[string] ## what the receiver can now infer, in words
    nowPlayable*: seq[int]
    nowDead*: seq[int]
    nowCritical*: seq[int]
    outcome*: string      ## move: stack | misplay | discarded | hint
    fizzle*: bool         ## move: a misplay burned a fuse
    hintTokens*: int      ## move: public counters after the move
    fuses*: int
    deck*: int
    countdown*: int
    score*: int
    origin*: string       ## move: llm | retry | fallback | scripted
    scripted*: bool       ## move: decided without the model
    text*: string         ## move: the seat's note; end: reason; start: "hanabi"
    banner*: string       ## move: the seat's spectator-only line
    endReason*: string    ## end: perfect|strikeout|deckout|turnlimit|deadline
    fireworks*: seq[int]  ## end: the five stack heights
    digest*: string       ## end: FNV-1a 64 of the final state
    seed*: int            ## start
    seats*: int           ## start
    handSize*: int        ## start
    maxTurns*: int        ## start

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    maxTurns: 80,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 150,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 800,
    llmTimeoutSeconds: 20
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(HanabiError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("maxTurns"):
    config.maxTurns = node["maxTurns"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.maxTurns < 4:
    raise newException(HanabiError, "maxTurns must be at least 4")
