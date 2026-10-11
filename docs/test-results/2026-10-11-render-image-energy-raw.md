# Raw excerpts: #291 / #284 / #290 (2026-10-11)

## D17

`corta-final-d17-before-1.txt`

```text
frame CPU time (120x40, full screen, Release, -O): avg 0.456 ms, p50 0.437 ms, p95 0.900 ms, p99 1.301 ms, max 1.301 ms, over 60 iterations
```

`corta-final-d17-after-1.txt`

```text
frame CPU time (120x40, full screen, Release, -O): avg 0.355 ms, p50 0.335 ms, p95 0.517 ms, p99 1.032 ms, max 1.032 ms, over 60 iterations
```

`corta-final-d17-before-2.txt`

```text
frame CPU time (120x40, full screen, Release, -O): avg 0.370 ms, p50 0.336 ms, p95 0.705 ms, p99 1.120 ms, max 1.120 ms, over 60 iterations
```

`corta-final-d17-after-2.txt`

```text
frame CPU time (120x40, full screen, Release, -O): avg 0.381 ms, p50 0.335 ms, p95 0.699 ms, p99 1.239 ms, max 1.239 ms, over 60 iterations
```

`corta-final-d17-before-3.txt`

```text
frame CPU time (120x40, full screen, Release, -O): avg 0.342 ms, p50 0.331 ms, p95 0.516 ms, p99 1.037 ms, max 1.037 ms, over 60 iterations
```

`corta-final-d17-after-3.txt`

```text
frame CPU time (120x40, full screen, Release, -O): avg 0.356 ms, p50 0.334 ms, p95 0.568 ms, p99 0.972 ms, max 0.972 ms, over 60 iterations
```

## Large-image proxy

`corta-image-measurement-tiled.log`

```text
4096 PNG decode+texture ms=70.533208 baseline=141394760 peak parent=426820664 delta=285425904 peak helper=202785512
4096 PNG decode+texture ms=46.728666 baseline=141394760 peak parent=243647328 delta=102252568 peak helper=136151784
4096 PNG decode+texture ms=65.496667 baseline=141263664 peak parent=426689568 delta=285425904 peak helper=201016040
4096 PNG decode+texture ms=43.884917 baseline=141230896 peak parent=243483464 delta=102252568 peak helper=136872656
4096 PNG decode+texture ms=65.192792 baseline=141214488 peak parent=426640392 delta=285425904 peak helper=205243112
4096 PNG decode+texture ms=42.716833 baseline=141263664 peak parent=243516232 delta=102252568 peak helper=136970960
```

## Full UV sampling

`corta-linear-sampling-isolated.txt`

```text
4096x4096 BGRA sampled to 1024x768; submission-to-completion, same gpu metric boundary
linear: p50=0.654125 p95=1.458791 p99=2.005583 ms
tiled: p50=1.13075 p95=2.066417 p99=2.097167 ms
private: p50=0.49075 p95=1.849416 p99=1.879792 ms
```

## Reader QoS

`corta-qos-interactive.log`

```text
reader QoS benchmark: user-initiated, set=0
feed throughput, `yes` lines, no snapshotter: 86.4 MiB/s median of 3 (86.4 / 86.4 / 84.3)
feed throughput, `yes` lines, 60 Hz, released at once: 84.8 MiB/s median of 3 (85.5 / 84.8 / 83.4)
feed throughput, `yes` lines, 60 Hz, held to the next tick: 83.7 MiB/s median of 3 (84.9 / 83.7 / 82.9)
feed throughput, 200-column lines, no snapshotter: 589.5 MiB/s median of 3 (555.8 / 589.7 / 589.5)
feed throughput, 200-column lines, 60 Hz, released at once: 541.4 MiB/s median of 3 (540.0 / 553.3 / 541.4)
feed throughput, 200-column lines, 60 Hz, held to the next tick: 537.4 MiB/s median of 3 (537.4 / 532.1 / 538.7)
one 200-column line into a full scrollback, nothing sharing it: p50 0.000 ms / p95 0.000 ms / p99 0.001 ms / max 0.001 ms (mean 0.000 ms, 1000 samples)
the same line with a snapshot alive (the copy-on-write): p50 0.008 ms / p95 0.017 ms / p99 0.019 ms / max 0.022 ms (mean 0.009 ms, 1000 samples)
write backpressure (child not reading): caller-side cost of 1 MB write with full pty buffer: 0.0 ms (96 MB pre-fill cost the caller 0.0 ms in total)
reader interactive: qos-producer p50=12.6us p99=21.5us max=142.7us over1ms=0
reader interactive: qos-producer p50=13.0us p99=23.9us max=63.9us over1ms=0
reader interactive: qos-producer p50=13.0us p99=22.5us max=46.0us over1ms=0
```

`corta-qos-utility.log`

