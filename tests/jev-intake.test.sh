#!/usr/bin/env bash
# Advisory integration tests; all evaluator responses here are synthetic.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import importlib.util, json, os, subprocess, unittest
from unittest.mock import patch
from pathlib import Path
spec = importlib.util.spec_from_file_location('issue_file', 'lib/issue-file.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class AdvisoryTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {'JEV_PI_INTAKE': '1'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_off_never_calls_evaluator(self):
        with patch.dict(os.environ, {'JEV_PI_INTAKE': '0'}), patch.object(m.subprocess, 'run') as run:
            self.assertEqual(m.intake_advisory('repo#1', 'title', 'body', 'light'), '')
            self.assertEqual(m.duplicate_advisory('title', 'body', {'number': 1, 'repository': 'repo'}, .5), '')
            run.assert_not_called()

    def test_spec_and_scope(self):
        def evaluate(site, ref, state, questions):
            self.assertEqual(ref, 'repo#1')
            self.assertEqual(state['body'], 'body')
            if site == 'pi-intake-spec':
                self.assertEqual(len(questions['quality']['criteria']), 4)
                return {'quality': {'score': 1}}
            return {'scope': {'choice': 'heavy', 'probabilities': {'heavy': .8}}}
        with patch.object(m, 'jev_answers', side_effect=evaluate):
            text = m.intake_advisory('repo#1', 'title', 'body', 'light')
        self.assertIn('spec-quality: 1/3', text)
        self.assertIn('scope: heavy p=0.80; existing difficulty: light', text)

    def test_good_spec_no_warning(self):
        with patch.object(m, 'jev_answers', side_effect=[{'quality': {'score': 3}}, {}]):
            self.assertEqual(m.intake_advisory('repo#1', 'title', 'body', 'light'), '')

    def test_invalid_answers_inert(self):
        with patch.object(m, 'jev_answers', side_effect=[{'quality': {'score': 'bad'}}, {'scope': {'choice': 'evil\ntext', 'probabilities': {}}}]):
            self.assertEqual(m.intake_advisory('repo#1', 'title', 'body', 'light'), '')
        for p in [None, '0.8', True, -1, 2, float('nan')]:
            with patch.object(m, 'jev_answers', return_value={'duplicate': {'probability': p}}):
                self.assertEqual(m.duplicate_advisory('t', 'b', {'number': 1, 'repository': 'repo'}, .5), '')

    def test_duplicate_marker_and_legacy_parser(self):
        with patch.object(m, 'jev_answers', return_value={'duplicate': {'probability': .87}}):
            text = m.duplicate_advisory('t', 'b', {'number': 1, 'repository': 'repo'}, .5)
        self.assertIn('possible-duplicate-of: repo#1 score=0.50 jev_p=0.87', text)
        self.assertIn('score=0.50 -->', m.duplicate_marker('repo#1', .5))
        self.assertEqual(m.classify(.5), 'borderline')
        self.assertEqual(m.classify(.7), 'duplicate')

    def test_shared_client_contract_and_failure(self):
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{"answers":{"x":{"probability":0.7}}}', '')) as run:
            self.assertEqual(m.jev_answers('pi-intake-dup', 'repo#1', {'body': 'b'}, {'x': {'type': 'boolean'}})['x']['probability'], .7)
            kwargs = run.call_args.kwargs
            self.assertEqual(json.loads(kwargs['input'])['site'], 'pi-intake-dup')
            self.assertEqual(json.loads(kwargs['input'])['ref'], 'repo#1')
            self.assertLessEqual(kwargs['timeout'], 20)
        for failure in [FileNotFoundError(), subprocess.TimeoutExpired('jev-eval', 15)]:
            with patch.object(m.subprocess, 'run', side_effect=failure):
                self.assertEqual(m.jev_answers('site', 'ref', {}, {'x': {}}), {})
        for stdout, rc in [('bad json', 0), ('[]', 0), ('{}', 3)]:
            with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], rc, stdout, '')):
                self.assertEqual(m.jev_answers('site', 'ref', {}, {'x': {}}), {})

    def test_filing_branches_and_dry_run(self):
        issue = {'number': 1, 'repository': 'repo', 'title': 'existing', 'body': 'existing'}
        args = m.build_parser().parse_args(['file', '-R', 'repo', '--title', 'candidate', '--body', 'body', '--from-json', 'unused'])
        for score, kind in [(.5, 'borderline'), (.8, 'duplicate')]:
            with patch.object(m, 'collect_open', return_value=[issue]), patch.object(m, 'best_match', return_value={'score': score, 'issue': issue}), patch.object(m, 'issue_has_filing_comment', return_value=False), patch.object(m, 'gh_comment', return_value=(0, '')) as comment, patch.object(m, 'gh_create', return_value=(0, 'https://github.com/repo/issues/2')) as create, patch.object(m, 'duplicate_advisory', return_value='jev_p=0.87') as advice:
                args.dry_run = True
                self.assertEqual(m.cmd_file(args), 0)
                advice.assert_not_called()
                create.assert_not_called()
                comment.assert_not_called()
                args.dry_run = False
                self.assertEqual(m.cmd_file(args), 0)
                advice.assert_called_once()
                output = comment.call_args.args[2] if kind == 'duplicate' else create.call_args.args[2]
                self.assertIn('jev_p=0.87', output)
                advice.return_value = ''
                self.assertEqual(m.cmd_file(args), 0)
                output = comment.call_args.args[2] if kind == 'duplicate' else create.call_args.args[2]
                expected = m.comment_body('candidate', 'body', score, 'repo') if kind == 'duplicate' else m.duplicate_marker('repo#1', score) + 'body'
                self.assertEqual(output, expected)

    def test_tick_uses_existing_filer_without_changing_routing(self):
        text = Path('lib/pi-intake-tick.sh').read_text()
        self.assertIn('intake-advisory', text)
        self.assertIn('difficulty="$(issue_difficulty "${labels[$i]}" "$title" "$body")"', text)
        self.assertIn('jev-intake-advisory:', text)

unittest.main()
PY
