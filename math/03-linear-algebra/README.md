# 03. Linear algebra for ML and GPUs

<!-- continue: ../02-proofs-invariants/README.md -->

A neural network is mostly matrix multiplication, so the cost of AI infrastructure is mostly the cost of matrix multiplication. This guide teaches just enough linear algebra to read that sentence closely, and one idea that explains why GPUs exist: **arithmetic intensity**. You measure it on your own CPU, and find the same arithmetic running 20 times faster or slower, depending only on how it reaches memory.

**Real systems:** this is the prerequisite for [Phase 8](../../lessons/08-ai-infrastructure/README.md)'s CUDA and matrix-multiply steps. [DSA guide 00](../../dsa/00-complexity/README.md) and the [Performance Bridge](../../lessons/perf-bridge/README.md) showed that cache misses can beat Big-O. Here's the formal version of that.

## Set up

Add NumPy:

<!-- run: uv add numpy -->

~~~bash
uv add numpy
~~~

## Vectors and the dot product

A **vector** is a list of numbers. It can be a point, a direction, an embedding of a sentence, or one row of a table. The **dot product** multiplies pairs, then adds them up:

```
a · b = a₁b₁ + a₂b₂ + … + aₙbₙ
```

It measures how much two vectors point the same way: positive if they agree, zero if they're at right angles, negative if they're opposed. Divide by their lengths, and you have **cosine similarity**, which is how a vector search finds similar documents. It's also one neuron: a weighted sum of inputs is a dot product with the weights.

## Matrices

A **matrix** is a grid of numbers. Think of it as **a function that transforms vectors**. Matrix times vector means taking the dot product of each row with the vector: *n* dot products of length *n*.

Matrix times matrix is **composition**: apply one transformation, then the other. Entry (*i*, *j*) of *AB* is row *i* of *A* dotted with column *j* of *B*.

```
[1 2]   [5 6]   [1·5+2·7  1·6+2·8]   [19 22]
[3 4] × [7 8] = [3·5+4·7  3·6+4·8] = [43 50]
```

Three facts worth keeping:

- **The shapes must match:** an *m*×*k* times a *k*×*n* gives an *m*×*n*.
- **Order matters:** *AB* usually isn't *BA*. "Rotate, then stretch" isn't "stretch, then rotate".
- **The identity** (ones on the diagonal) changes nothing, like multiplying by 1.

Write it from scratch once, so that nothing about it is magic:

<!-- file: linalg/matrix.py -->
~~~python
"""Vectors and matrices from scratch, as lists of floats."""

Vector = list[float]
Matrix = list[list[float]]


def dot(a: Vector, b: Vector) -> float:
    """Return the dot product: multiply pairs, and add them up."""
    return sum(x * y for x, y in zip(a, b, strict=True))


def mat_vec(m: Matrix, v: Vector) -> Vector:
    """Return m times v: the dot product of each row with v."""
    return [dot(row, v) for row in m]


def mat_mul(a: Matrix, b: Matrix) -> Matrix:
    """Return a times b: entry (i, j) is row i of a dotted with column j of b."""
    rows, cols, inner = len(a), len(b[0]), len(b)
    out = [[0.0] * cols for _ in range(rows)]
    for i in range(rows):
        for j in range(cols):
            total = 0.0
            for k in range(inner):
                total += a[i][k] * b[k][j]
            out[i][j] = total
    return out
~~~

## The cost of a matrix multiply

Three nested loops of *n* each give *n*³ steps, each with one multiply and one add. So:

```
matrix multiply: 2n³ flops        (floating-point operations)
```

Doubling *n* costs **eight** times as much. Now count the data as well, and here's the key idea. Each operation has an **arithmetic intensity**: how many flops it does for each byte it has to touch.

| Operation | Flops | Data touched (bytes, for 8-byte numbers) | Intensity (flops per byte) |
|---|---|---|---|
| Dot product | 2*n* | 16*n* | 0.125, whatever *n* is |
| Matrix × vector | 2*n*² | about 8*n*² | 0.25, whatever *n* is |
| Matrix × matrix | 2*n*³ | 24*n*² | *n*/12: **it grows with *n*** |

