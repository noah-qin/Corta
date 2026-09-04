#!/bin/bash
# The five-minute pass, no Instruments needed: launches the Release build
# with CORTA_RENDER_METRICS=1 and streams its p50/p99 dumps as they land
# (RenderMetrics.swift — a 600-sample ring buffer per stage, ~10s of
# continuous frames at 60Hz, dumped to the unified log the moment it fills).
#
# Answers, without Typometer: whether drawableWait is worth an M8.18 A/B
# at all (Step 2's job if it is), and gives a cpuFrame/gpu sanity check
# for M9 before spending time on a full Typometer run.
#
# Usage: scripts/measure-render-metrics.sh
#   Then, in the launched Corta window: hold a key to auto-repeat for
#   ~10s (fills cpuFrame/gpu), and scroll a long file or run `yes` for a
#   few seconds (fills drawableWait). Ctrl-C here when done.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=$("$repo_root/scripts/find-release-app.sh")
echo "==> Using $app"

echo "==> Streaming dev.noahqin.Corta / render-metrics (Ctrl-C to stop)"
log stream --predicate 'subsystem == "dev.noahqin.Corta" AND category == "render-metrics"' &
log_pid=$!
trap 'kill "$log_pid" 2>/dev/null; wait "$log_pid" 2>/dev/null || true' EXIT

sleep 1
echo "==> Launching Corta with CORTA_RENDER_METRICS=1"
CORTA_RESTORE_WINDOWS=0 CORTA_RENDER_METRICS=1 "$app/Contents/MacOS/Corta" &
app_pid=$!

echo "==> Corta is running (pid $app_pid). Type, scroll, flood output — Ctrl-C here to stop both."
wait "$app_pid"
