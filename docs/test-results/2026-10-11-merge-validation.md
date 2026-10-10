# Final merge validation, October 11, 2026

This corrects two measurement limitations in the prior
[foreground record](2026-10-10-foreground-followup.md). Historical failures
remain in that record; they are not deleted or reclassified as passes.

## Four-pane sustained flood

The measurement helper previously stopped each `yes` producer before reading
its latest metric ring. Stopping four panes sequentially changes the workload
and can fill a new ring during teardown. The corrected helper reads and
attaches its rings **while all producers are still running**, after the five
four-second CPU/memory measurements, and only then stops them.

The old-source control is `b0917ddf`, with the existing isolated measurement
patches and additional current `RenderMetrics`/display-link callback diagnostics.
It preserves the old row storage, renderer, PTY polling and policy. Native GPU
execution/feedback timing was already present on both sides. Wake-hop
instrumentation remains additional work on the current side; this is callback
and GPU instrumentation parity, not a claim that every diagnostic call is
identical. The callback baseline executable SHA-256 is
`408f40971a9fefc5a8306f5ad755c07bfc7f3e9ad4ca8b3671098bbd0f8a3bfa`;
current measured executable is
`4283d84160599cadf07e6c56799f54a252f00c7276b3dc13c47df7715ef6a3b6`.
Three alternating old/current pairs use Benchmark, displaylink, mains,
Low Power Mode off, the built-in 60 Hz display and the same isolated fixtures.
No build, trace recorder or other measurement runs concurrently with them.

| Pair | Old CPU p99 | Current CPU p99 | Old GPU p99 | Current GPU p99 |
| --- | ---: | ---: | ---: | ---: |
| 1 | 0.32 ms | 0.29 ms | 0.61 ms | 0.49 ms |
| 2 | 0.36 ms | 0.27 ms | 0.47 ms | 0.49 ms |
| 3 | 0.34 ms | 0.28 ms | 0.48 ms | 0.48 ms |

All six XCTest runs pass. Current GPU p99 is within the old range;
CPU tails improve. This is the sustained-workload default-driver comparison.
The first parity probe using the obsolete teardown procedure still reported
2.05 ms at its final ring, while intervening current rings were 0.47–0.49 ms.
Its partial second pair was stopped once the sampling defect was identified;
that incomplete run is not a pass and is not included in the prospective table.
An additional final-source flood check is recorded below.

## No-sync experiment disposition

`ondemand-nosync` did not receive the issue's required continuous-screen
human verification. Its enum value and disabling of display synchronization
are removed. Both retained drivers explicitly keep synchronization enabled;
a stale `ondemand-nosync` value falls back to displaylink, covered by the
existing environment accessor test. Historical no-sync measurements remain
experimental records. Displaylink remains the default under #280's explicit
fallback; failed experimental flood results do not promote ondemand.
Removing this rejected option does not change either retained driver's
presentation path used in the flood pairs above.

## Raw sustained-flood rings

These are all CPU/GPU execution/feedback rings attached before teardown,
including startup rings. The quoted values are the latest full rings, according
to the fixed helper; no high startup or intermediate ring is discarded from
this raw record. Local result bundles are
`/tmp/corta-steady-flood-{before,after}-{1,2,3}.xcresult`.

### before, pair 1

```text
cpuFrame: n=600 avg=0.13ms p50=0.11ms p95=0.24ms p99=0.87ms max=1.86ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.46ms p50=0.41ms p95=0.78ms p99=2.50ms max=5.57ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.12ms p50=0.10ms p95=0.16ms p99=0.43ms max=2.95ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.28ms max=0.53ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.13ms p50=0.13ms p95=0.20ms p99=0.25ms max=0.46ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.47ms p99=0.59ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.14ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.22ms p99=0.33ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.47ms p99=0.60ms max=0.65ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.11ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.13ms p95=0.21ms p99=0.34ms max=0.44ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.48ms p99=0.60ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.12ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.15ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.13ms p95=0.21ms p99=0.34ms max=0.50ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.50ms p99=0.60ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.18ms p50=0.15ms p95=0.35ms p99=0.56ms max=0.73ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.34ms p95=0.56ms p99=0.62ms max=0.67ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.12ms p99=0.16ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.12ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.13ms p95=0.21ms p99=0.27ms max=0.50ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.47ms p99=0.59ms max=0.61ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.24ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.25ms p99=0.42ms max=1.05ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.48ms p99=0.60ms max=0.63ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.11ms max=0.22ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.22ms p99=0.35ms max=0.38ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.47ms p99=0.61ms max=0.63ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.06ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.24ms p99=0.36ms max=0.54ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.47ms p99=0.61ms max=0.64ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.22ms p99=0.32ms max=0.38ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.47ms p99=0.61ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
```