That last row is why AI runs on GPUs. A dot product touches a byte for almost every operation. A matrix multiply at *n* = 1,000 does 83 flops per byte. The data can be brought in once, and worked on many times.

<!-- file: linalg/cost.py -->
~~~python
"""How much arithmetic an operation does, and how much data it has to touch."""

from dataclasses import dataclass

FLOAT_BYTES = 8  # a double; GPUs often use 4 or 2


@dataclass(frozen=True)
class Cost:
    flops: float  # floating-point operations
    bytes: float  # data read and written, each element counted once

    @property
    def intensity(self) -> float:
        """Arithmetic intensity: flops per byte of data."""
        return self.flops / self.bytes


def dot_cost(n: int) -> Cost:
    """n multiplies and n additions, over two vectors of n."""
    return Cost(2 * n, 2 * n * FLOAT_BYTES)


def mat_vec_cost(n: int) -> Cost:
    """n dot products of length n, over a matrix and two vectors."""
    return Cost(2 * n**2, (n**2 + 2 * n) * FLOAT_BYTES)


def mat_mul_cost(n: int) -> Cost:
    """n² dot products of length n, over three matrices of n²."""
    return Cost(2 * n**3, 3 * n**2 * FLOAT_BYTES)


def attainable(intensity: float, peak_flops: float, bandwidth: float) -> float:
    """The roofline: the flop rate is capped by the arithmetic units, or by
    how fast memory can supply data at this intensity."""
    return min(peak_flops, intensity * bandwidth)
~~~

## The roofline

A chip has two limits: how fast it can do arithmetic, and how fast memory can feed it. Whichever comes first sets your speed:

```
attainable flops/s = min(peak flops/s, intensity × memory bandwidth)
```

This is the **roofline model**. Plotted against intensity, it's a sloped line (limited by memory), then a flat roof (limited by arithmetic). Low-intensity work is on the slope, and buying more arithmetic does nothing for it. High-intensity work is under the roof.

A GPU is a machine with a very high roof. It has thousands of simple arithmetic units, so **only work with high intensity can reach that roof**. Large matrix multiplies are exactly that. It's the same reason why batch size matters: a bigger batch makes a bigger matrix, with more intensity, and keeps more of the units busy.

## Measuring it

Time NumPy on one CPU core, with `OPENBLAS_NUM_THREADS=1`. NumPy's `@` calls OpenBLAS, a library that's been tuned for exactly this for decades.

<!-- file: linalg/measure.py -->
~~~python
"""Time matrix work on one CPU core, and fit a roofline to the results."""

import os

os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")  # before NumPy loads

import math
import statistics
import time

import numpy as np

from linalg.cost import attainable, dot_cost, mat_mul_cost
from linalg.matrix import mat_mul


def seconds(a: np.ndarray, b: np.ndarray) -> float:
    """Return the median time of one a @ b.

    Each sample repeats the call until it has taken 10 ms, so that a tiny
    operation isn't swamped by the cost of calling it from Python.
    """
    calls = 1
    while True:
        start = time.perf_counter()
        for _ in range(calls):
            a @ b
        if time.perf_counter() - start > 0.01:
            break
        calls *= 2
    samples = []
    for _ in range(5):
        start = time.perf_counter()
        for _ in range(calls):
            a @ b
        samples.append((time.perf_counter() - start) / calls)
    return statistics.median(samples)


def python_against_numpy() -> None:
    n = 256
    a = np.random.default_rng(1).random((n, n))
    b = np.random.default_rng(2).random((n, n))
    start = time.perf_counter()
    mat_mul(a.tolist(), b.tolist())
    slow = time.perf_counter() - start
    fast = seconds(a, b)
    print(f"n={n}: pure Python {slow:.2f} s, NumPy {fast * 1000:.2f} ms, {slow / fast:.0f} times")


