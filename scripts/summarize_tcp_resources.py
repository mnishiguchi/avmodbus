#!/usr/bin/env python3
"""Turn successful AtomVM TCP resource probe logs into comparable CSV rows.

Uses only the Python standard library; neither this script nor its output is
included in the AtomVM application. Logs remain the source of truth.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

SAMPLE = re.compile(
    r"\bmodbus_resource_probe cycle=(?P<cycle>\d+) "
    r"connections=(?P<connections>\d+) "
    r"processes=(?P<processes>\d+/\d+/\d+/\d+) "
    r"free_heap=(?P<free_heap>\d+/\d+/\d+/\d+) "
    r"largest_free=(?P<largest_free>\d+/\d+/\d+/\d+)"
)
SUCCESS = re.compile(r"\bmodbus_resource_probe result=ok cycles=(\d+)")
FAILURE = re.compile(r"\bmodbus_resource_probe result=error\b")
FIELDS = [
    "label", "atomvm_ref", "device", "source", "cycle", "connections",
    "processes_before", "processes_idle", "processes_active", "processes_cleanup",
    "free_heap_before", "free_heap_idle", "free_heap_active", "free_heap_cleanup",
    "largest_free_before", "largest_free_idle", "largest_free_active", "largest_free_cleanup",
    "idle_heap_delta", "active_heap_delta", "processes_recovered",
]


def parse_log(text, label, atomvm_ref, device, source):
    """Return resource rows, or fail if the log is incomplete or reports error."""
    if FAILURE.search(text):
        raise ValueError(f"{source}: probe reports result=error")

    successes = [int(match.group(1)) for match in SUCCESS.finditer(text)]
    samples = list(SAMPLE.finditer(text))
    if len(successes) != 1:
        raise ValueError(f"{source}: expected exactly one result=ok marker")
    if len(samples) != successes[0]:
        raise ValueError(
            f"{source}: expected {successes[0]} cycles, found {len(samples)}"
        )

    rows = []
    seen_cycles = set()
    for match in samples:
        cycle = int(match.group("cycle"))
        if cycle in seen_cycles or cycle < 1:
            raise ValueError(f"{source}: repeated or invalid cycle {cycle}")
        seen_cycles.add(cycle)

        row = {
            "label": label,
            "atomvm_ref": atomvm_ref,
            "device": device,
            "source": source,
            "cycle": cycle,
            "connections": int(match.group("connections")),
        }
        for field in ("processes", "free_heap", "largest_free"):
            before, idle, active, cleanup = map(int, match.group(field).split("/"))
            row[f"{field}_before"] = before
            row[f"{field}_idle"] = idle
            row[f"{field}_active"] = active
            row[f"{field}_cleanup"] = cleanup

        row["idle_heap_delta"] = row["free_heap_before"] - row["free_heap_idle"]
        row["active_heap_delta"] = row["free_heap_before"] - row["free_heap_active"]
        row["processes_recovered"] = (
            row["processes_cleanup"] <= row["processes_before"] + 1
        )
        rows.append(row)

    if seen_cycles != set(range(1, successes[0] + 1)):
        raise ValueError(f"{source}: cycles are not consecutive from 1")
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path, help="complete captured monitor logs")
    parser.add_argument("--label", required=True, help="firmware/build label or commit")
    parser.add_argument("--atomvm-ref", required=True, help="exact AtomVM tag or commit")
    parser.add_argument("--device", required=True, help="board and transceiver configuration")
    parser.add_argument("--output", type=Path, help="CSV path (default: stdout)")
    parser.add_argument("--append", action="store_true", help="append rows to existing CSV")
    args = parser.parse_args(argv)
    if args.append and not args.output:
        parser.error("--append requires --output")

    try:
        rows = [
            row
            for path in args.logs
            for row in parse_log(
                path.read_text(encoding="utf-8", errors="replace"),
                args.label, args.atomvm_ref, args.device, path.name,
            )
        ]
        if args.output:
            exists = args.output.exists() and args.output.stat().st_size > 0
            if args.append and exists:
                with args.output.open(encoding="utf-8") as existing:
                    header = existing.readline().rstrip("\r\n")
                if header != ",".join(FIELDS):
                    raise ValueError(f"{args.output}: unexpected CSV header")
            with args.output.open("a" if args.append else "w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=FIELDS)
                if not (args.append and exists):
                    writer.writeheader()
                writer.writerows(rows)
        else:
            writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
    except (OSError, ValueError) as error:
        parser.exit(1, f"resource report: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
