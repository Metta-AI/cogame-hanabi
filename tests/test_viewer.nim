## Chrome invariants. The viewer chrome is INHERITED from
## Metta-AI/cogame-bullwhip: chrome.css is that file byte for byte with one
## appended game block, and the pages are that starter's pages with two
## appended elements and nothing removed. These are the checks that catch a
## rewrite-that-reuses-the-ids (cogame-gridlock, 2026-08-23), a shadowed
## game-block builder (tandem, 2026-08-23) and a beat kind with no CSS.

import std/[json, os, sequtils, sets, sha1, strutils, unittest]

const RepoDir = currentSourcePath().parentDir().parentDir()

## SHA-1 of client/chrome.css in Metta-AI/cogame-bullwhip as mounted when
## this game was forked (11,964 bytes). Everything before the appended
## `/* ---------- Hanabi ---------- */` marker must still hash to this: the
## file's convention is to accrete one appended block per game, never to
## edit a rule above.
const InheritedChromeSha1 = "8f0d16397cb227a427ec1112d39c180f1aef1bfd"
const InheritedChromeBytes = 11964
const HanabiMarker = "/* ---------- Hanabi ---------- */"

## Every element the starter's replay page ships. None may be removed.
const StarterIds = ["layout", "stage", "topband", "wordmark", "clock",
  "topright", "statuschip", "feedtoggle", "scorebug", "board-wrap", "table",
  "lightpool", "grain", "endscreen", "transport", "scrub", "play", "pos",
  "feed", "loading"]

proc read(path: string): string =
  readFile(RepoDir / path)

suite "chrome.css is the starter's file plus one appended block":
  test "the inherited prefix is byte-identical":
    let css = read("client/chrome.css")
    let marker = css.find(HanabiMarker)
    check marker > 0
    check css.count(HanabiMarker) == 1
    let inherited = css[0 ..< marker].strip(leading = false,
      trailing = true) & "\n"
    check inherited.len == InheritedChromeBytes
    check toLowerAscii($secureHash(inherited)) == InheritedChromeSha1

  test "the appended block carries the game's own rules":
    let css = read("client/chrome.css")
    let appended = css[css.find(HanabiMarker) .. ^1]
    for selector in ["#tokenbar", ".tok-score", ".tok-hint", ".tok-fuse",
        ".tok-deck", ".tok-pip", ".tok-pip.spent", ".tok-fuse.blown",
        "#hintpane", ".hp-head", ".hp-line", ".hp-line.playable",
        ".hp-line.dead", ".hp-line.critical", ".hp-line.negative",
        ".plate-plays", ".plate-misplays", ".plate-fallback",
        "button.beat-marker", "--band", "--hudscale"]:
      check selector in appended
    ## The caption never sits over the transport band.
    check "#loading { bottom: var(--band); }" in appended
    ## The scorebug stays legible in a 360px iframe.
    check "min-width: 3.2em" in css
    check "flex: 1 1 auto" in css
    check "@media (max-width: 560px)" in appended
    check "@media (max-width: 720px)" in appended
    check "@media (max-width: 420px)" in appended

suite "the pages are the starter's pages":
  test "every starter element survives, with its id, on both pages":
    for path in ["replay-viewer/index.html",
        "tools/ci/renderer_fixture.html"]:
      let page = read(path)
      for id in StarterIds:
        check ("id=\"" & id & "\"") in page
      ## The two appended elements, and nothing else added.
      check "id=\"tokenbar\"" in page
      check "id=\"hintpane\"" in page
      ## Zoom is dropped entirely: the table always fits the frame.
      check "viewpanel" notin page
      ## --band and --hudscale are set on the ROOT, from the measured
      ## transport height, and fit() runs from the same function.
      check "relayout" in page
      check "document.documentElement" in page
      check "--band" in page
      check "--hudscale" in page

  test "the replay pages carry the fork's own wordmark and renderer":
    ## There is exactly ONE replay page: the static wasm bundle's. The pod
    ## has no /client/replay route and no page behind it (r1 review F3).
    for path in ["replay-viewer/index.html"]:
      let page = read(path)
      check "HANA<span>BI</span>" in page
      check "HanabiRenderer" in page
      check "BULLWHIP" notin page
    let bundle = read("replay-viewer/index.html")
    check "./hanabi_replay.js" in bundle
    check "./static_replay.js" in bundle
    check "./chrome.css" in bundle
    check "./renderer.js" in bundle

  test "the pod serves no replay path at all":
    ## The static bundle is the ONLY viewer path: no /client/replay route,
    ## no page behind it, no /replay websocket and no replay-server mode.
    check not fileExists(RepoDir / "client/replay.html")
    let server = read("src/hanabi/server.nim")
    check "/client/replay" notin server
    check "\"/replay\"" notin server
    check "runReplayServer" notin server
    check "replayMode" notin read("src/hanabi.nim")

