#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export VOICE_ROOT="$ROOT"

exec python3 - <<'PY'
import json
import os
import queue
import subprocess
import sys
import threading
import time

TIMEOUT_SECONDS = 180

process = subprocess.Popen(
    ["codex", "app-server"],
    cwd=os.environ["VOICE_ROOT"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

assert process.stdin is not None
assert process.stdout is not None
assert process.stderr is not None


def copy_stderr() -> None:
    for line in process.stderr:
        sys.stderr.write(line)
        sys.stderr.flush()


threading.Thread(target=copy_stderr, daemon=True).start()
output_lines = queue.Queue()


def collect_stdout() -> None:
    for line in process.stdout:
        output_lines.put(line)
    output_lines.put(None)


threading.Thread(target=collect_stdout, daemon=True).start()
deadline = time.monotonic() + TIMEOUT_SECONDS
agent_message_received = False


def send(message: dict[str, object]) -> None:
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def receive() -> dict[str, object]:
    global agent_message_received

    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError(f"codex app-server timed out after {TIMEOUT_SECONDS} seconds")

    try:
        line = output_lines.get(timeout=remaining)
    except queue.Empty as error:
        raise TimeoutError(
            f"codex app-server timed out after {TIMEOUT_SECONDS} seconds"
        ) from error
    if line is None:
        raise RuntimeError(
            f"codex app-server closed stdout with exit code {process.poll()}"
        )

    sys.stdout.write(line)
    sys.stdout.flush()
    message = json.loads(line)

    if message.get("method") == "item/agentMessage/delta":
        agent_message_received = True
    params = message.get("params")
    if isinstance(params, dict):
        item = params.get("item")
        if isinstance(item, dict) and item.get("type") == "agentMessage":
            agent_message_received = True

    return message


def wait_for_response(request_id: int) -> dict[str, object]:
    while True:
        message = receive()
        if message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(
                    f"request {request_id} failed: {json.dumps(message['error'])}"
                )
            return message


try:
    send(
        {
            "method": "initialize",
            "id": 1,
            "params": {
                "clientInfo": {"name": "voice", "version": "0.1"},
                "capabilities": {"experimentalApi": True},
            },
        }
    )
    wait_for_response(1)
    send({"method": "initialized", "params": {}})

    send(
        {
            "method": "thread/start",
            "id": 2,
            "params": {
                "model": "gpt-5.6-luna",
                "cwd": os.environ["VOICE_ROOT"],
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "developerInstructions": (
                    "Clean the supplied dictation and output only the cleaned text. "
                    "Do not use tools."
                ),
                "ephemeral": True,
                "dynamicTools": [],
            },
        }
    )
    thread_response = wait_for_response(2)
    result = thread_response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("thread/start returned no result object")
    if result.get("model") != "gpt-5.6-luna":
        raise RuntimeError("thread/start did not accept gpt-5.6-luna")
    if result.get("approvalPolicy") != "never":
        raise RuntimeError("thread/start did not disable approval prompts")
    sandbox = result.get("sandbox")
    if not isinstance(sandbox, dict) or sandbox.get("type") != "readOnly":
        raise RuntimeError("thread/start did not apply the read-only sandbox")
    thread_value = result.get("thread")
    if not isinstance(thread_value, dict) or not isinstance(
        thread_value.get("id"), str
    ):
        raise RuntimeError("thread/start returned no thread id")
    thread_id = thread_value["id"]

    send(
        {
            "method": "turn/start",
            "id": 3,
            "params": {
                "threadId": thread_id,
                "input": [
                    {
                        "type": "text",
                        "text": "um so the the test er passed I think",
                    }
                ],
                "effort": "none",
            },
        }
    )

    while True:
        message = receive()
        if message.get("id") == 3 and "error" in message:
            raise RuntimeError(
                f"turn/start failed: {json.dumps(message['error'])}"
            )
        if message.get("method") == "turn/completed":
            completed_params = message.get("params")
            completed_turn = (
                completed_params.get("turn")
                if isinstance(completed_params, dict)
                else None
            )
            if not isinstance(completed_turn, dict) or completed_turn.get(
                "status"
            ) != "completed":
                raise RuntimeError("turn/completed reported a failed turn")
            break

    if not agent_message_received:
        raise RuntimeError("turn completed without an agentMessage")
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
PY
