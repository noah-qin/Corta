# Corta, Ghostty and iTerm2 on one machine — 2026-10-09 (#279)

The cross-terminal baseline the 1.2.0 latency and throughput issues
(#280–#283) are measured against. A bare `§n` below refers to
`PERFORMANCE.md`; §5.5 there keeps the summary.

## The table this replaces

`PERFORMANCE.md` §5.5 until this run — taken before 1.0.0 with the same
external screen-capture tool: 200 characters / 150 ms delay / 50 ms period /
1,000 ms length, synchronous mode, same machine, same font (system
monospaced, 12 pt), power connected, target app frontmost:

| Terminal | Min, ms | Max, ms | Avg, ms | SD, ms |
| -------- | ------- | ------- | ------- | ------ |
| Corta    | 32.8    | 64.1    | 45.4    | 8.1    |
| iTerm2   | 28.1    | 63.0    | 42.7    | 7.7    |
| Ghostty  | 17.8    | 45.2    | 31.9    | 5.9    |

One run each, min/max/avg/SD rather than §5.1's distribution, and §5.2's
environment not recorded. Corta's 45.4 ms matched M6's 45.5 ms, from before
M9.1 moved the frame driver to `CAMetalDisplayLink`
(`2026-09-09-LATENCY-BEFORE-1.0.md`).

## Environment

| Variable | Corta | Ghostty | iTerm2 |
| --- | --- | --- | --- |
| Version | 1.1.9, Release build of `main` at `0f2c107` | 1.3.1 (15212) | 3.6.11 |
| Font, latency runs | system monospaced, **18 pt** | system monospaced, **12 pt** | system monospaced, **18 pt** |
| Font, throughput runs | 18 pt | 18 pt | 18 pt |
| Grid | 120×30, one pane, windowed | 120×30 | 120×30 |
| Cursor | hidden (DECTCEM) by the test program | same | same |
| Cursor blink | off | off | off |
| GPU renderer | always | always | Metal, iTerm2's default (on mains) |
| VSync | default | `window-vsync = true` | default |
| Configuration | scratch `CORTA_STAGE_DIR`, `CORTA_RESTORE_WINDOWS=0` | a config file passed with `--config-default-files=false` | a `corta-bench` dynamic profile, removed afterwards |

Shared: MacBook Air, Apple M5 (Mac17,3), macOS 27.0.1 (26A434); built-in
Retina display, 1470×956 points at 2x, 60 Hz; mains power; Low Power Mode
off; ABC keyboard layout for the latency runs; Xcode 27.0 for the Corta build.

The system monospaced face is SF Mono. Neither Ghostty nor iTerm2 finds it
by that name: Ghostty takes `.AppleSystemUIFontMonospaced`, iTerm2
`.AppleSystemUIFontMonospaced-Regular`, and Ghostty's `+show-face`
confirmed the match.

`script/cross-terminal.swift` (`TESTING.md`, *Against other terminals*)
writes every configuration and launches each terminal with it. Nothing
outside `.build/cross-terminal/` was changed except the iTerm2 dynamic
profile, which `cleanup` removed (D13).

### Where the run departs from #279's plan, and why

- **Font size.** Typometer finds the typed `.` in a half-size (1x) capture
  and then polls one physical pixel of it. At 12 pt, Corta's period does not
  cover that pixel, so the pattern step waits forever. A replay of
  Typometer's own `Metrics.detect` against Corta read the background
  colour at the chosen point while the dot was on screen. At 18 pt it does
  cover it. Ghostty is the reverse: it hung at 18 pt and ran at 12 pt. Font
  size is not on the keypress-to-glass path, so each terminal ran at a
  size Typometer can read, and the table says which.
- **Cursor hidden.** A visible cursor is part of the change Typometer
  measures the dot from. It pulled the watched point above the dot,
  which sits on the baseline. The test program hides the cursor first, in
  all three terminals.
- **"Hung" means 80 s.** Typometer checks its 3 s timeout only once every
  10,000 polls, and a poll costs about 8 ms on this machine, so a miss looks
  like a hang.
- **Corta's grid.** A new Corta window opens short of `rows` (#305). The
  scratch config asks for 32 rows at 18 pt to get 30, and each window was
  checked at 120×30 from its tty (`stty size`).
- **macOS screen capture can wedge.** During the investigation a stuck
  capture left `replayd` unresponsive, and every capture on the machine
  timed out until the stuck processes were killed. None of the numbers
  below was taken in that state.

## Keypress → glass

Typometer 1.0.1 on Temurin 25.0.4: 200 characters, 150 ms delay,
synchronous, no intermediate pauses. Native API is unavailable on macOS.
Three runs per terminal, 200 samples each. The export's column order is
Corta, iTerm2, Ghostty for each of the three rounds, so the rounds were
probably not alternated as #279 asked. The raw CSV is the record of what
ran.

| Terminal | n | p50 | p95 | p99 | max | min | avg | SD |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Corta** | 600 | **60.4** | 79.6 | 81.2 | 82.3 | 47.4 | 61.0 | 10.1 |
| iTerm2 | 600 | 38.5 | 56.7 | 60.8 | 69.3 | 31.6 | 42.0 | 8.0 |
| Ghostty | 600 | **34.5** | 39.7 | 43.7 | 50.1 | 16.4 | 31.0 | 7.5 |

Milliseconds. The p50 of each run:

| Terminal | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Corta | 61.1 | 59.8 | 59.1 |
| iTerm2 | 38.0 | 38.8 | 38.2 |
| Ghostty | 35.1 | 35.0 | 33.2 |

Reading:

- **Corta trails Ghostty by 26 ms at p50, about one and a half 60 Hz frames.**
  The pre-1.0 gap was 13.5 ms (avg). Corta's fastest sample (47.4 ms) is
  slower than Ghostty's slowest (50.1 ms), so the difference is a fixed wait
  in the path, not jitter. This is #280's baseline.
- **Corta now trails iTerm2 by 22 ms at p50.** Before 1.0 the two were within
  each other's spread.
- iTerm2 and Ghostty reproduce their pre-1.0 averages (42.0 against 42.7,
  31.0 against 31.9). That supports reading the change in Corta's figure
  as Corta's, not the tool's.

## Calibration against `keypressToPresent`

One more Typometer run on Corta, launched with
`CORTA_RENDER_METRICS=<file>`, so the same keystrokes produced both
figures:

| Measure | n | p50 | p95 | p99 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Typometer (external) | 200 | 52.6 | 65.7 | 76.8 | 78.9 |
| `keypressToPresent`, first summary | 200 | 66.9 | 110.7 | 119.2 | 157.1 |
| `keypressToPresent`, second summary | 200 | 66.4 | 108.3 | 119.8 | 140.4 |

- **At p50, the in-app figure reads about 14 ms above the external one.**
  Subtract it to put a §5.7 in-app p50 on the external scale.
- The tails do not translate. The in-app summaries count every key
  Typometer sends, including the backspaces it deletes with in a burst at
  the end. Those queue behind each other; the external figure times only
  the typed characters.
- The external p50 of this run, 52.6 ms, sits below the three runs above
  (59–61 ms). Whether `CORTA_RENDER_METRICS` itself changes the frame
  timing, or this is run-to-run drift, was not settled. Re-take the offset
  together with the next in-app run that relies on it.
- In the same session: `cpuFrame` p50 0.32 ms and `gpu` p50 1.16 ms. As
  #280 says, the frame's own work is a rounding error of the latency.

## Throughput

`alacritty/vtebench` at `ead80032e57d` (2025-01-09), its default set, with
the default 10 s per case and 1 MiB per sample. Then `cat` of a 100 MiB file
three times, with wall-clock timestamps taken inside the terminal. The file
uses `corta-bench`'s `makeCorpus` line shape (SGR-coloured `ls`-style lines).
Three rounds in the order A B C, C B A, A B C, with the window frontmost
and the machine untouched.

vtebench, milliseconds per 1 MiB sample (lower is faster). Each figure is
the median of each run's samples, then the median of the three runs:

| Case | Corta | Ghostty | iTerm2 |
| --- | ---: | ---: | ---: |
| `dense_cells` | 10 | 7 | 80 |
| `medium_cells` | 11 | 10 | 417 |
| `sync_medium_cells` | 14 | 14 | 346 |
| `scrolling` | 30 | 17 | 21 |
| `scrolling_bottom_region` | 30 | 17 | 452 |
| `scrolling_bottom_small_region` | 30 | 17 | 452 |
| `scrolling_top_region` | 79 | 22 | 2,040 |
| `scrolling_top_small_region` | 30 | 21 | 453 |
| `scrolling_fullscreen` | 23 | 25 | 36 |
| `unicode` | 36 | 9 | 50 |

`cat` of 100 MiB, MiB/s:

| Terminal | Median | Every timing |
| --- | ---: | --- |
| Corta | 88 | 95, 96, 96 · 84, 89, 88 · 83, 87, 87 |
| Ghostty | 76 | 90, 89, 89 · 75, 76, 76 · 72, 74, 72 |
| iTerm2 | 17 | 17 in all nine |

Reading:

- **Scrolling is where Corta trails Ghostty.** Plain and bottom-region
  scrolling run at 30 against 17. A top-anchored region, the shape `vim` and
  `less` produce, runs at 79 against 22. Those are #281 (row reuse) and #283
  (shifting the render cache for a region) respectively.
- `unicode` is four times Ghostty's figure (36 against 9). No open issue
  covers it.
- Corta is the fastest of the three at `cat` of a large file and at
  `scrolling_fullscreen`. Dense and medium cell updates are within one or two
  milliseconds of Ghostty.

`cursor_motion` and `light_cells` did not run in any terminal. Their
generator scripts read the grid with `tput cols < $tty`, which yields
nothing on macOS. The scripts then emit an empty payload, and vtebench
silently drops a case it cannot load.

## Not measured

- **120 Hz.** The only panel is the MacBook Air's 60 Hz display. Nothing
  here says anything about 120 Hz.
- **Full screen.** Optional in #279; not taken.
- **Terminal.app.** Not in #279's scope.
- **Whether the latency rounds alternated.** See above.

## Done by a person

- Granting Terminal.app Accessibility and Screen Recording for Typometer:
  done. No permission prompt appeared during the run.
- Typing: none needed. Typometer types.
- Choosing iTerm2's dynamic profile for each window: done for every run.
- Switching the input source to ABC for the latency runs: done.