### after, pair 1

```text
cpuFrame: n=600 avg=0.14ms p50=0.11ms p95=0.30ms p99=0.83ms max=2.58ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.46ms p50=0.39ms p95=0.83ms p99=3.32ms max=5.84ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.12ms p50=0.08ms p95=0.16ms p99=1.07ms max=2.83ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.11ms p99=0.19ms max=0.44ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.21ms p99=0.35ms max=0.87ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.52ms max=0.56ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.30ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.20ms p99=0.29ms max=0.46ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.49ms max=0.51ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.18ms p99=0.29ms max=0.38ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.49ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.32ms max=0.40ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.49ms max=0.51ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.18ms p99=0.27ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.50ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.12ms max=0.14ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.12ms p95=0.20ms p99=0.28ms max=0.40ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.21ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.12ms p95=0.20ms p99=0.30ms max=0.45ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.26ms max=0.34ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.12ms p95=0.20ms p99=0.29ms max=0.44ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.48ms p99=0.49ms max=0.52ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
```

### before, pair 2

```text
cpuFrame: n=600 avg=0.14ms p50=0.11ms p95=0.29ms p99=0.86ms max=1.81ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.48ms p50=0.41ms p95=0.83ms p99=2.72ms max=6.58ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.13ms p50=0.08ms p95=0.16ms p99=1.07ms max=2.24ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.20ms max=0.92ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.13ms p50=0.13ms p95=0.20ms p99=0.34ms max=0.59ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.46ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.13ms p95=0.21ms p99=0.36ms max=0.58ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.34ms p95=0.46ms p99=0.48ms max=0.50ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.13ms p95=0.22ms p99=0.33ms max=0.40ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.34ms p95=0.46ms p99=0.48ms max=0.50ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.11ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.21ms p99=0.31ms max=0.35ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.46ms p99=0.47ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.21ms p99=0.35ms max=0.39ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.34ms p95=0.46ms p99=0.47ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.21ms p99=0.32ms max=0.42ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.46ms p99=0.47ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.22ms p99=0.36ms max=0.57ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.32ms p50=0.33ms p95=0.46ms p99=0.47ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.22ms p99=0.38ms max=0.40ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.32ms p50=0.33ms p95=0.45ms p99=0.46ms max=0.47ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.12ms p99=0.15ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.06ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.17ms p50=0.15ms p95=0.33ms p99=0.47ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.51ms p99=0.57ms max=0.82ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.59ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.11ms p99=0.13ms max=0.22ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.22ms p99=0.36ms max=0.76ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.46ms p99=0.47ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
```

### after, pair 2

```text
cpuFrame: n=600 avg=0.13ms p50=0.10ms p95=0.24ms p99=0.81ms max=1.79ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.47ms p50=0.40ms p95=0.81ms p99=2.21ms max=6.91ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.13ms p50=0.10ms p95=0.16ms p99=1.07ms max=2.00ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.18ms max=0.95ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.27ms max=0.43ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.49ms max=0.64ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.11ms p50=0.11ms p95=0.19ms p99=0.29ms max=0.41ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.49ms max=0.61ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.15ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.24ms max=0.34ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.49ms max=0.56ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.12ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.28ms max=0.46ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.49ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.12ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.12ms p95=0.20ms p99=0.31ms max=0.36ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.58ms max=0.60ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.12ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.20ms p99=0.27ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.34ms p95=0.47ms p99=0.48ms max=0.59ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.12ms p95=0.19ms p99=0.31ms max=0.43ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.47ms p99=0.57ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.21ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.20ms p99=0.30ms max=0.56ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.47ms p99=0.48ms max=0.67ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.13ms p50=0.11ms p95=0.23ms p99=0.37ms max=0.67ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.50ms max=0.59ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.12ms p95=0.19ms p99=0.27ms max=0.37ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.34ms p95=0.48ms p99=0.49ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
```

### before, pair 3