```text
reader QoS benchmark: utility, set=0
feed throughput, `yes` lines, no snapshotter: 86.6 MiB/s median of 3 (86.8 / 86.6 / 86.3)
feed throughput, `yes` lines, 60 Hz, released at once: 85.2 MiB/s median of 3 (85.3 / 85.2 / 84.7)
feed throughput, `yes` lines, 60 Hz, held to the next tick: 84.7 MiB/s median of 3 (84.8 / 84.7 / 84.2)
feed throughput, 200-column lines, no snapshotter: 591.4 MiB/s median of 3 (581.6 / 601.6 / 591.4)
feed throughput, 200-column lines, 60 Hz, released at once: 563.6 MiB/s median of 3 (548.5 / 563.6 / 571.5)
feed throughput, 200-column lines, 60 Hz, held to the next tick: 548.3 MiB/s median of 3 (538.3 / 548.3 / 550.5)
one 200-column line into a full scrollback, nothing sharing it: p50 0.000 ms / p95 0.000 ms / p99 0.000 ms / max 0.006 ms (mean 0.000 ms, 1000 samples)
the same line with a snapshot alive (the copy-on-write): p50 0.008 ms / p95 0.014 ms / p99 0.016 ms / max 0.023 ms (mean 0.008 ms, 1000 samples)
write backpressure (child not reading): caller-side cost of 1 MB write with full pty buffer: 0.0 ms (96 MB pre-fill cost the caller 0.0 ms in total)
reader background: qos-producer p50=13.0us p99=24.2us max=73.9us over1ms=0
reader background: qos-producer p50=13.0us p99=22.9us max=86.2us over1ms=0
reader background: qos-producer p50=12.9us p99=21.6us max=48.0us over1ms=0
```

## Thread lifecycle UI metrics

```text
measurement: machine: Mac17,3 / Apple M5; macOS Version 27.0.1 (Build 26A434)
measurement: build: Release, -O
measurement: max drawables: default; frame latency: default
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:129: Test Case '-[CortaUITests.MeasurementUITests testFloodFourPanes]' measured [Absolute Memory Physical (dev), kB] average: 176151.970, relative standard deviation: 0.005%, values: [176145.416000, 176145.416000, 176145.416000, 176161.800000, 176161.800000], performanceMetricID:com.apple.dt.XCTMetric_Memory-dev.noahqin.Corta.dev.physical_absolute, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:129: Test Case '-[CortaUITests.MeasurementUITests testFloodFourPanes]' measured [CPU Time (dev), s] average: 15.949, relative standard deviation: 1.062%, values: [15.716371, 15.876645, 16.180556, 15.867033, 16.102991], performanceMetricID:com.apple.dt.XCTMetric_CPU-dev.noahqin.Corta.dev.time, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:129: Test Case '-[CortaUITests.MeasurementUITests testFloodFourPanes]' measured [Memory Physical (dev), kB] average: 29.491, relative standard deviation: 173.561%, values: [131.072000, 0.000000, 0.000000, 16.384000, 0.000000], performanceMetricID:com.apple.dt.XCTMetric_Memory-dev.noahqin.Corta.dev.physical, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
measurement: 4-pane flood cpuFrame: n=600 avg=0.15ms p50=0.15ms p95=0.27ms p99=0.34ms max=0.37ms rate=0.0/0.0/defaultHz lowPower=false
measurement: 4-pane flood gpu: n=600 avg=0.40ms p50=0.38ms p95=0.62ms p99=0.94ms max=1.20ms rate=0.0/0.0/defaultHz lowPower=false
Test Case '-[CortaUITests.MeasurementUITests testFloodFourPanes]' passed (50.550 seconds).
measurement: machine: Mac17,3 / Apple M5; macOS Version 27.0.1 (Build 26A434)
measurement: build: Release, -O
measurement: max drawables: default; frame latency: default
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:129: Test Case '-[CortaUITests.MeasurementUITests testFloodTwoPanes]' measured [Absolute Memory Physical (dev), kB] average: 154200.662, relative standard deviation: 0.009%, values: [154223.600000, 154190.832000, 154190.832000, 154190.832000, 154207.216000], performanceMetricID:com.apple.dt.XCTMetric_Memory-dev.noahqin.Corta.dev.physical_absolute, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:129: Test Case '-[CortaUITests.MeasurementUITests testFloodTwoPanes]' measured [CPU Time (dev), s] average: 8.266, relative standard deviation: 0.063%, values: [8.262291, 8.259964, 8.263964, 8.269875, 8.274072], performanceMetricID:com.apple.dt.XCTMetric_CPU-dev.noahqin.Corta.dev.time, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:129: Test Case '-[CortaUITests.MeasurementUITests testFloodTwoPanes]' measured [Memory Physical (dev), kB] average: 6.554, relative standard deviation: 406.202%, values: [49.152000, -32.768000, 0.000000, 0.000000, 16.384000], performanceMetricID:com.apple.dt.XCTMetric_Memory-dev.noahqin.Corta.dev.physical, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
measurement: 2-pane flood cpuFrame: n=600 avg=0.06ms p50=0.06ms p95=0.11ms p99=0.12ms max=0.13ms rate=0.0/0.0/defaultHz lowPower=false
measurement: 2-pane flood gpu: n=600 avg=0.51ms p50=0.51ms p95=0.56ms p99=0.59ms max=0.63ms rate=0.0/0.0/defaultHz lowPower=false
Test Case '-[CortaUITests.MeasurementUITests testFloodTwoPanes]' passed (41.112 seconds).
measurement: machine: Mac17,3 / Apple M5; macOS Version 27.0.1 (Build 26A434)
measurement: build: Release, -O
measurement: max drawables: default; frame latency: default
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:84: Test Case '-[CortaUITests.MeasurementUITests testIdleCPU]' measured [CPU Time (dev), s] average: 0.001, relative standard deviation: 140.386%, values: [0.000481, 0.003114, 0.000412, 0.000060, 0.000058], performanceMetricID:com.apple.dt.XCTMetric_CPU-dev.noahqin.Corta.dev.time, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
Test Case '-[CortaUITests.MeasurementUITests testIdleCPU]' passed (30.066 seconds).
measurement: machine: Mac17,3 / Apple M5; macOS Version 27.0.1 (Build 26A434)
measurement: build: Release, -O
measurement: max drawables: default; frame latency: default
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:200: Test Case '-[CortaUITests.MeasurementUITests testOpenAndCloseWindowReturnsMemory]' measured [Memory Physical (dev), kB] average: 62.259, relative standard deviation: 184.886%, values: [262.144000, 114.688000, -32.768000, -49.152000, 16.384000], performanceMetricID:com.apple.dt.XCTMetric_Memory-dev.noahqin.Corta.dev.physical, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/noah/Developer/personal/Corta/CortaUITests/MeasurementUITests.swift:200: Test Case '-[CortaUITests.MeasurementUITests testOpenAndCloseWindowReturnsMemory]' measured [Absolute Memory Physical (dev), kB] average: 104291.746, relative standard deviation: 0.038%, values: [104236.040000, 104350.728000, 104317.960000, 104268.808000, 104285.192000], performanceMetricID:com.apple.dt.XCTMetric_Memory-dev.noahqin.Corta.dev.physical_absolute, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
Test Case '-[CortaUITests.MeasurementUITests testOpenAndCloseWindowReturnsMemory]' passed (49.214 seconds).
```

