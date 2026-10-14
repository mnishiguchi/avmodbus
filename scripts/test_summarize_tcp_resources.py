"""Host-only regression tests; run with python3 -m unittest discover -s scripts."""

import contextlib
import csv
import io
import tempfile
import unittest
from pathlib import Path

from summarize_tcp_resources import main, parse_log


LOG = """I (123) AtomVM: boot
modbus_resource_probe cycle=1 connections=2 processes=4/12/30/4 free_heap=180000/170000/158000/179000 largest_free=70000/65000/59000/69000
modbus_resource_probe cycle=2 connections=2 processes=4/12/30/4 free_heap=179000/169000/156000/178000 largest_free=68000/62000/58000/67000
modbus_resource_probe result=ok cycles=2
"""


class ReportTest(unittest.TestCase):
    def test_parses_exact_cycles_and_deltas(self):
        rows = parse_log(LOG, "build-1", "8d3e051", "XIAO ESP32-C5", "log.txt")
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["idle_heap_delta"], 10000)
        self.assertEqual(rows[0]["active_heap_delta"], 22000)
        self.assertEqual(rows[1]["active_heap_delta"], 23000)
        self.assertTrue(all(r["processes_recovered"] for r in rows))

    def test_rejects_incomplete_or_failed_logs(self):
        for invalid in (
            LOG.replace("cycle=2", "cycle=1"),
            LOG.replace("result=ok", "result=error"),
            LOG.replace("cycles=2", "cycles=3"),
            LOG.replace("modbus_resource_probe result=ok cycles=2", ""),
        ):
            with self.subTest(invalid=invalid[-80:]), self.assertRaises(ValueError):
                parse_log(invalid, "build", "ref", "board", "log")

    def test_csv_append_and_header_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "monitor.log"
            report = Path(directory) / "report.csv"
            log.write_text(LOG, encoding="utf-8")
            args = [str(log), "--label", "build", "--atomvm-ref", "tag", "--device", "board", "--output", str(report)]
            self.assertEqual(main(args), 0)
            self.assertEqual(main(args + ["--append"]), 0)
            with report.open(newline="", encoding="utf-8") as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual(len(rows), 4)
            self.assertEqual(rows[0]["active_heap_delta"], "22000")
            report.write_text("bad,header\n", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    main(args + ["--append"])
            self.assertEqual(caught.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
