#!/usr/bin/env python3
"""Scripted OpenAI-compatible chat-completions server (SCRIPTED TEST MODEL, not a real model) for the fx hook review fixes.

Never contacts the network. Each reply asks fx for the next scripted tool call; the attacks come from the
security review of the fx hook (startup-file poisoning, swapping the policy or binaries, tty, reload, fx's own
network tools). Usage: fake_model_steps.py PORT LOGFILE STEPS_JSON (a list of [tool, args])
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG, STEPS_FILE = int(sys.argv[1]), sys.argv[2], sys.argv[3]


STEPS = [tuple(x) for x in json.load(open(STEPS_FILE))]

def log(obj):
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj)[:40000] + "\n")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "fake-model", "object": "model"}]})
        else:
            self._json(404, {"error": "not found"})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try: req = json.loads(raw)
        except Exception: req = {}
        msgs = req.get("messages", [])
        tools = [t.get("function", {}).get("name") for t in req.get("tools", []) if isinstance(t, dict)]
        results = [m for m in msgs if m.get("role") == "tool"]
        step = len(results)
        log({"step": step, "tools": tools, "tool_results": [str(m.get("content"))[:900] for m in results]})
        if step < len(STEPS):
            name, args = STEPS[step]
            call = {"id": "call_%d" % (step + 1), "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
            message, finish = {"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls"
        else:
            message, finish = {"role": "assistant", "content": "PROBE DONE"}, "stop"
        created, model = int(time.time()), req.get("model", "fake-model")
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.end_headers()
            base = {"id": "chatcmpl-probe", "object": "chat.completion.chunk", "created": created, "model": model}
            delta = {"role": "assistant"}
            if message.get("tool_calls"):
                tc = dict(message["tool_calls"][0]); tc["index"] = 0; delta["tool_calls"] = [tc]
            else:
                delta["content"] = message["content"]
            for chunk in ({**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                          {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]},
                          {**base, "choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}):
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        else:
            self._json(200, {"id": "chatcmpl-probe", "object": "chat.completion", "created": created, "model": model,
                             "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                             "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
