"""Offline journal join tests. Only the 7414 pair below is a real-record proof."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('reliability', ROOT / 'scripts/bench/seat-reliability.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def row(when, phase, suffix='', boot='a'):
    return {'__REALTIME_TIMESTAMP': str(when * 1000000),
            'MESSAGE': f'pi-issue-run: x-1 phase={phase}{suffix}', '_BOOT_ID': boot}


class JournalEvidence(unittest.TestCase):
    def test_retains_successes_for_denominator(self):
        runs = m.join_journal([row(1, 'start'), row(2, 'exit', ' rc=0 reason=success'),
                              row(3, 'start'), row(4, 'exit', ' rc=0 reason=infra-death-requeue')])
        self.assertEqual(len(runs), 2)
        self.assertFalse(runs[0]['death_candidate'])
        self.assertTrue(runs[1]['death_candidate'])
        self.assertEqual(runs[1]['start'], 3)

    def test_real_7414_journal_join_ignores_systemd_cat_pid(self):
        # #7483 handoff / #7444: actual journal records read 2026-09-17.
        rows = [
            {'__REALTIME_TIMESTAMP': '1789655987413393', 'MESSAGE': 'pi-issue-run: fleet-ops-7414 phase=start', '_PID': '1066572', '_BOOT_ID': '24c0b422d261413095743b8d84bf0ab7', '_SYSTEMD_INVOCATION_ID': '4f35b7e422bb413dba1e1f36a666ef7b'},
            {'__REALTIME_TIMESTAMP': '1789658508590968', 'MESSAGE': 'pi-issue-run: fleet-ops-7414 phase=exit rc=0 reason=infra-death-requeue', '_PID': '1398249', '_BOOT_ID': '24c0b422d261413095743b8d84bf0ab7'},
        ]
        run = m.join_journal(rows)[0]
        self.assertEqual(run['start'], 1789655987.413393)
        self.assertAlmostEqual(run['elapsed_s'], 2521.177575, places=5)

    def test_unmatched_exit_has_no_invented_duration(self):
        run = m.join_journal([row(4, 'exit', ' rc=1 reason=pi-failed')])[0]
        self.assertIsNone(run['start'])
        self.assertIsNone(run['elapsed_s'])

    def test_unknown_reason_stays_unknown(self):
        run = m.join_journal([row(1, 'start'), row(2, 'exit', ' rc=1 reason=unknown')])[0]
        self.assertIsNone(run['death_candidate'])

    def test_ambiguous_starts_not_silently_overwritten(self):
        run = m.join_journal([row(1, 'start'), row(2, 'start'), row(3, 'exit', ' rc=1 reason=pi-failed')])[0]
        self.assertIsNone(run['start'])
        self.assertEqual(run['join_status'], 'ambiguous_starts')

    def test_no_cross_boot_pair(self):
        run = m.join_journal([row(1, 'start'), row(3, 'exit', ' rc=1 reason=pi-failed', boot='b')])[0]
        self.assertIsNone(run['start'])

    def test_duplicate_rows_not_extra_deaths(self):
        rows = [row(1, 'start'), row(2, 'exit', ' rc=1 reason=pi-failed')]
        self.assertEqual(len(m.join_journal(rows + rows)), 1)


if __name__ == '__main__':
    unittest.main()
