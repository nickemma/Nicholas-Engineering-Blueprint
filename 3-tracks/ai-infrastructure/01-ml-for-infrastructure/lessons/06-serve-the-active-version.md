# 06 Serve the active version

> ML for infrastructure · Week 3

## The problem

The serving path can drift away from training if they transform inputs differently. A rollback also needs to change the version actually answering requests.

## The mental model

~~~text
POST /predict → admission feature contract → active artifact → runtime, artifact ID
~~~

## The pattern

Accept only the admission fields and share the same feature projection and scale as offline prediction. Read the active alias on each request and reload verified weights when its version changes. Send the artifact ID with the estimate so you can trace it. The loopback server returns 400 for a malformed request and 503 when a prediction is unavailable.

## Build it

### Expose one bounded prediction route

Keep the handler local, bound its body and socket wait, and reuse the released Predictor.

Create `ml_lab/serve.py`.

<!-- file: ml_lab/serve.py -->
~~~python
"""Bounded loopback prediction endpoint with a version in every response."""

import json
import math
from functools import partial
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer

from .contract import ContractError, Features
from .model import Predictor, configure_cpu
from .registry import Registry


class Service:
    def __init__(self, registry: Registry) -> None:
        self.registry = registry
        self.active = None
        self.model = None

    def predict(self, body: object) -> dict:
        features = Features.parse(body)
        active = self.registry.state()["active"]
        if active is None:
            raise ValueError("no active artifact")
        if self.active != active:
            meta, weights = self.registry.artifact(active)
            self.model = Predictor.from_artifact(meta, weights)
            self.active = active
        runtime = self.model.predict([features])[0]
        if not math.isfinite(runtime):
            raise ValueError("nonfinite prediction")
        return {"artifact": self.active, "runtime_ms": runtime}


class Handler(BaseHTTPRequestHandler):
    def __init__(self, *args, service: Service, **kwargs) -> None:
        self.service = service
        super().__init__(*args, **kwargs)

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(2)

    def do_POST(self) -> None:
        if self.path != "/predict":
            self.reply(HTTPStatus.NOT_FOUND, {"error": "route not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 1024 or self.headers.get("Transfer-Encoding"):
                raise ValueError("invalid body size")
            body = json.loads(self.rfile.read(length))
        except (OSError, ValueError, RecursionError):
            self.reply(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON body"})
            return
        try:
            value = self.service.predict(body)
        except ContractError as exc:
            self.reply(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except (OSError, ValueError, RuntimeError, KeyError):
            self.reply(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "prediction unavailable"})
        else:
            self.reply(HTTPStatus.OK, value)

    def reply(self, status: HTTPStatus, value: dict) -> None:
        payload = json.dumps(value, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *args) -> None:
        # The lab reports response outcomes in its gate. Avoid request logging
        # here so that arbitrarily supplied paths cannot enter the artifacts.
        return


def bind(registry: Registry, port: int) -> HTTPServer:
    configure_cpu()
    return HTTPServer(("127.0.0.1", port), partial(Handler, service=Service(registry)))
~~~

## Check it

~~~bash
uv run --locked python -c "from ml_lab.contract import Features; print(Features.parse({'work_units':200,'queue_depth':3,'pool':'slow'}).numeric())"
~~~

<!-- run: uv run --locked python -c "from ml_lab.contract import Features; assert Features.parse({'work_units':200,'queue_depth':3,'pool':'slow'}).numeric() == (200,3,1)" -->

Expect `(200, 3, 1)`. The live gate uses the same request against the model and the socket endpoint, including after rollback. On a 503, the scheduler can continue using FIFO while an operator checks the active version.
