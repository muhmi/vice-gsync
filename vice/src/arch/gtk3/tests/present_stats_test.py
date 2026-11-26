import importlib.util
from pathlib import Path
import unittest
from contextlib import redirect_stdout
import io

spec = importlib.util.spec_from_file_location("present_stats", Path(__file__).parent.parent / "present_stats.py")
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)


class RealTimeTest(unittest.TestCase):
    def test_smooth_slowdown_is_not_real_time(self):
        nominal = 19.95
        rows = [{"kind": "N", "done_ms": str(1000 + i * nominal / 0.9),
                 "ready_ms": str(1000 + i * nominal / 0.9), "completed_ms": str(999 + i * nominal / 0.9),
                 "target_ms": "0", "dropped": "0", "emulated_hz": str(1000 / nominal)} for i in range(3000)]
        intervals = stats.new_intervals(rows, "done_ms")
        self.assertEqual(sum(i > nominal * 1.5 for i in intervals), 0)
        self.assertAlmostEqual(stats.realtime_ratio(rows, "done_ms"), 1 / 0.9)
        with redirect_stdout(io.StringIO()):
            self.assertFalse(stats.summarise("slow", rows, 0, 1.001))

    def test_redraw_resets_and_repeats_do_not_count(self):
        rows = [{"kind": kind, "done_ms": str(time), "emulated_hz": "50"}
                for kind, time in [("N", 1000), ("R", 1010), ("N", 1020),
                                   ("D", 9000), ("N", 10000), ("N", 10020)]]
        self.assertEqual(stats.new_intervals(rows, "done_ms"), [20, 20])
        self.assertEqual(stats.realtime_ratio(rows, "done_ms"), 1)


if __name__ == "__main__":
    unittest.main()