```text
cpuFrame: n=600 avg=0.14ms p50=0.11ms p95=0.33ms p99=0.79ms max=2.43ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.48ms p50=0.41ms p95=0.84ms p99=2.02ms max=6.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.12ms p50=0.08ms p95=0.16ms p99=0.87ms max=3.72ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.34ms max=0.75ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.13ms p50=0.13ms p95=0.21ms p99=0.34ms max=0.56ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.47ms p99=0.49ms max=0.61ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.15ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.15ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.16ms p50=0.14ms p95=0.26ms p99=0.53ms max=0.69ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.36ms p95=0.50ms p99=0.59ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.16ms p99=0.19ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.13ms max=0.30ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.22ms p99=0.33ms max=0.61ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.47ms p99=0.56ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.25ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.13ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.23ms p99=0.34ms max=0.42ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.48ms p99=0.59ms max=0.63ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.10ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.24ms p99=0.38ms max=0.51ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.47ms p99=0.59ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.11ms max=0.23ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.23ms p99=0.39ms max=0.74ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.48ms p99=0.58ms max=0.61ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.16ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.11ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.23ms p99=0.33ms max=0.68ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.33ms p95=0.47ms p99=0.59ms max=0.62ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.10ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.15ms p50=0.14ms p95=0.22ms p99=0.33ms max=0.39ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.34ms p95=0.46ms p99=0.59ms max=0.61ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.17ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.22ms p99=0.31ms max=0.35ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.46ms p99=0.49ms max=0.60ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.14ms p95=0.22ms p99=0.34ms max=0.37ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.33ms p50=0.33ms p95=0.46ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.09ms p50=0.08ms p95=0.14ms p99=0.16ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.09ms p99=0.10ms max=0.16ms rate=0.0/0.0/defaultHz lowPower=false
```

### after, pair 3

```text
cpuFrame: n=600 avg=0.13ms p50=0.10ms p95=0.24ms p99=0.70ms max=1.82ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.45ms p50=0.41ms p95=0.68ms p99=2.44ms max=5.59ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.12ms p50=0.11ms p95=0.17ms p99=0.38ms max=2.06ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.16ms max=0.81ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.25ms max=0.47ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.52ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.15ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.14ms p50=0.12ms p95=0.30ms p99=0.44ms max=0.53ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.50ms p99=0.57ms max=0.65ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.10ms p50=0.08ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.12ms max=0.15ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.20ms p99=0.26ms max=0.44ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.49ms max=0.52ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.16ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.27ms max=0.42ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.50ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.21ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.20ms p99=0.30ms max=0.38ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.27ms max=0.37ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.34ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.14ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.26ms max=0.60ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.46ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.20ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.12ms max=0.15ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.27ms max=0.32ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.34ms p95=0.46ms p99=0.48ms max=0.48ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.10ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.06ms p95=0.10ms p99=0.12ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.20ms p99=0.30ms max=0.41ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.34ms p50=0.35ms p95=0.47ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.19ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.17ms rate=0.0/0.0/defaultHz lowPower=false
cpuFrame: n=600 avg=0.12ms p50=0.11ms p95=0.19ms p99=0.28ms max=0.47ms rate=0.0/0.0/defaultHz lowPower=false
gpu: n=600 avg=0.35ms p50=0.35ms p95=0.48ms p99=0.48ms max=0.49ms rate=0.0/0.0/defaultHz lowPower=false
gpuExecution: n=600 avg=0.11ms p50=0.12ms p95=0.17ms p99=0.18ms max=0.18ms rate=0.0/0.0/defaultHz lowPower=false
gpuFeedbackDelay: n=600 avg=0.07ms p50=0.07ms p95=0.10ms p99=0.11ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
```

## Equal-cadence scripted power pairs

The prior XCTest keyboard loop waits for application idleness for each key;
its observed normal and low-power delivery cadences differed. This follow-up
uses the same guarded CGHID digit injector in both modes: 205 keys, 150 ms
between keys, one 200-valid-presentation ring. Before every key it checks
that the isolated test PID is still foreground and aborts if focus changes.
This is scripted input, **not a substitute for the completed human runs**.
The app uses the final retained displaylink driver, Benchmark, `exec cat
>/dev/null`, cursor blink off, and independent stages. Each pair is normal
then low power, three rounds, mains confirmed at start/end. System Settings
actually toggles Never / Only on Power Adapter; summaries confirm lowPower
false/true. The final setting returns to Never and original input source is
restored. There is no injected power-policy value.

| Pair | Normal p50 / p95 / p99 | Low-power p50 / p95 / p99 |
| --- | --- | --- |
| 1 | 61.46 / 70.96 / 80.50 ms | 61.52 / 69.81 / 71.39 ms |
| 2 | 61.35 / 70.84 / 85.31 ms | 61.48 / 70.58 / 85.05 ms |
| 3 | 61.24 / 69.93 / 145.77 ms | 61.55 / 71.32 / 85.85 ms |