def growth() -> list[tuple[int, float]]:
    print(f"{'n':>6} {'seconds':>9} {'GFLOPS':>8} {'intensity':>10}")
    results = []
    for n in (8, 32, 128, 512, 1024, 2048):
        a = np.random.default_rng(1).random((n, n))
        b = np.random.default_rng(2).random((n, n))
        t = seconds(a, b)
        cost = mat_mul_cost(n)
        rate = cost.flops / t
        results.append((n, t))
        print(f"{n:6d} {t:9.5f} {rate / 1e9:8.1f} {cost.intensity:10.2f}")
    (n1, t1), (n2, t2) = results[-3], results[-1]
    print(f"growth from n={n1} to n={n2}: time goes as n^{math.log(t2 / t1, n2 / n1):.2f}")
    return results


def dot_rates() -> float:
    print(f"{'bytes':>12} {'GFLOPS':>8}")
    rate = 0.0
    for size in (16 << 10, 1 << 20, 8 << 20, 64 << 20, 512 << 20):
        n = size // 16
        a = np.random.default_rng(1).random(n)
        b = np.random.default_rng(2).random(n)
        t = seconds(a, b)
        rate = dot_cost(n).flops / t
        print(f"{size:12d} {rate / 1e9:8.2f}")
    return rate


def roofline_check(bandwidth: float) -> None:
    """Predict a case the roofline wasn't fitted to, then measure it."""
    n = 8192  # a 512 MB matrix, far bigger than any cache
    m = np.random.default_rng(1).random((n, n))
    v = np.random.default_rng(2).random(n)
    measured = 2 * n**2 / seconds(m, v)
    predicted = 0.25 * bandwidth  # 2n² flops over the matrix's 8n² bytes
    print(f"\nmatrix-vector, n={n}: predicted {predicted / 1e9:.1f}, measured {measured / 1e9:.1f}")


def main() -> None:
    python_against_numpy()
    print()
    results = growth()
    print()
    memory_rate = dot_rates()
    bandwidth = memory_rate / dot_cost(1).intensity
    peak = max(mat_mul_cost(n).flops / t for n, t in results)
    print(f"\nroofline: peak {peak / 1e9:.1f} GFLOPS, memory {bandwidth / 1e9:.1f} GB/s")
    for n in (2, 8, 64, 1024):
        cost = mat_mul_cost(n)
        limit = attainable(cost.intensity, peak, bandwidth)
        print(
            f"  matmul n={n:5d}: intensity {cost.intensity:7.2f}, limit {limit / 1e9:6.1f} GFLOPS"
        )
    roofline_check(bandwidth)


if __name__ == "__main__":
    main()
~~~

<!-- file: linalg/layer.py -->
~~~python
"""One layer of a neural network is a matrix multiply, plus a bend."""

import numpy as np


def relu(x: np.ndarray) -> np.ndarray:
    return np.maximum(x, 0)


def forward(batch: np.ndarray, weights: list[np.ndarray]) -> np.ndarray:
    """Pass a batch (one row per example) through layers of weights."""
    x = batch
    for w in weights[:-1]:
        x = relu(x @ w)
    return x @ weights[-1]


def parameters(widths: list[int]) -> int:
    """Count the weights in a network with these layer widths."""
    return sum(a * b for a, b in zip(widths, widths[1:], strict=False))


def forward_flops(batch: int, widths: list[int]) -> int:
    """Count the flops of one forward pass, ignoring the ReLUs."""
    return sum(2 * batch * a * b for a, b in zip(widths, widths[1:], strict=False))
~~~

<!-- file: linalg/test_linalg.py -->
~~~python
import numpy as np
import pytest

from linalg.cost import attainable, dot_cost, mat_mul_cost, mat_vec_cost
from linalg.layer import forward, forward_flops, parameters, relu
from linalg.matrix import dot, mat_mul, mat_vec


def test_dot():
    assert dot([1, 2, 3], [4, 5, 6]) == 32


def test_mat_vec():
    assert mat_vec([[1, 2], [3, 4]], [1, 1]) == [3, 7]


def test_mat_mul_by_hand():
    assert mat_mul([[1, 2], [3, 4]], [[5, 6], [7, 8]]) == [[19, 22], [43, 50]]


def test_mat_mul_handles_rectangles():
    assert mat_mul([[1, 2, 3]], [[1], [1], [1]]) == [[6]]


def test_the_identity_changes_nothing():
    a = [[1.0, 2.0], [3.0, 4.0]]
    assert mat_mul(a, [[1.0, 0.0], [0.0, 1.0]]) == a


