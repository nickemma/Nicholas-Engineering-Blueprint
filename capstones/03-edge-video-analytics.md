# 3. Edge video analytics on fluctuating links

**Field:** networking · ML · edge computing · **Difficulty:** high · **Languages:** Python, Go

## Problem

Cameras for traffic monitoring, wildlife tracking or crop and building inspection increasingly feed object-detection models. Sending full-quality video to the cloud uses more bandwidth than many sites have; sending too little ruins accuracy. And the available bandwidth changes minute by minute. Choosing frame rate, resolution and compression well, **continuously**, is the difference between a useful system and an expensive one.

## Who

Cities, conservation projects, farms and infrastructure inspectors running cameras over cellular or rural links. The engineers who build their pipelines.

## Gap

- Research systems such as **Chameleon** (Jiang et al., SIGCOMM 2018) and **AWStream** (Zhang et al., SIGCOMM 2018) showed that adapting video configurations can save large amounts of resources while keeping accuracy.
- These systems were evaluated with specific models and networks. Lightweight, reproducible implementations that a small team could run, measured against today's small, CPU-friendly detectors on realistic fluctuating links, are less common.

## Research question

> On links whose bandwidth fluctuates, how much detection accuracy can an adaptive controller keep, compared with fixed configurations, at the same average bandwidth? How quickly must it react to changes in the link and in the scene?

## Hypothesis and baseline

- **Baselines:** fixed configurations (high, medium, low quality), plus an oracle that knows the future bandwidth, as a ceiling.
- **Hypothesis:** an adaptive controller using recent bandwidth and simple scene statistics (motion, object count) keeps accuracy within a few points of the oracle at a fraction of the high-quality bandwidth. It helps most when bandwidth and scene change on similar timescales.

## System

- **An edge agent** (Go or Python) that reads video, applies a configuration (frame rate, resolution, encoder quality), and streams to the server, with backpressure and a bounded queue (Phase 2).
- **A detection server** (Python, PyTorch) running a small pretrained object detector on CPU. It returns detections and costs.
- **A controller** that chooses configurations from bandwidth estimates and scene statistics: rule-based first, then optionally learned.
- **Network emulation** (Phase 5) replaying bandwidth traces. Public cellular bandwidth traces exist from mobile-networking research; or document a synthetic process.
- **A ground-truth pipeline:** run the detector on full-quality video offline, and score each configuration against it.

## Experiment

| Variable | Values |
|---|---|
| Controller | Fixed high, medium, low; adaptive (rules); adaptive (learned); oracle |
| Bandwidth trace | Stable; slow drift; sudden drops; highly variable |
| Video | Public datasets with different motion levels (traffic, pedestrians, nature) |
| Reaction interval | 1 s, 5 s, 30 s |

## Measures

- Detection accuracy (F1 or mAP against ground truth).
- Bandwidth used.
- End-to-end latency.
- Frames dropped.
- Server CPU per frame.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Edge agent | Go, or Python with FFmpeg bindings | Streaming with backpressure and a bounded queue (Phase 2) |
| Encoding | FFmpeg (H.264), configurable frame rate, resolution and quality | The knobs the controller turns |
| Detection server | Python, PyTorch, a small pretrained detector on CPU | No GPU needed |
| Controller | Python first; Go if it moves into the agent | Rules first, then optionally learned |
| Network emulation | `tc netem` replaying bandwidth traces (Phase 5) | Fluctuating links, reproducibly |
| Observability | Prometheus and Grafana (Phase 5) | Per-frame latency and bytes |

## Features to implement

1. An agent that applies a configuration per segment and reports the bytes it sends.
2. A server that returns detections, inference time and queue depth.
3. A controller that picks the next configuration from bandwidth estimates and scene statistics, with hysteresis so it doesn't flap.
4. A ground-truth pipeline that scores every configuration offline against full-quality detections.
5. A trace player for bandwidth, and an oracle controller for the ceiling.
6. Graceful degradation: when the link collapses, keep sending a minimum stream instead of stalling.

## Benchmark your work

- **Accuracy versus bandwidth:** each controller's F1 plotted against average bandwidth, with the fixed configurations as a frontier.
- **Latency:** frame capture to detection, p50 and p99, per trace.
- **Failure:** restart the server mid-stream and measure the gap and the recovery.
- **Server throughput:** frames per second per core at each resolution, to find where the CPU becomes the bottleneck.
- **Rigour:** at least 5 runs per trace and controller, with intervals. Record the clips, traces, model weights and FFmpeg version.

## What you might find

Adaptation may help most during sudden drops. Scene-aware decisions (sending more when there's motion) may matter as much as bandwidth-aware ones. A cheap rule-based controller may come surprisingly close to a learned one.

## Limitations to expect

- CPU-only, small detectors.
- Emulated links.
- Ground truth from a bigger model isn't human labelling.
- Privacy of video subjects must be considered for any real deployment.

## Skills used

Phases 2 (backpressure, streaming), 5 (network emulation, observability), 7 (PyTorch, evaluation) and the Python Bridge (measurement).

## Read first

- Jiang et al., *Chameleon: Scalable Adaptation of Video Analytics*, SIGCOMM 2018
- Zhang et al., *AWStream: Adaptive Wide-Area Streaming Analytics*, SIGCOMM 2018
- Kurose & Ross Ch. 9 (multimedia networking) and §3.7 (congestion control)