Normal p50 median **61.35 ms**, low-power median **61.52 ms**: difference
**0.17 ms**, within the normal three-run p50 spread **0.22 ms**. This uses
median difference versus run-to-run range, as the earlier normal-mode
non-regression comparison does; it does not claim each low-power p50 lies
between the minimum and maximum normal p50. Pair 3 differs by 0.31 ms and
is retained. The several-frame scripted penalty is absent with matched
input delivery. All rings, including their long first/rare samples, remain:

```text
keypressToPresent: n=200 avg=62.84ms p50=61.46ms p95=70.96ms p99=80.50ms max=154.14ms rate=0.0/0.0/defaultHz lowPower=false
keypressToPresent: n=200 avg=62.66ms p50=61.52ms p95=69.81ms p99=71.39ms max=150.20ms rate=0.0/0.0/defaultHz lowPower=true
keypressToPresent: n=200 avg=62.97ms p50=61.35ms p95=70.84ms p99=85.31ms max=141.58ms rate=0.0/0.0/defaultHz lowPower=false
keypressToPresent: n=200 avg=62.84ms p50=61.48ms p95=70.58ms p99=85.05ms max=129.87ms rate=0.0/0.0/defaultHz lowPower=true
keypressToPresent: n=200 avg=62.87ms p50=61.24ms p95=69.93ms p99=145.77ms max=147.14ms rate=0.0/0.0/defaultHz lowPower=false
keypressToPresent: n=200 avg=63.50ms p50=61.55ms p95=71.32ms p99=85.85ms max=146.56ms rate=0.0/0.0/defaultHz lowPower=true
```

Prior old low-power scripted p50 and old/new human power results remain in
the earlier record. They establish the before penalty and independent real
input confirmation. A 120 Hz panel remains unavailable, expressly allowed
by #282; no 120 Hz measurement is inferred.

## Idle wakeup attribution and platform floor

The previous “metrics-off” launch set `CORTA_RENDER_METRICS=0`, but any
present value enables metrics. That control was mislabeled. Three corrected
launches omit the entire variable. They measure **9 / 8 / 12** interrupts in
**20.012323625 / 20.0130445 / 20.007285417 s** after the input grace:
**0.449723 / 0.399739 / 0.599782 per second**. Thus extra metrics are not
the cause, and strict zero process interrupts is still not a measured result.

Three AppKit/paused-Metal-link controls without GPU submission or Corta code
also have nonzero counters. Adding a minimal NSTextInputClient does not
reproduce Corta's three-second timer, so an IME attribution was rejected.
The decisive probe records timer registration stacks in the isolated signed
Debug app with LLDB. It is an attribution probe, **not a performance run**.
`dispatch_source_set_timer` resolves at the shared timer entry point; the
arm64 interval argument `x2` is **3,000,000,000 ns**. The registration stack:

```text
_dispatch_source_set_runloop_timer_4CF
AGX::Device<AGX::HAL300::Encoders, AGX::HAL300::Classes, AGX::HAL300::ObjClasses>::setupDeferred(AGXG17GFamilyDevice*)
_dispatch_client_callout
_dispatch_once_callout
-[AGXG17GFamilyDevice setupDeferred]
-[AGXG17GFamilyDevice newMTL4CommandQueueWithDescriptor:error:]
Corta.Metal4Backend.init(device: __C.MTLDevice, slotWaitLimit: Dispatch.DispatchTimeInterval) throws -> Corta.Metal4Backend
Corta.Metal4Backend.__allocating_init(device: __C.MTLDevice, slotWaitLimit: Dispatch.DispatchTimeInterval) throws -> Corta.Metal4Backend
Corta.TerminalRenderer.init(device: __C.MTLDevice, font: __C.CTFontRef, scale: CoreGraphics.CGFloat, atlasPixelSize: Swift.Optional<Swift.Int>) throws -> Corta.TerminalRenderer
Corta.TerminalRenderer.__allocating_init(device: __C.MTLDevice, font: __C.CTFontRef, scale: CoreGraphics.CGFloat, atlasPixelSize: Swift.Optional<Swift.Int>) throws -> Corta.TerminalRenderer
Corta.ViewController.makeRenderer(device: __C.MTLDevice, scale: CoreGraphics.CGFloat) throws -> Corta.TerminalRenderer
Corta.ViewController.setUpPane(strictRespawn: Swift.Bool) -> ()
```

