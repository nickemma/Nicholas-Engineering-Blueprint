# 13 CUDA, transfers, and vLLM

> **Optional, and needs an NVIDIA GPU you rent.** The required path skips this lesson; the module's gate doesn't depend on it.

Read the [linear-algebra guide](../../../../math/03-linear-algebra/README.md) first: arithmetic intensity and the roofline explain why prefill, decode and tiny kernels hit different limits. CUDA has a host and device address space; transfer time and launch overhead are work too. Pinned host buffers allow efficient DMA, but pinning costs memory and setup, and `non_blocking=True` alone does not prove overlap. See [NVIDIA's CUDA best practices](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/).

**Evidence status:** no GPU is available in this checkout. These scripts are provided for a run on an authorised NVIDIA host. They have no measured output yet. If using a rented host, agree its budget first, record the rate, and stop/destroy the instance afterwards. First capture `nvidia-smi`, driver/CUDA versions, CPU/RAM, image/environment digest and the model revision. Use a fresh GPU-specific environment rather than the lab's CPU-only PyTorch index.

~~~bash
uv venv --python 3.12 .gpu-venv
# Choose a CUDA-enabled PyTorch build compatible with the provider's driver.
# Record the resolved packages with: uv pip freeze --python .gpu-venv/bin/python
~~~

A CUDA kernel maps blocks and threads onto indices; the final block may be partial. This one deliberately uses 1,003 elements to catch an omitted bounds check:


<!-- file: gpu/add.cu -->
~~~cpp
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#define CHECK(call) do { auto e=(call); if(e!=cudaSuccess) { \
 fprintf(stderr,"%s\n",cudaGetErrorString(e)); std::exit(1); } } while(0)
__global__ void add(const float* a, const float* b, float* c, int n) {
 int i=blockIdx.x*blockDim.x+threadIdx.x;
 if(i<n) c[i]=a[i]+b[i];
}
int main() {
 constexpr int n=1003;
 float *a,*b,*c;
 CHECK(cudaMallocManaged(&a,n*sizeof(float)));
 CHECK(cudaMallocManaged(&b,n*sizeof(float)));
 CHECK(cudaMallocManaged(&c,n*sizeof(float)));
 for(int i=0;i<n;i++){a[i]=i;b[i]=2*i;}
 add<<<(n+255)/256,256>>>(a,b,c,n);
 CHECK(cudaGetLastError()); CHECK(cudaDeviceSynchronize());
 for(int i=0;i<n;i++) if(c[i]!=3*i) return 2;
 std::puts("1003 elements correct, including the partial final block");
 CHECK(cudaFree(a)); CHECK(cudaFree(b)); CHECK(cudaFree(c));
}
~~~

~~~bash
nvcc -O2 gpu/add.cu -o gpu/add
compute-sanitizer ./gpu/add
~~~

**Break it:** remove `if(i<n)` and run compute-sanitizer. Restore the guard. A successful launch is not a successful kernel: check launch errors and synchronise before reading results.

Now measure transfer **completion**, not the time to enqueue a copy. Allocate before timing, warm up, use repeated samples and check answers. PyTorch invokes CUDA here; this complements the kernel exercise above.


<!-- file: gpu/capture.py -->
~~~python
"""GPU-only evidence capture: warm up, synchronise, measure and verify."""

import json
import platform
import statistics
import time

import torch


