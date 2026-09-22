"""Exercise CLI selection and installer boundaries without real harness/GitHub calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = Path(self.tmp.name) / 'project with spaces'
        self.project.mkdir()
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('SQUAD_', 'CLAUDE_', 'CODEX_'))}
        self.env['HOME'] = self.tmp.name
    def config(self, harness):
        path = self.project / ('.codex' if harness == 'codex' else '.claude')
        path.mkdir(exist_ok=True)
        (path/'squad.local.md').write_text('---\nrepository: example/demo\nscratch_root: '+self.tmp.name+'/state\n---\n')
    def run_cli(self, *args):
        return subprocess.run([str(ROOT/'bin/squad'), *args], cwd=self.project, env=self.env, capture_output=True, text=True)
    def test_help_needs_no_project_or_auth(self):
        result = self.run_cli('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('doctor', result.stdout)
    def test_infers_both_role_maps(self):
        for harness, model in [('codex','gpt-5.6-luna'),('claude-code','sonnet')]:
            with self.subTest(harness=harness):
                self.config(harness)
                result = self.run_cli('--harness', harness, 'models')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['administrator'], model)
    def test_auto_detect_and_reject_ambiguity(self):
        self.config('codex')
        self.assertEqual(self.run_cli('models').returncode, 0)
        self.config('claude-code')
        result = self.run_cli('models')
        self.assertEqual(result.returncode, 2)
        self.assertIn('both', result.stderr)
    def test_pause_reason_preserves_shell_characters(self):
        self.config('codex')
        reason = 'literal $(touch SHOULD_NOT_EXIST); `echo x`'
        result = self.run_cli('pause', '--reason', reason)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.project/'SHOULD_NOT_EXIST').exists())
        self.assertIn(reason, self.run_cli('state').stdout)
        self.assertTrue(json.loads(self.run_cli('status').stdout)['paused'])
    def test_explicit_project_from_elsewhere(self):
        self.config('claude-code')
        result = subprocess.run([str(ROOT/'bin/squad'), '--project', str(self.project), 'models'], cwd=self.tmp.name, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_claude_session_refused(self):
        result = self.run_cli('--harness','claude-code','session','attach')
        self.assertEqual(result.returncode, 2)
        self.assertIn('only for Codex', result.stderr)
    def test_cli_install_idempotent_and_no_overwrite(self):
        target = Path(self.tmp.name)/'bin with spaces'
        def install():
            return subprocess.run(['bash',str(ROOT/'install.sh'),'codex','--cli-only','--bin-dir',str(target)],env=self.env,capture_output=True,text=True)
        for _ in range(2):
            result = install(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((target/'squad').resolve(), ROOT/'bin/squad')
        (target/'squad').unlink(); (target/'squad').write_text('keep me')
        self.assertNotEqual(install().returncode,0)
        self.assertEqual((target/'squad').read_text(),'keep me')
    def test_installer_uses_local_marketplace_without_starting_agents(self):
        fake = Path(self.tmp.name)/'fake'; fake.mkdir()
        log = Path(self.tmp.name)/'calls'
        for tool in ['codex','claude']:
            path=fake/tool
            path.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["CALL_LOG"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
            path.chmod(0o755)
        self.env.update(PATH=str(fake)+os.pathsep+self.env['PATH'],CALL_LOG=str(log))
        for harness in ['codex','claude-code']:
            result=subprocess.run(['bash',str(ROOT/'install.sh'),harness,'--bin-dir',str(Path(self.tmp.name)/'bin')],env=self.env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(calls, [['plugin','marketplace','add',str(ROOT)],['plugin','add','squad@squad'],['plugin','marketplace','add',str(ROOT)],['plugin','install','squad@squad','--scope','user']])

if __name__ == '__main__':
    unittest.main()