def test_order_matters():
    a, b = [[0, 1], [0, 0]], [[0, 0], [1, 0]]
    assert mat_mul(a, b) != mat_mul(b, a)


def test_mat_mul_agrees_with_numpy():
    rng = np.random.default_rng(1)
    a, b = rng.random((8, 8)), rng.random((8, 8))
    assert np.allclose(mat_mul(a.tolist(), b.tolist()), a @ b)


def test_doubling_n_costs_eight_times_the_flops():
    assert mat_mul_cost(200).flops == 8 * mat_mul_cost(100).flops


def test_intensity_grows_with_n_only_for_mat_mul():
    assert dot_cost(10).intensity == dot_cost(1000).intensity
    assert mat_vec_cost(1000).intensity == pytest.approx(0.25, rel=0.01)
    assert mat_mul_cost(1000).intensity == pytest.approx(10 * mat_mul_cost(100).intensity)


def test_the_roofline_has_two_regions():
    assert attainable(0.1, 100, 50) == pytest.approx(5)
    assert attainable(100, 100, 50) == 100


def test_a_layer_is_a_matmul():
    x = np.array([[1.0, 2.0]])
    w = np.array([[1.0, 0.0, 2.0], [0.0, 1.0, 1.0]])
    assert forward(x, [w]).tolist() == [[1.0, 2.0, 4.0]]


def test_relu_clips_negatives():
    assert relu(np.array([-1.0, 2.0])).tolist() == [0.0, 2.0]


def test_counts():
    assert parameters([784, 256, 10]) == 784 * 256 + 256 * 10
    assert forward_flops(32, [10, 5]) == 2 * 32 * 10 * 5
~~~

<!-- run: uv run pytest -q linalg && uv run ruff format --check . && uv run ruff check . -->

~~~bash
uv run pytest -q linalg
uv run python -m linalg.measure
~~~

CI runs the tests, but not the timing. One run, on an 8-core Ryzen 7 PRO 5850U under WSL2, with OpenBLAS 0.3.34:

~~~text
n=256: pure Python 1.62 s, NumPy 0.80 ms, 2030 times

     n   seconds   GFLOPS  intensity
     8   0.00000      0.8       0.67
    32   0.00000     18.4       2.67
   128   0.00011     37.5      10.67
   512   0.00696     38.6      42.67
  1024   0.05781     37.1      85.33
  2048   0.43227     39.7     170.67
growth from n=512 to n=2048: time goes as n^2.98

       bytes   GFLOPS
       16384     2.01
     1048576     8.12
     8388608     7.81
    67108864     1.85
   536870912     1.95

roofline: peak 39.7 GFLOPS, memory 15.6 GB/s
  matmul n=    2: intensity    0.17, limit    2.6 GFLOPS
  matmul n=    8: intensity    0.67, limit   10.4 GFLOPS
  matmul n=   64: intensity    5.33, limit   39.7 GFLOPS
  matmul n= 1024: intensity   85.33, limit   39.7 GFLOPS

matrix-vector, n=8192: predicted 3.9, measured 3.5
~~~

Your numbers will differ, and they'll move from run to run: on this laptop, the peak ranged over 39–47 GFLOPS across five runs, and memory over 12–16 GB/s.

**It's cubic.** The fitted exponent was between 2.8 and 3.1 across five runs. Doubling *n* costs about eight times as much, as predicted.

**Same formula, about a thousand times faster.** Pure Python took about a second for what NumPy did in less than a millisecond. The maths is identical. The difference is interpreted objects against tight loops, vector instructions and cache-aware blocking. This is the measure of what "just write it in Python" costs, and of what a good library is worth.

**The same arithmetic, 20 times apart.** Compare the two tables. A matrix multiply runs at about 40 GFLOPS. A dot product whose data doesn't fit in the cache runs at about 2. Both are multiplies and adds, on the same core, in the same library. Only the intensity differs. That's the roofline, on your own machine.

**The roofline predicts.** Memory bandwidth came from the dot product, so that part is a fit, and proves nothing. The test is in the last line: a matrix-vector multiply wasn't used to fit anything, and its intensity is twice a dot product's, so it should run at about twice the rate. Across five runs, the median prediction was 3.9 GFLOPS, and the median measurement was 3.3. It's about 15% high, and it gets the size right from one number.

