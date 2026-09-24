## Hanabi player: prompt, scripted, or external action policy.
##
## Prompt policies deliver PLAYER_PROMPT for the game's existing Claude
## adapter. PLAYER_JEV=1 receives seat observations and legal moves, calls
## System One here, and sends a normal action back to the game.
##
## PLAYER_SCRIPTED=conventions (or 1) registers the seat as the built-in
## convention-following baseline instead; PLAYER_SCRIPTED=cautious as the
## never-misplays baseline. The server plays those deterministically, no
## LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <hanabi-image> --name my-hanabi \
##     --run /bin/hanabi-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  hanabi/jev_policy,
  whisky

const DefaultPrompt = """
You cannot see your own cards; your partners can, and the only thing you
may send them is a hint. Before you move, read the move log and ask what
each hint your partners gave was FOR - a card to play now, or a card too
precious to discard. Only play a card when every candidate you hold for it
is playable right now; otherwise give a hint that makes a partner's card
playable this round, preferring the partner who acts next, or discard your
oldest unhinted card to buy a hint token back. Never discard a card whose
last copy is still in a hand, and never spend the last hint token on
information a partner already has. Keep one line per partner in your note:
what you have told them, and what you believe they are holding.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  var scripted = getEnv("PLAYER_SCRIPTED").strip()
  let jevRequested = getEnv("PLAYER_JEV") == "1"
  let jev = jevRequested and (
    getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("METTA_CAPTURE_URL").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0)
  if jevRequested and not jev:
    scripted = "conventions"
    echo "hanabi player: no Jev transport; using conventions"

  proc promptFrame(): string =
    if jev: $ %*{"type": "register", "control": "external"}
    else: $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "hanabi player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "hanabi player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""),
    (if jev: ", Jev choices" else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame, and mummy's send only
  ## QUEUES, so the game's quit(0) can outrun the flushed `final` frame and
  ## kill this container with status 1 through no fault of its own. A dead
  ## socket is a normal end of episode: exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "hanabi player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "hanabi player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "hanabi player: final score ", payload{"score"},
            " (", payload{"endReason"}.getStr(), ")"
          break
        of "observation":
          if jev:
            let action = chooseAction(payload["observation"],
              payload["legalMoves"], prompt)
            socket.send($ %*{"type": "action", "turn": payload["turn"],
              "action": action})
        else:
          discard
      except CatchableError as error:
        echo "hanabi player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "hanabi player: socket closed (", error.msg, "), exiting"
    quit(0)
  try:
    socket.close()
  except CatchableError:
    discard
