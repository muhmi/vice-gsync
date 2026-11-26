#!/usr/bin/env python3
"""Summarise VICE_PRESENT_STATS logs of the GTK3 GL and Metal renderers.

Usage: present_stats.py [--skip SECONDS] [--display-hz HZ] LOG [LOG ...]
"""

import argparse
import csv
import math
import sys


def load(path, skip_s):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit(f"{path}: no presents")
    start = float(rows[0]["done_ms"]) + skip_s * 1000.0
    return [r for r in rows if float(r["done_ms"]) >= start]


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100.0 * (len(ordered) - 1))))]


def sd_of(values):
    mean = sum(values) / len(values)
    return math.sqrt(sum((v - mean) ** 2 for v in values) / len(values))


def new_intervals(rows, column):
    previous = None
    result = []
    for row in rows:
        if row["kind"] == "D":
            previous = None
        elif row["kind"] == "N":
            now = float(row[column])
            if now <= 0:
                continue
            if previous is not None:
                result.append(now - previous)
            previous = now
    return result


def realtime_ratio(rows, column):
    intervals = new_intervals(rows, column)
    if not intervals:
        raise ValueError("fewer than two measured new frames")
    hz = float(next(r["emulated_hz"] for r in reversed(rows) if r["kind"] == "N"))
    return sum(intervals) / len(intervals) * hz / 1000.0


def summarise(path, rows, display_hz, max_interval_ratio=None):
    new = [r for r in rows if r["kind"] == "N"]
    hz = float(new[-1]["emulated_hz"]) if new else 0.0
    nominal = 1000.0 / hz if hz > 1.0 else 20.0
    done = [float(r["done_ms"]) for r in new]
    intervals = new_intervals(rows, "done_ms")
    if not intervals:
        sys.exit(f"{path}: fewer than two new frames")
    ready = [float(r["ready_ms"]) for r in new]
    calls = [b - a for a, b in zip(ready, ready[1:])]
    present = [float(r["done_ms"]) - float(r["ready_ms"]) for r in rows]
    mean = sum(intervals) / len(intervals)
    sd = sd_of(intervals)
    latency = [float(r["done_ms"]) - float(r["completed_ms"]) for r in new]
    paced = [r for r in rows if float(r["target_ms"]) > 0.0]
    wake = [float(r["ready_ms"]) - float(r["target_ms"]) for r in paced]
    dropped = int(rows[-1]["dropped"]) - int(rows[0]["dropped"])

    print(f"== {path}")
    print(f"span {(done[-1] - done[0]) / 1000.0:.1f} s, emulated {hz:.3f} Hz ({nominal:.3f} ms)")
    print(f"presents: new {len(new)}, repeat {sum(r['kind'] == 'R' for r in rows)}, "
          f"redraw {sum(r['kind'] == 'D' for r in rows)}, dropped {dropped}")
    print(f"new-frame interval ms: mean {mean:.3f} sd {sd:.3f} min {min(intervals):.3f} "
          f"p1 {percentile(intervals, 1):.3f} p99 {percentile(intervals, 99):.3f} max {max(intervals):.3f}")
    print(f"new-frame present call interval ms: sd {sd_of(calls):.3f} p1 {percentile(calls, 1):.3f} "
          f"p99 {percentile(calls, 99):.3f}")
    print(f"present call->return ms: mean {sum(present) / len(present):.3f} "
          f"p99 {percentile(present, 99):.3f} max {max(present):.3f}")
    print(f"late (>1.5 frames) {sum(i > nominal * 1.5 for i in intervals)}, "
          f"bunched (<0.5 frames) {sum(i < nominal * 0.5 for i in intervals)}")
    print(f"latency completed->present return ms: mean {sum(latency) / len(latency):.2f} "
          f"p99 {percentile(latency, 99):.2f} max {max(latency):.2f}")
    if wake:
        print(f"paced presents {len(paced)}, call minus target ms: mean {sum(wake) / len(wake):.3f} "
              f"p99 {percentile(wake, 99):.3f} max {max(wake):.3f}")

    print("interval histogram (1 ms bins):")
    bins = {}
    for i in intervals:
        bins[int(i)] = bins.get(int(i), 0) + 1
    peak = max(bins.values())
    for b in range(min(bins), max(bins) + 1):
        n = bins.get(b, 0)
        print(f"  {b:3d}-{b + 1:<3d} {n:6d} {'#' * int(round(50.0 * n / peak))}")

    if display_hz:
        refresh = 1000.0 / display_hz
        counts = {}
        for i in intervals:
            k = int(round(i / refresh))
            counts[k] = counts.get(k, 0) + 1
        shown = ", ".join(f"{k}: {counts[k]}" for k in sorted(counts))
        print(f"interval in {display_hz:g} Hz refreshes ({refresh:.3f} ms): {shown}")
    column = "done_ms"
    coverage = True
    if "presented_ms" in rows[0]:
        column = "presented_ms"
        positive = [r for r in rows if r["status"] == "presented" and float(r["presented_ms"]) > 0]
        coverage = len(positive) == len(rows)
        print(f"Metal actual presentation coverage: {len(positive)}/{len(rows)}")
        for status in sorted({r["status"] for r in rows}):
            print(f"  {status}: {sum(r['status'] == status for r in rows)}")
        actual = new_intervals(rows, column)
        if actual:
            print(f"actual new-frame interval ms: mean {sum(actual) / len(actual):.6f} "
                  f"sd {sd_of(actual):.6f} late {sum(i > nominal * 1.5 for i in actual)}")
            latency = [float(r[column]) - float(r["completed_ms"]) for r in positive if r["kind"] == "N"]
            print(f"actual completed->presented latency ms: mean {sum(latency) / len(latency):.6f}")
    try:
        ratio = realtime_ratio(rows, column)
    except ValueError as error:
        print(f"real-time: FAIL ({error})")
        return False
    print(f"new-frame mean interval/nominal: {ratio:.9f}; nominal/mean: {1 / ratio:.9f}")
    passed = coverage and (max_interval_ratio is None or ratio <= max_interval_ratio)
    if max_interval_ratio is not None:
        print(f"real-time: {'PASS' if passed else 'FAIL'} (maximum ratio {max_interval_ratio:.9f})")
    print()
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--skip", type=float, default=5.0,
                        help="seconds at the start to leave out (autostart, warp); default 5")
    parser.add_argument("--display-hz", type=float, default=0.0,
                        help="also count intervals in refreshes of a display at this rate")
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--max-interval-ratio", type=float,
                        help="fail above this mean new-frame interval / nominal ratio; derive from GL controls")
    args = parser.parse_args()
    passed = True
    for path in args.logs:
        passed = summarise(path, load(path, args.skip), args.display_hz, args.max_interval_ratio) and passed
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