suite "the renderer's game block":
  test "no top-level name is defined twice":
    ## The tandem failure was a game-block `function markBeat` hoisted over
    ## the chrome's own alias of the same name. Nothing in this file may
    ## declare the same top-level name twice, and the game-block builders
    ## carry their own names.
    let renderer = read("client/renderer.js")
    var names: seq[string]
    for line in renderer.splitLines():
      if not line.startsWith("  function "):
        continue
      let rest = line["  function ".len .. ^1]
      names.add(rest[0 ..< rest.find('(')])
    check names.len > 20
    check names.toHashSet().len == names.len
    check "markHanabiBeat" in names
    check "buildHanabiHintPane" in names
    check "markBeat" notin names
    check "viewpanel" notin renderer

  test "every beat kind the renderer emits has a CSS rule":
    let renderer = read("client/renderer.js")
    let css = read("client/chrome.css")
    var kinds: seq[string]
    let parts: seq[string] = renderer.split("kind: \"")
    for index in 1 ..< parts.len:      ## parts[0] is the head of the file
      kinds.add(parts[index][0 ..< parts[index].find('"')])
    ## The deck-out beat is passed positionally, not as a record.
    kinds.add("deckout")
    check kinds.toHashSet().len == 7
    for kind in kinds.deduplicate():
      check (".beat-marker." & kind) in css
    for kind in ["hint", "play", "stack5", "misplay", "discard", "deckout",
        "end"]:
      check kind in kinds
    ## Beats are labelled, clickable buttons that seek.
    check "document.createElement(\"button\")" in renderer
    check "aria-label" in renderer
    check "marker.onclick" in renderer

  test "replay playback pauses on Space and offers a half-speed chip":
    ## Both live in attachReplay, so the static bundle, the CI fixture and
    ## any future replay surface inherit them from the one renderer.
    let renderer = read("client/renderer.js")
    let css = read("client/chrome.css")
    check "[0.5, 1, 2].forEach" in renderer
    check "stepMs / speed" in renderer
    check "evt.code !== \"Space\"" in renderer
    check "evt.preventDefault()" in renderer
    ## Typing somewhere must not toggle playback.
    check "t.tagName === \"TEXTAREA\"" in renderer
    check "t.isContentEditable" in renderer
    ## The chips are styled, and only in the appended game block.
    let appended = css[css.find(HanabiMarker) .. ^1]
    check ".tchip.on" in appended
    check ".tspeed" in appended

suite "packaging agrees with itself":
  test "the manifest image placeholder matches the compose service":
    let compose = read("compose.yaml")
    let manifest = parseJson(read("coworld_manifest_template.json"))
    check "  hanabi:" in compose
    check "image: coworld-hanabi:latest" in compose
    check "platform: linux/amd64" in compose
    check manifest["game"]["runnable"]["image"].getStr() == "{{HANABI_IMAGE}}"
    check manifest["game"]["name"].getStr() == "hanabi"
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    ## num_agents in EVERY variant and in the certification fixture.
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 4
      check variant.hasKey("description")
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 4
    check manifest["certification"]["players"].len == 4
    ## Both protocols, each a {"type":"text","value":...} object.
    for key in ["player", "global"]:
      check manifest["game"]["protocols"][key]["type"].getStr() == "text"
      check manifest["game"]["protocols"][key]["value"].getStr().len > 100
    check manifest["game"]["docs"]["readme"]["type"].getStr() == "text"
    var pages: seq[string]
    for page in manifest["game"]["docs"]["pages"]:
      pages.add(page["id"].getStr())
      check page["content"]["type"].getStr() == "text"
    check pages == @["rules.md", "hints-and-knowledge.md"]
    ## The secret the hosted container needs.
    check manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"]
      .getStr() == "secret://coworld/hanabi/anthropic_api_key"

  test "the CI scaffold is present, executable and unsubstituted-free":
    for path in [".github/workflows/ci.yml",
        ".github/workflows/coworld-release.yml",
        ".github/workflows/coworld-submit.yml", "tools/ci/docker_smoke.sh",
        "tools/ci/viewer_smoke.mjs", "tools/ci/policies.json",
        "tools/ci/renderer_fixture.html", "tools/build_replay_viewer.sh"]:
      check fileExists(RepoDir / path)
    for path in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"]:
      check fpUserExec in getFilePermissions(RepoDir / path)
    for path in [".github/workflows/ci.yml",
        ".github/workflows/coworld-release.yml",
        ".github/workflows/coworld-submit.yml", "tools/ci/docker_smoke.sh",
        "tools/ci/policies.json"]:
      let text = read(path)
      check "<slug>" notin text
      check "<IMAGE>" notin text
      check "<SEATS>" notin text
    ## Two prompt champions and two scripted fillers, all one image.
    let policies = parseJson(read("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripts = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/hanabi-player"
      if policy["env"].hasKey("PLAYER_PROMPT"):
        prompts += 1
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        scripts += 1
    check prompts == 2
    check scripts == 2
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
