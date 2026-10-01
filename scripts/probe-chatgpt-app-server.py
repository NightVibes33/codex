#!/usr/bin/env python3
import json
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: probe-chatgpt-app-server.py <codex-binary> <output-jsonl>")

cli, output_path = sys.argv[1:3]
proc = subprocess.Popen(
    [cli, "app-server"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

requests = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"clientInfo": {"name": "high-sierra-verify", "version": "1.0.0"}},
    },
    {"jsonrpc": "2.0", "method": "initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "configRequirements/read"},
]
payload = "\n".join(json.dumps(item, separators=(",", ":")) for item in requests) + "\n"

try:
    stdout, stderr = proc.communicate(payload, timeout=20)
except subprocess.TimeoutExpired:
    proc.kill()
    stdout, stderr = proc.communicate()
    print("app-server probe timed out", file=sys.stderr)
    if stderr:
        print(stderr[-4000:], file=sys.stderr)
    raise SystemExit(1)

with open(output_path, "w", encoding="utf-8") as f:
    f.write(stdout)

if stdout:
    print(stdout, end="" if stdout.endswith("\n") else "\n")
if stderr:
    print(stderr[-4000:], file=sys.stderr)

responses = {}
for line in stdout.splitlines():
    try:
        message = json.loads(line)
    except Exception:
        continue
    if "id" in message:
        responses[str(message["id"])] = message

initialize = responses.get("1")
requirements = responses.get("2")
if not initialize or "result" not in initialize:
    raise SystemExit("initialize did not return a result")
if not requirements or "result" not in requirements:
    raise SystemExit("configRequirements/read did not return a result")

print("bundled_app_server_startup_gate=pass")
