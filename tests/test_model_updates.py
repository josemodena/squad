"""Upgrade checks must report provider evidence without changing execution state."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'shared/runtime'))
import model_updates as m


class ModelUpdates(unittest.TestCase):
    def catalogue(self, data):
        return patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess(
            [], 0, json.dumps(data), ''))

    def test_report_preserves_overrides_and_live_jobs(self):
        state = {'jobs': {'work': {'id': 'work', 'status': 'running',
                                 'model': 'old', 'actual_model': 'old'}}}
        before = copy.deepcopy(state)
        roles = {'engineer': 'old', 'administrator': 'new', 'architect': 'custom'}
        with self.catalogue({'models': [
            {'slug': 'old', 'upgrade': {'model': 'new', 'retirement_at': 'later'}},
            {'slug': 'new', 'upgrade': None}]}):
            result = m.check_upgrades({'harness_name': 'Codex'}, roles, state)
        self.assertEqual(result['roles']['engineer']['suggested_model'], 'new')
        self.assertTrue(result['roles']['engineer']['target_in_catalogue'])
        self.assertEqual(result['roles']['administrator']['status'], 'no-upgrade-advertised')
        self.assertEqual(result['roles']['architect']['status'], 'not-in-catalogue')
        self.assertEqual(result['active_jobs'][0]['actual_model'], 'old')
        self.assertFalse(result['automatic_changes'])
        self.assertEqual(state, before)
        self.assertEqual(roles['engineer'], 'old')

    def test_missing_target_is_not_claimed_available(self):
        with self.catalogue({'models': [{'slug': 'old', 'upgrade': {'model': 'future'}}]}):
            result = m.check_upgrades({'harness_name': 'Codex'}, {'engineer': 'old'}, {})
        self.assertFalse(result['roles']['engineer']['target_in_catalogue'])

    def test_claude_never_calls_codex_or_claims_alias_resolution(self):
        with patch.object(m.subprocess, 'run') as run:
            result = m.check_upgrades({'harness_name': 'Claude Code'}, {'engineer': 'opus'}, {})
        run.assert_not_called()
        self.assertEqual(result['status'], 'unsupported')
        self.assertEqual(result['roles']['engineer']['status'], 'not-checked')

    def test_malformed_catalogue_fails_closed(self):
        for data in ({}, {'models': []}, {'models': [None]},
                     {'models': [{'slug': 'x'}, {'slug': 'x'}]},
                     {'models': [{'slug': 'x', 'upgrade': 'latest'}]}):
            with self.subTest(data=data), self.catalogue(data), self.assertRaises(ValueError):
                m.catalogue()

    def test_timeout_is_bounded_without_retry_or_mutation(self):
        with patch.object(m.subprocess, 'run', side_effect=subprocess.TimeoutExpired('codex', 30)) as run:
            with self.assertRaisesRegex(ValueError, 'no settings changed'):
                m.catalogue()
        run.assert_called_once_with(['codex', 'debug', 'models'], text=True,
                                    capture_output=True, timeout=30)

    def test_failure_does_not_leak_catalogue_or_auth_output(self):
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 1, 'private output', 'private error')):
            with self.assertRaisesRegex(ValueError, '^Codex model catalogue failed;') as exc:
                m.catalogue()
        self.assertNotIn('private', str(exc.exception))