## Test results

```text
corta-issues-unit-final.log
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
━ Test run with 979 tests in 151 suites passed after 14.189 seconds with 4 known issues.
	/Users/noah/Developer/personal/Corta/.build/unit/Logs/Test/Test-Corta-2026.10.11_13-48-09-+0800.xcresult
corta-issues-core-final.log
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
✔ Test run with 13 tests in 2 suites passed after 0.003 seconds.
✔ Test run with 22 tests in 5 suites passed after 0.078 seconds.
✔ Test run with 756 tests in 79 suites passed after 26.480 seconds.
✔ Test run with 125 tests in 10 suites passed after 2.338 seconds.
corta-issues-tsan.log
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
✔ Test run with 23 tests in 4 suites passed after 0.194 seconds.
	/Users/noah/Developer/personal/Corta/.build/tsan/Logs/Test/Test-Corta-2026.10.11_13-45-45-+0800.xcresult
corta-cursor-fixed-test.log
	 Executed 2 tests, with 0 failures (0 unexpected) in 26.750 (26.751) seconds
	 Executed 2 tests, with 0 failures (0 unexpected) in 26.750 (26.752) seconds
	 Executed 2 tests, with 0 failures (0 unexpected) in 26.750 (26.752) seconds
	/Users/noah/Developer/personal/Corta/.build/ui/Logs/Test/Test-Corta-2026.10.11_13-45-04-+0800.xcresult
corta-cursor-thread-test.log
	 Executed 2 tests, with 0 failures (0 unexpected) in 30.623 (30.624) seconds
	 Executed 2 tests, with 0 failures (0 unexpected) in 30.623 (30.625) seconds
	 Executed 2 tests, with 0 failures (0 unexpected) in 30.623 (30.626) seconds
	/Users/noah/Developer/personal/Corta/.build/ui/Logs/Test/Test-Corta-2026.10.11_13-45-55-+0800.xcresult
corta-thread-lifecycle.log
	 Executed 4 tests, with 0 failures (0 unexpected) in 170.942 (170.944) seconds
	 Executed 4 tests, with 0 failures (0 unexpected) in 170.942 (170.944) seconds
	 Executed 4 tests, with 0 failures (0 unexpected) in 170.942 (170.945) seconds
	/Users/noah/Developer/personal/Corta/.build/perf/Logs/Test/Test-Corta-2026.10.11_13-47-29-+0800.xcresult
```

## Final build and document check

```text
BUILD SUCCEEDED; script --verify returned application PID 58102
DocumentationDriftTests: 5 tests in 1 suite passed
corta-license check: 670 files checked; every header is in place
```