def main():
    if not torch.cuda.is_available():
        raise SystemExit("not measured: CUDA device unavailable")
    torch.manual_seed(1)
    print(
        json.dumps(
            {
                "torch": torch.__version__,
                "cuda": torch.version.cuda,
                "gpu": torch.cuda.get_device_name(),
                "host": platform.platform(),
            }
        )
    )
    for n in (1 << 10, 1 << 20, 1 << 24):
        for pinned in (False, True):
            host = torch.ones(n, pin_memory=pinned)
            device = torch.empty(n, device="cuda")
            samples = []
            for i in range(12):
                torch.cuda.synchronize()
                start = time.perf_counter()
                device.copy_(host, non_blocking=pinned)
                torch.cuda.synchronize()  # measuring completion, not enqueue
                if i >= 2:
                    samples.append(time.perf_counter() - start)
            assert device.sum().item() == n
            print(
                json.dumps(
                    {
                        "bytes": n * 4,
                        "pinned": pinned,
                        "median_seconds": statistics.median(samples),
                    }
                )
            )
    n = 512
    a, b = torch.randn(n, n), torch.randn(n, n)
    reference = a @ b
    aa, bb = a.cuda(), b.cuda()
    torch.cuda.synchronize()
    samples = []
    for i in range(12):
        start, end = (
            torch.cuda.Event(enable_timing=True),
            torch.cuda.Event(enable_timing=True),
        )
        start.record()
        result = aa @ bb
        end.record()
        end.synchronize()
        if i >= 2:
            samples.append(start.elapsed_time(end))
    torch.testing.assert_close(result.cpu(), reference, rtol=1e-3, atol=1e-3)
    print(
        json.dumps(
            {
                "matmul_n": n,
                "median_ms": statistics.median(samples),
                "max_memory_bytes": torch.cuda.max_memory_allocated(),
            }
        )
    )


if __name__ == "__main__":
    main()
~~~

<!-- run: python3 -m py_compile gpu/capture.py -->

~~~bash
.gpu-venv/bin/python gpu/capture.py > gpu-results.jsonl
~~~

Explain why small transfers are dominated by fixed overhead, why pinning can matter for large transfers, and why the device matmul timer excludes host-device copies. Compare end-to-end time separately. A speedup without answer parity is not accepted. If a tolerance fails, investigate precision settings; do not silently widen it.

Finally run [vLLM](https://docs.vllm.ai/en/latest/serving/offline_inference/) on the same frozen prompt/quality set. In a separate environment install a pinned version supported by the provider, record its lock and model revision, then:

~~~bash
vllm serve Qwen/Qwen2.5-0.5B-Instruct --host 127.0.0.1 --port 8000 --max-model-len 4096
~~~

Use the step-3 load client through an SSH tunnel bound to loopback, at concurrency/arrival rates that fit the GPU. Repeat the performance/cost/quality grid, collecting server token usage, GPU memory and utilisation. vLLM's batching and paged KV management target different overheads from our tick simulator; explain which bottleneck moved. Compare the same precision/model when possible, and label Q4 GGUF versus FP16 as a combined engine-and-precision comparison. One GPU cannot verify multi-GPU tensor parallelism.

## What you can check without a GPU

Before you pay for a GPU, check everything that doesn't need one, so the paid hour isn't spent fixing typos. NVIDIA publishes its CUDA compiler as Python wheels, so you can install it without a GPU and without admin rights:

~~~bash
uv venv --python 3.12 .cuda-tools
uv pip install --python .cuda-tools/bin/python nvidia-cuda-nvcc==13.5.37 nvidia-cuda-runtime==13.5.37
NVCC=.cuda-tools/lib/python3.12/site-packages/nvidia/cu13/bin/nvcc
$NVCC --version | tail -2
$NVCC -O2 gpu/add.cu -o gpu/add && ./gpu/add
~~~

~~~text
Cuda compilation tools, release 13.5, V13.5.37
Build cuda_13.5.r13.5/compiler.39125733_0
CUDA driver version is insufficient for CUDA runtime version
~~~

The kernel compiles. Running it fails at the first CUDA call, and the `CHECK` macro reports why and exits with status 1, instead of carrying on and checking answers that were never computed. That's the error path working. (The CUDA 12 wheel, `nvidia-cuda-nvcc-cu12`, contains only `ptxas`, not `nvcc`; use the CUDA 13 one.)

Now the Break it without a GPU: delete `if(i<n)` and compile again. It compiles without a warning. The compiler can't know the last block is partial, which is exactly why the step runs `compute-sanitizer` on real hardware. Put the guard back.

The timing script refuses rather than inventing numbers:

~~~bash
cd serve && uv run python ../gpu/capture.py
~~~

~~~text
not measured: CUDA device unavailable
~~~

This proves the code compiles and that both programs fail cleanly without a GPU. It proves nothing about correctness or speed on one: those need the run above, on real hardware.

**Done when:** the kernel passes sanitizer, transfer and matmul parity pass, the repeated timing records exist, vLLM completes the frozen quality/performance suite, and the instance is destroyed. Until those artifacts exist, lesson 13 remains **not measured**, never an expected numerical output invented from a spec sheet.

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->
