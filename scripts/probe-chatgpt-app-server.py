#!/usr/bin/env python3
import json
import os
import selectors
import subprocess
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit("usage: probe-chatgpt-app-server.py <codex-binary> <output-jsonl>")

cli, output_path = sys.argv[1:3]
proc = subprocess.Popen(
    [cli, "app-server", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    env=os.environ.copy(),
)

sel = selectors.DefaultSelector()
sel.register(proc.stdout, selectors.EVENT_READ, "stdout")
sel.register(proc.stderr, selectors.EVENT_READ, "stderr")
transcript = []

def send(obj):
    line = json.dumps(obj, separators=(",", ":"))
    transcript.append({"send": obj})
    proc.stdin.write(line + "\n")
    proc.stdin.flush()

send({
    "id": 1,
    "method": "initialize",
    "params": {
        "clientInfo": {
            "name": "chatgpt-high-sierra-probe",
            "title": "ChatGPT High Sierra Probe",
            "version": "1.0.0",
        },
        "capabilities": {
            "experimentalApi": True,
            "requestAttestation": False,
        },
    },
})

initialized = False
requirements = None
deadline = time.time() + 30

try:
    while time.time() < deadline and proc.poll() is None:
        for key, _ in sel.select(timeout=0.5):
            line = key.fileobj.readline()
            if not line:
                continue
            if key.data == "stderr":
                transcript.append({"stderr": line.rstrip()})
                continue

            transcript.append({"stdout": line.rstrip()})
            try:
                msg = json.loads(line)
            except Exception:
                continue

            if msg.get("id") == 1:
                if "error" in msg:
                    raise RuntimeError("initialize error: " + json.dumps(msg))
                initialized = True
                send({"id": 2, "method": "configRequirements/read"})
            elif msg.get("id") == 2:
                if "error" in msg:
                    raise RuntimeError("configRequirements/read error: " + json.dumps(msg))
                requirements = msg.get("result")
                break
        if requirements is not None:
            break
finally:
    with open(output_path, "w", encoding="utf-8") as f:
        for row in transcript:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")

if not initialized:
    raise SystemExit("bundled Codex app-server did not initialize")
if requirements is None:
    raise SystemExit("bundled Codex app-server did not answer configRequirements/read")

print("bundled_app_server_initialize=pass")
print("bundled_app_server_config_requirements_read=pass")
print("configRequirements/read:", json.dumps(requirements, sort_keys=True))

proc.terminate()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait(timeout=5)
