## Authoritative private language decisions; spectator replay stays separate.
import std/[json, options]
import bitworld/decision_trajectory
import llm, sim, prompts

proc decisionAction*(decision: Decision): JsonNode =
  result = moveJson(decision.move)
  result["note"] = %decision.note
  result["banner"] = %decision.banner

proc recordAppliedDecision*(trajectory: DecisionTrajectory, before: Sim,
    seat: int, proposed, applied: Decision, operatorPrompt: string,
    terminal: bool, selection: PromptSelection) =
  let actualAction = applied.decisionAction()
  var attempts = proposed.nativeAttempts
  var selected = none(string)
  let fallback = applied.origin == "fallback"
  if not fallback and attempts.len == 0:
    let origin = if applied.origin == "scripted": aoTeacher else: aoUnknown
    var evidence = newDecisionAttempt("turn-" & $before.turn & "-applied",
      if origin == aoTeacher: applied.policy else: "external-hanabi", origin)
    evidence.prompt = %*[{"role": "system", "content": systemPrompt(before, seat, selection)},
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
  var observation = before.playerFrameJson(seat, true)
  observation["operator_prompt"] = %operatorPrompt
  observation["prompt_selection"] = selection.selectionMetadata()
  var metadata = newJArray()
  for attempt in attempts:
    if attempt.origin in {aoModel, aoTeacher}:
      metadata.add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": selection.promptMetadata(
          attempt.prompt[0]["content"].getStr(), attempt.prompt[1]["content"].getStr())})
  observation["prompt_attempts"] = metadata
  trajectory.recordDecision("hanabi-" & $before.turn, $seat,
    observation, attempts, selected, actualAction,
    if fallback: asFallback else: asAccepted, terminal = terminal,
    fallbackOrigin = if fallback: some("scripted-conventions") else: none(string))