This is Apple's AGX deferred GPU-device setup, reached by creation of the
Metal 4 command queue. It matches the prior System Trace's approximately
three-second timer drain/poke cadence. An independent AppKit/Metal control,
with no Corta code or application timer, now creates a standard Metal queue
and commits one empty command buffer. After twelve key events and the grace,
its three 20-second idle windows each contain **7 interrupt wakeups**:
**0.349800 / 0.349820 / 0.349824 per second**. The unprimed input-context
control has **2 / 2 / 4**. GPU initialization alone reproduces a residual
idle counter floor. The controls and registration establish the three-second
GPU-driver timer; they do not map every individual interrupt in Corta one
for one to a particular framework callback.

The earlier System Trace independently establishes a continuously blocked
PTY reader (27.127 s), and valid owned render signposts have no new frames or
commits in the accepted idle windows. Together with the removed 250 ms poll,
these establish application quiescence. The correct acceptance statement is
**no Corta periodic PTY/render work after grace, with an observed AGX/platform
process-wakeup floor**, not “the process counter is exactly zero.” No private
GPU-driver timer or OS setting is disabled to manufacture a zero reading.
This documented platform limit replaces the previously unidentified wakeup
blocker; it is not a claim that the issue's literal absolute-zero wording is
achieved. The default driver remains the issue's explicit fallback.

The independent control source is:

```swift
import AppKit
import QuartzCore
import Metal
final class Input: NSView, NSTextInputClient {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    func insertText(_ string: Any, replacementRange: NSRange) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func hasMarkedText() -> Bool { false }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(NSRect(x: 0,y: 0,width: 1,height: 1)) ?? .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}
}
final class Delegate: NSObject, NSApplicationDelegate, CAMetalDisplayLinkDelegate {
    var window: NSWindow!
    var link: CAMetalDisplayLink?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 800,height: 500),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.title = "Corta isolated framework idle control"
        let input = Input(frame: NSRect(x: 0,y: 0,width: 800,height: 500))
        window.contentView = input
        if CommandLine.arguments.contains("metal") {
            input.wantsLayer = true
            let layer = CAMetalLayer(); layer.device = MTLCreateSystemDefaultDevice(); input.layer = layer
            let queue = layer.device!.makeCommandQueue()!
            let command = queue.makeCommandBuffer()!; command.commit(); command.waitUntilCompleted()
            link = CAMetalDisplayLink(metalLayer: layer); link?.delegate = self
            link?.add(to: .main,forMode: .common); link?.isPaused = true
        }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(input)
        NSApp.activate(ignoringOtherApps: true)
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) { update.drawable.present() }
}
let app = NSApplication.shared
let delegate = Delegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()

```

Local attribution log: `/tmp/corta-idle-timer-registration.jsonl`;
controls: `/tmp/corta-idle-{control,input-context,gpu-control}-summary.json`;
true diagnostics-off samples: `/tmp/corta-true-metrics-off-idle-summary.json`.
The debugger and every isolated control process were stopped.

## Final retained source and checks

Final Benchmark executable SHA-256:
`16017f444d3e80bba3f401686ccc8624a1129176f5be5b89bc1eb59fe788548f`.
The six matched-cadence power runs above use this executable. An additional
corrected four-pane sustained flood on it passes: CPU p99 **0.24 ms**, GPU p99
**0.48 ms**, within the paired baseline's GPU envelope. Result:
`/tmp/corta-sync-final-flood.xcresult`.
Full normal Unit passes **962 tests / 147 suites**, with four already-known
intentional degenerate Metal cases; `/tmp/corta-sync-final-unit.xcresult`.
Core code is unchanged by this measurement/no-sync cleanup; the retained
904 package tests and 500k fuzz run remain applicable.

The already inspected native app checks, real Pinyin ghost suppression and
completed human mains/power/driver pairs remain applicable to the two
retained synchronized drivers. The user did not perform the proposed
continuous tearing observation. No physical-panel universal tear-free claim
is made: the optional path which specifically required that human check,
no-sync, is withdrawn rather than shipped. The captures and native checks
establish no observed content/overlay defects within their stated coverage.

Release disposition: retain displaylink by default, keep synchronized
ondemand as a measurement seam, ship the verified core/cache/policy/PTY/IME
fixes, and preserve negative experiment records and the quantified driver
floor. Default four-pane non-regression and matched-cadence low-power gates
are now established. The proposed merge accepts application quiescence with
the diagnosed platform floor, not a fabricated absolute-zero measurement.
