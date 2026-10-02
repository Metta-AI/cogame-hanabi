## Authoritative private language decisions; spectator replay stays separate.
import std/[json, options]
import bitworld/decision_trajectory
import llm, sim

proc decisionAction*(decision: Decision): JsonNode =
  result = moveJson(decision.move)
  result["note"] = %decision.note
  result["banner"] = %decision.banner

proc recordAppliedDecision*(trajectory: DecisionTrajectory, before: Sim,
    seat: int, proposed, applied: Decision, operatorPrompt: string,
    terminal: bool) =
  let actualAction = applied.decisionAction()
  var attempts = proposed.nativeAttempts
  var selected = none(string)
  let fallback = applied.origin == "fallback"
  if not fallback and attempts.len == 0:
    let origin = if applied.origin == "scripted": aoTeacher else: aoUnknown
    var evidence = newDecisionAttempt("turn-" & $before.turn & "-applied",
      if origin == aoTeacher: applied.policy else: "external-hanabi", origin)
    evidence.prompt = %*[{"role": "system", "content": systemPrompt(before, seat)},
      {"role": "user", "content": userPrompt(before, seat, operatorPrompt)}]
    evidence.response = %($actualAction)
    evidence.parsedAction = actualAction
    evidence.accepted = true
    attempts.add(evidence)
  for index in 0 ..< attempts.len:
    if fallback and attempts[index].accepted:
      attempts[index].accepted = false
      attempts[index].rejectionReason = some(applied.reject)
    elif attempts[index].accepted:
      selected = some(attempts[index].attemptId)
  trajectory.recordDecision("hanabi-" & $before.turn, $seat,
    before.playerFrameJson(seat, true), attempts, selected, actualAction,
    if fallback: asFallback else: asAccepted, terminal = terminal,
    fallbackOrigin = if fallback: some("scripted-conventions") else: none(string))
