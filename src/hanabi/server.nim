## Hanabi game server: implements the Coworld game contract.
##
## Endpoints (every one registered BEFORE any catch-all asset route, because
## hosted certification probes /healthz, /client/player, a bad-token player
## websocket and /client/global before the player pods start):
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/renderer.js         - shared table renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##
## There is NO replay route and no replay-server mode: hosted replays are
## served from the static wasm bundle (replay-viewer/, built by
## tools/build_replay_viewer.sh), which is the only viewer path this game has.
##
## Player protocol (hanabi.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","protocol":"hanabi.player.v1",...}
##                   {"type":"state",...} after every event, REDACTED to the
##                   seat: its own hand appears as knowledge only, and no
##                   other seat's note, banner or policy name is in it
##                   {"type":"final","scores":[...],"fireworks":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"conventions"}
##                   (max 4000 runes; scripted plays a built-in baseline for
##                   that seat: "conventions" / "1", or "cautious")

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  TurnReserveSeconds* = 45.0
    ## Checked BEFORE every turn's decision: attempt 0 (20 s) + attempt 1
    ## (20 s) + the request-spacing floor (2 s) + apply/broadcast/pacing.
    ## Play therefore never crosses the play budget even when every single
    ## request times out and retries.
  ShutdownGraceSeconds* = 20
    ## The certifier pings /global with a 2 s deadline AFTER the player pods
    ## start, and a fast scripted episode has already written its artifacts
    ## by then — so keep answering for a while before quitting.

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the alias.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.frameJson()
  result["type"] = %"state"
  result["game"] = %"hanabi"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Redacted to the seat: the observation text is exactly what that seat
  ## may know — its own hand as knowledge only, never as identities — and it
  ## carries no other seat's note or banner and no policy name. Decisions
  ## are server-side, so this loses the policy nothing. The frame is built
  ## in the pure sim module so tests/test_prompt.nim can assert the
  ## redaction on the same code path the socket uses.
  gs.sim.playerFrameJson(slot, gs.started)

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table (every hand
  ## face-up); players get the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## hanabi.replay.v1, built in the pure sim module so the same bytes the
  ## platform stores are the ones tests/test_replay.nim re-reads.
  var policyNames: seq[string]
  for player in gs.config.players:
    policyNames.add(player.name)
  $gs.sim.replayJson(results, policyNames)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "score": results["score"],
      "fireworks": results["fireworks"],
      "names": aliasNames,
      "turns": results["turns"],
      "endReason": results["endReason"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "hanabi: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Keep /healthz and /global answering for a while after the artifacts
  ## land: the certifier probes them after the player pods start, and a
  ## fast scripted episode would otherwise already be gone.
  echo "hanabi: episode complete; serving for another ",
    ShutdownGraceSeconds, "s before shutting down"
  sleep(ShutdownGraceSeconds * 1000)
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "hanabi: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its
    ## own worker sidecar, NOT to the game container, so when the env is
    ## silent assume the configured platform default rather than playing
    ## open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "hanabi: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and
            epochTime() + TurnReserveSeconds > playDeadline:
          ## The platform kills an episode that outruns its timeout and
          ## keeps nothing at all, so give up turns rather than the whole
          ## result: stop here, between turns, with the stacks as they
          ## stand.
          echo "hanabi: episode deadline reached after ", state.sim.turn,
            "/", config.maxTurns, " turns; ending early"
          if state.sim.turn == 0:
            ## The connect wait ate the budget. Play the whole episode on
            ## the scripted baseline (no LLM, milliseconds) so the replay is
            ## never empty.
            echo "hanabi: no turn was played; running the conventions " &
              "baseline for the whole episode"
            while not state.sim.done:
              let seat = state.sim.pendingSeats()[0]
              let decision = scriptedAction(state.sim, seat, skConventions)
              state.sim.applyMove(seat, decision.move, "", "", "scripted")
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        echo "hanabi: turn ", state.sim.turn, " of ", config.maxTurns,
          ", seat ", seats[0], " (", state.sim.names[seats[0]], ") at ",
          (epochTime() - gameStart).int, "s"

      ## The slow part (Claude, one request for the acting seat) runs
      ## outside the lock on a snapshot; only this thread mutates the sim,
      ## so the snapshot cannot go stale.
      let decisions = client.decideAll(simCopy, seats, prompts, scripted)

      withLock stateLock:
        for index, seat in seats:
          let decision = decisions[index]
          echo "hanabi: turn ", state.sim.turn, " ", state.sim.names[seat],
            " ", moveText(decision.move), " (", decision.origin, ")",
            (if decision.reject.len > 0: " after: " & decision.reject
             else: "")
          try:
            state.sim.applyMove(seat, decision.move, decision.note,
              decision.banner, decision.origin)
          except HanabiError as error:
            ## Belt and braces: the decision path already validated against
            ## legalMoves, so this can only fire if the two disagree.
            echo "hanabi: move rejected (", error.msg,
              "); using the conventions baseline"
            let fallback = scriptedAction(state.sim, seat, skConventions)
            state.sim.applyMove(seat, fallback.move, "", "", "fallback")
        state.broadcastLocked()

      ## Pace between turns so spectators can read the table.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "hanabi: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "hanabi.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "seats": Seats,
        "handSize": HandSize,
        "maxTurns": state.config.maxTurns
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skConventions
              else: skNone)
            else: parseScriptKind(node.getStr())
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
          echo "hanabi: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted != skNone: ", scripted " & $scripted else: ""), ")"
      except CatchableError as error:
        echo "hanabi: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(HanabiError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "hanabi: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