**Two readings to ignore.** The smallest sizes are slow for a boring reason: at *n* = 8 or a 16 KB dot product, you're mostly timing the call from Python into NumPy, not the arithmetic. Each operation takes a fraction of a microsecond, and calling it costs more than that. The dot product does reach about 8 GFLOPS in cache, so the slope is real, but the left-hand end of that table isn't the roofline. Don't quote it.

## A neural network, as matrices

A layer takes a batch of inputs (one row per example), multiplies by a matrix of weights, and applies a simple non-linear function such as ReLU, which clips negatives to zero. Without that bend, stacking layers would be pointless, since a chain of matrix multiplies is just one matrix multiply.

`linalg/layer.py` above is the whole of it: `x @ w` in a loop. You can now work out what a model costs from its shape:

```
weights in a layer:  inputs × outputs
flops, one pass:     2 × batch × inputs × outputs
memory:              weights × bytes per weight
```

A layer of 4,096 by 4,096 has about 16.8 million weights: 67 MB at 4 bytes each. One forward pass with a batch of 32 takes about a billion flops, and a large model has many such layers. At 40 GFLOPS on this core, that one layer takes 27 ms; a model of 100 layers takes 2.7 seconds per batch, before any training. Training adds a backward pass of about the same order, and it repeats for millions of batches, which is why this needs far more arithmetic than one CPU core can offer.

Two consequences for Phase 8:

- **Precision is a trade.** Halving a number's size from 4 bytes to 2 doubles the intensity, and halves the memory. Numbers lose accuracy, and a lot of inference engineering lives in that trade-off.
- **Bandwidth is the wall.** Once the arithmetic is under its roof, a GPU's memory and, in a cluster, its network set the limit. That's the [Networking Bridge](../../lessons/network-bridge/README.md)'s bandwidth-delay product again, between machines.

## What to do with this

- **Estimate first.** Before you run anything, count flops and bytes. Compare with the machine's peak and bandwidth, and you have a lower bound on the run time.
- **Ask where you are on the roofline.** If memory is the limit, faster arithmetic buys nothing.
- **Check a benchmark's claim.** "This GPU does *X* FLOPS" means that at the top of the roofline, on the most intense work. Yours may be on the slope.
- **Don't write your own matrix multiply.** You did, once, to see why.

## Practice

Solve these alone. There are no solutions here.

1. What's the cost of multiplying an *m*×*k* by a *k*×*n*? Show that multiplying three matrices can cost very different amounts, depending on the order of the brackets. (The cheapest order is a famous DP problem.)
2. Compute cosine similarity from `dot`. Write a brute-force search over 100,000 random vectors. How does its time scale? Why is that a problem for a vector database?
3. Rewrite `mat_mul` with the loops in i-k-j order in Go, and compare it with i-j-k at *n* = 2,000. Explain the difference with a tool from the Performance Bridge.
4. Break a matrix multiply into 64×64 blocks. Does it help in Go? Which row of the roofline does blocking change?
5. Run `measure.py` with `OPENBLAS_NUM_THREADS=8`. Which limit does the matrix multiply hit? Which does the dot product hit? Do they scale the same way?
6. Look up a real GPU's peak FLOPS and memory bandwidth, and draw its roofline. Where does an *n*-by-*n* matrix multiply hit the roof?
7. Work out flops and memory for a model with your own choice of layers, and check your count of weights against one in PyTorch.

## Read

- Williams, Waterman and Patterson, [*Roofline: An Insightful Visual Performance Model for Multicore Architectures*](https://dl.acm.org/doi/10.1145/1498765.1498785), Communications of the ACM, 2009.
- Grant Sanderson, [*Essence of Linear Algebra*](https://www.3blue1brown.com/topics/linear-algebra): the best way to see it.
- Gilbert Strang, *Introduction to Linear Algebra*, and his [MIT course 18.06](https://ocw.mit.edu/courses/18-06-linear-algebra-spring-2010/).
- Patterson and Hennessy, *Computer Organization and Design*: the chapters on parallel processors and GPUs.
