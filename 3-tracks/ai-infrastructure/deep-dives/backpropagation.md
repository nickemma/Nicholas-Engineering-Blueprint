# Verify backpropagation by hand

Start with one input, a single ReLU hidden unit, and a linear output. With scalar weights a and b, input x, target y, hidden activation h = max(0, a × x), prediction p = b × h, and loss L = (p − y)² / 2, the chain rule gives dL/db = (p − y) × h and dL/da = (p − y) × b × x when the hidden unit is active. Away from the activation kink, the inactive derivative is zero.

Calculate both derivatives on paper. Shift each weight by a small amount in both directions and use the centered difference in loss to check your result.

<!-- file: gradient_check.py -->
~~~python
from math import isclose


def loss(a, b, x=2.0, y=1.0):
    prediction = b * max(0.0, a * x)
    return (prediction - y) ** 2 / 2


def backward(a, b, x=2.0, y=1.0):
    hidden = max(0.0, a * x)
    residual = b * hidden - y
    return residual * b * x if a * x > 0 else 0.0, residual * hidden


for a, b in ((1.0, 2.0), (-1.0, 2.0)):
    eps = 0.00001
    numeric_a = (loss(a + eps, b) - loss(a - eps, b)) / (2 * eps)
    numeric_b = (loss(a, b + eps) - loss(a, b - eps)) / (2 * eps)
    grad_a, grad_b = backward(a, b)
    assert isclose(grad_a, numeric_a, abs_tol=eps)
    assert isclose(grad_b, numeric_b, abs_tol=eps)
    print(f"{a=}, {b=}: gradient {grad_a}, {grad_b}")
~~~

<!-- run: python3 gradient_check.py -->

Now accumulate gradients across a batch and divide by batch size if your loss is a mean. Compare the same input, weights, and loss reduction with an automatic differentiation implementation. Avoid placing the numerical check exactly at a ReLU kink, where the centered difference crosses two distinct slopes. [Train the larger model](../01-ml-for-infrastructure/lessons/04-train-a-cpu-model-and-score-it.md)

## Check a vectorized network

The matrix version below preserves the earlier lab's manual forward and backward passes for a full batch. The first layer stores activations so the backward pass can apply the ReLU mask. The numerical check perturbs every weight or bias individually.

<!-- file: batch_gradient_check.py -->
~~~python
import numpy as np


class MLP:
    """Weights, and the passes forward and back."""

    def __init__(self, inputs: int, hidden: int, seed: int = 1):
        rng = np.random.default_rng(seed)
        # He initialisation: weights scaled so a ReLU layer's outputs keep
        # about the spread of its inputs, layer after layer.
        self.params = {
            "W1": rng.normal(0, np.sqrt(2 / inputs), (inputs, hidden)),
            "b1": np.zeros(hidden),
            "W2": rng.normal(0, np.sqrt(2 / hidden), (hidden, 1)),
            "b2": np.zeros(1),
        }

    def forward(self, x: np.ndarray) -> tuple[np.ndarray, dict]:
        p = self.params
        z = x @ p["W1"] + p["b1"]
        h = np.maximum(z, 0)
        out = (h @ p["W2"] + p["b2"]).ravel()
        return out, {"x": x, "z": z, "h": h}

    def loss(self, x: np.ndarray, y: np.ndarray) -> float:
        out, _ = self.forward(x)
        return float(np.mean((out - y) ** 2) / 2)

    def backward(self, cache: dict, out: np.ndarray, y: np.ndarray) -> dict:
        """d(loss)/d(each parameter), by the chain rule, last layer first."""
        p, n = self.params, len(y)
        d_out = ((out - y) / n)[:, None]  # d loss / d out
        grads = {"W2": cache["h"].T @ d_out, "b2": d_out.sum(axis=0)}
        d_h = d_out @ p["W2"].T  # back through the second layer
        d_z = d_h * (cache["z"] > 0)  # back through ReLU: it passes only where z > 0
        grads["W1"] = cache["x"].T @ d_z
        grads["b1"] = d_z.sum(axis=0)
        return grads


def gradient_check(net: MLP, x: np.ndarray, y: np.ndarray, eps: float = 1e-6) -> dict[str, float]:
    """For each parameter, the largest relative difference between backward's gradient and
    the slope measured by central differences: (loss(w + eps) - loss(w - eps)) / (2 eps).
    A correct backward pass gives well under 1e-5 (in float64); a wrong one, far more.
    """
    out, cache = net.forward(x)
    grads = net.backward(cache, out, y)
    worst = {}
    for name, value in net.params.items():
        measured = np.zeros_like(value)
        for i in np.ndindex(value.shape):
            keep = value[i]
            value[i] = keep + eps
            up = net.loss(x, y)
            value[i] = keep - eps
            down = net.loss(x, y)
            value[i] = keep
            measured[i] = (up - down) / (2 * eps)
        diff = np.abs(grads[name] - measured) / np.maximum(
            np.abs(grads[name]) + np.abs(measured), 1e-12
        )
        worst[name] = float(diff.max())
    return worst


for seed in (1, 2, 3):
    rng = np.random.default_rng(seed)
    net = MLP(inputs=5, hidden=4, seed=seed)
    x, y = rng.normal(size=(20, 5)), rng.normal(size=20)
    errors = gradient_check(net, x, y)
    assert max(errors.values()) < 1e-5, errors
~~~

<!-- run: uv run --no-project --python 3.12 --with numpy==2.5.4 python batch_gradient_check.py -->

## Compare every gradient with PyTorch

Reuse the batch and weights from the numerical check. This is an optional check against the CPU build of PyTorch. It compares all four parameter tensors and the loss before starting any training.

<!-- file: torch_parity.py -->
~~~python
import numpy as np
import torch

from batch_gradient_check import MLP


rng = np.random.default_rng(11)
x, y = rng.normal(size=(20, 5)), rng.normal(size=20)
manual = MLP(5, 4, seed=11)
out, cache = manual.forward(x)
expected = manual.backward(cache, out, y)

p = {name: torch.tensor(value, requires_grad=True) for name, value in manual.params.items()}
hidden = (torch.from_numpy(x) @ p["W1"] + p["b1"]).relu()
prediction = (hidden @ p["W2"] + p["b2"]).ravel()
loss = (prediction - torch.from_numpy(y)).square().mean() / 2
loss.backward()

np.testing.assert_allclose(loss.detach().numpy(), manual.loss(x, y))
for name, gradient in expected.items():
    np.testing.assert_allclose(p[name].grad.numpy(), gradient, atol=1e-12)
print("PyTorch CPU loss and four parameter gradients match")
~~~

~~~bash
uv run --no-project --python 3.12 --with numpy==2.5.4 \
  --with torch==2.14.1+cpu --extra-index-url https://download.pytorch.org/whl/cpu \
  python torch_parity.py
~~~
