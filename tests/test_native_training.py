"""Probe actual native game clients with retries and consumed fallbacks."""

import json
import os
import subprocess
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GAME = "hanabi"
root = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix=GAME + "-native-") as temporary:
    binary = Path(temporary) / "probe"
    command = [os.environ.get("NIM", "nim"), "c", "--path:src", "--out:" + str(binary)]
    if os.environ.get("NIM_TRAINING_FLAGS"):
        command += Path(os.environ["NIM_TRAINING_FLAGS"]).read_text().splitlines()
    command += ["tools/ci/native_training_probe.nim"]
    subprocess.run(command, cwd=root, check=True, capture_output=True, text=True)
    for scenario in ["retry", "fallback"]:
        calls = []

        class NativeHandler(BaseHTTPRequestHandler):
            captured_calls = calls
            case = scenario

            def do_POST(self):
                assert self.path == "/v1/messages"
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.headers["X-Coworld-Player-Slot"] == "0"
                assert request["model"] == "checkpoint/native-fixture"
                assert request["temperature"] == 0
                assert "Exact private operator prompt" in request["messages"][0]["content"]
                if self.captured_calls:
                    assert "previous reply" in request["messages"][0]["content"]
                raw = (
                    '{"action":"hint","target":0,"hintType":"rank","hintValue":1}'
                    if GAME == "hanabi"
                    else '{"move":"not-a-move"}'
                )
                if self.captured_calls and self.case == "retry":
                    raw = (
                        '{"move":"play 1"}'
                        if GAME == "hanabi"
                        else '{"move":"A","notes":"private memory","say":"public line"}'
                    )
                call_id = str(uuid.uuid4())
                self.captured_calls.append((request, call_id, raw))
                body = json.dumps(
                    {
                        "id": call_id,
                        "model": request["model"],
                        "content": [{"type": "text", "text": raw}],
                        "stop_reason": "end_turn",
                        "usage": {"input_tokens": 3, "output_tokens": 2},
                        "sampling_evidence": {
                            "prompt_token_ids": [10, 11],
                            "completion_token_ids": [12],
                            "behavior_log_probs": None,
                            "stop_reason": "eos",
                            "sampling": "greedy",
                        },
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Softmax-Llm-Call-Id", call_id)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), NativeHandler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            endpoint = "http://127.0.0.1:" + str(server.server_port)
            result = subprocess.run(
                [str(binary), endpoint, scenario],
                cwd=root,
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert result.returncode == 0, result.stderr
            events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
            decision = events[0]
            assert decision["action_status"] == ("accepted" if scenario == "retry" else "fallback")
            assert len(decision["attempts"]) == len(calls) == 2
            for attempt, (request, call_id, raw) in zip(decision["attempts"], calls, strict=True):
                assert attempt["request"] == request
                assert attempt["platform_call_id"] == call_id
                assert attempt["prompt_token_ids"] == [10, 11]
                assert attempt["sampled_token_ids"] == [12]
                assert attempt["behavior_logprobs"] is None
                assert attempt["raw_response"]["content"][0]["text"] == raw
                assert attempt["prompt"][1]["content"] == request["messages"][0]["content"]
            if scenario == "retry":
                assert decision["selected_attempt_id"] == decision["attempts"][1]["attempt_id"]
                assert decision["executed_action"] == decision["attempts"][1]["parsed_action"]
            else:
                assert decision["selected_attempt_id"] is None
                assert decision["fallback_origin"].startswith("scripted-")
            assert events[-1]["status"] == "truncated"
            print(GAME, scenario, "native payload/private attempt/action joins passed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(5)
            assert not thread.is_alive()
