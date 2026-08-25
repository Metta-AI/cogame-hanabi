## Hanabi entrypoint: reads the Coworld runtime contract and starts the live
## episode server. There is no replay-server mode — hosted replays are served
## from the static wasm bundle, which is this game's only viewer path.

import
  std/[json, sysrand],
  bitworld/runtime,
  hanabi/server,
  hanabi/sim

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(HanabiError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()

  var config = defaultGameConfig()
  config.update(runtimeConfig.config)
  if not seedPinned(runtimeConfig.config):
    ## An unpinned seed is randomized so the deal and the aliases are not
    ## precomputable.
    config.seed = randomSeed()
    echo "hanabi: seed not pinned; randomized"
  ## Fit the cap AFTER the seed is settled, so a pinned seed reproduces
  ## the episode exactly.
  config = sampleEpisode(config)
  echo "hanabi: seats=", config.players.len,
    " maxTurns=", config.maxTurns,
    " seed=", config.seed
  runGameServer(config, runtimeConfig)
