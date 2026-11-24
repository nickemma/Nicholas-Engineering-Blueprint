"""A loopback stand-in for the serving lab's model endpoints."""

import json
import os
import secrets
import select
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from urllib.request import ProxyHandler, Request, build_opener


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 32768:
                raise ValueError
            request = json.loads(self.rfile.read(length))
        except (ValueError, OSError):
            self.send_error(400)
            return
        if self.path == "/apply-template" and request.get("add_generation_prompt") is True:
            self.send_json({"prompt": "fixture/chat"})
        elif self.path == "/tokenize" and request.get("content") == "fixture/chat" and request.get("add_special") is True:
            self.send_json({"tokens": [10, 20, 30]})
        elif self.path == "/v1/chat/completions" and request.get("stream_options") == {"include_usage": True}:
            body = (
                b'data: {"choices":[{"delta":{"content":"river"}}]}\n\n'
                b'data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1}}\n\n'
                b'data: [DONE]\n\n'
            )
            self.reply("text/event-stream", body)
        else:
            self.send_error(400)

    def send_json(self, body):
        self.reply("application/json", json.dumps(body).encode())

    def reply(self, content_type, body):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


def smoke(binary):
    with ThreadingHTTPServer(("127.0.0.1", 0), Model) as model:
        thread = Thread(target=model.serve_forever, daemon=True)
        thread.start()
        first, second = secrets.token_hex(24), secrets.token_hex(24)
        env = dict(os.environ, GATEWAY_MODEL_ADDR=f"127.0.0.1:{model.server_port}",
                   GATEWAY_LISTEN="127.0.0.1:0", GATEWAY_A_TOKEN=first, GATEWAY_B_TOKEN=second)
        try:
            with subprocess.Popen([str(Path(binary).resolve())], env=env, stderr=subprocess.PIPE, text=True) as child:
                try:
                    if not select.select([child.stderr], [], [], 5)[0]:
                        raise AssertionError("gateway listener did not start")
                    _, marker, address = child.stderr.readline().strip().partition("listening on ")
                    assert marker and address.startswith("127.0.0.1:")
                    body = {"messages": [{"role": "user", "content": "fixture"}], "max_tokens": 4, "stream": True}
                    request = Request(f"http://{address}/v1/chat/completions", json.dumps(body).encode(),
                                      headers={"Content-Type": "application/json", "Authorization": f"Bearer {first}"})
                    with build_opener(ProxyHandler({})).open(request, timeout=4) as response:
                        assert response.status == 200 and response.headers.get_content_type() == "text/event-stream"
                        output = response.read(4096)
                    assert b'"content":"river"' in output and b'"prompt_tokens":3' in output
                    assert output.endswith(b"data: [DONE]\n\n")
                    print("CLI smoke: template, tokenization, content, usage, and terminal event passed", flush=True)
                finally:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
        finally:
            model.shutdown()
            thread.join(timeout=5)


if __name__ == "__main__":
    if sys.argv[1] == "--serve":
        with ThreadingHTTPServer(("127.0.0.1", 0), Model) as model:
            print(f"model fixture at 127.0.0.1:{model.server_port}", flush=True)
            try:
                model.serve_forever()
            except KeyboardInterrupt:
                pass
    else:
        smoke(sys.argv[1])
