"""Offline regression tests; fixtures are not classified-death proof rows."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('reliability', ROOT / 'scripts/bench/seat-reliability.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class DeathEvidence(unittest.TestCase):
    def test_attempt_window_excludes_old_errors_and_later_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'session.jsonl'
            p.write_text('\n'.join(json.dumps(row) for row in [
                {'timestamp': '2026-09-17T10:00:00Z', 'message': {'errorMessage': 'old'}},
                {'timestamp': '2026-09-17T11:00:01Z', 'message': {'role': 'assistant', 'provider': 'p', 'model': 'm', 'usage': {'totalTokens': 12}}},
                {'timestamp': '2026-09-17T11:00:02Z', 'message': {'role': 'toolResult'}},
                {'timestamp': '2026-09-17T12:00:00Z', 'message': {'errorMessage': 'later'}},
            ]))
            result = m.session_evidence(p, m.epoch('2026-09-17T11:00:00Z'), m.epoch('2026-09-17T11:30:00Z'))
            self.assertEqual(result['tools'], 1)
            self.assertEqual(result['tokens'], 12)
            self.assertEqual(result['provider'], 'p')
            self.assertEqual(len(result['tail']), 2)
            self.assertNotIn('old', str(result))
            self.assertNotIn('later', str(result))

    def test_bad_probabilities_never_become_classifications(self):
        for probability in [float('nan'), float('inf'), -0.1, 1.1, None, True]:
            with self.assertRaises(ValueError):
                m.validate_answers({'cause': {'choice': 'provider_5xx', 'probabilities': {'provider_5xx': probability}}})

    def test_missing_boolean_is_unavailable(self):
        with self.assertRaises(ValueError):
            m.validate_answers({'cause': {'choice': 'provider_5xx', 'probabilities': {'provider_5xx': 0.9}}})

    def test_secret_line_not_exported(self):
        self.assertEqual(m.safe_line('Authorization: Bearer test-private-value'), '[withheld: credential-shaped record]')

    def test_journal_join_keeps_denominator_and_does_not_call_success_a_death(self):
        rows = [
            {'__REALTIME_TIMESTAMP': '1000000', 'MESSAGE': 'pi-issue-run: x-1 phase=start', '_PID': '1', '_BOOT_ID': 'a'},
            {'__REALTIME_TIMESTAMP': '2000000', 'MESSAGE': 'pi-issue-run: x-1 phase=exit rc=0 reason=success', '_PID': '1', '_BOOT_ID': 'a'},
            {'__REALTIME_TIMESTAMP': '3000000', 'MESSAGE': 'pi-issue-run: x-1 phase=start', '_PID': '2', '_BOOT_ID': 'a'},
            {'__REALTIME_TIMESTAMP': '4000000', 'MESSAGE': 'pi-issue-run: x-1 phase=exit rc=0 reason=infra-death-requeue', '_PID': '2', '_BOOT_ID': 'a'},
        ]
        runs = m.join_journal(rows)
        self.assertEqual(len(runs), 2)
        self.assertFalse(runs[0]['death'])
        self.assertTrue(runs[1]['death'])
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
        runs = m.join_journal([{'__REALTIME_TIMESTAMP': '4000000', 'MESSAGE': 'pi-issue-run: x-1 phase=exit rc=1 reason=unknown'}])
        self.assertIsNone(runs[0]['start'])


if __name__ == '__main__':
    unittest.main()
