"""Opt-in real Zellij smoke test, with fake model CLIs and a throwaway project."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('SQUAD_TEST_ZELLIJ')=='1' and shutil.which('zellij'),
                     'set SQUAD_TEST_ZELLIJ=1 for isolated real-Zellij validation')
class ZellijMeeting(unittest.TestCase):
    def test_both_plugins_open_interactive_commands_and_focus(self):
        with tempfile.TemporaryDirectory(prefix='squad-meeting-') as tmp:
            base=Path(tmp);fake=base/'bin';fake.mkdir();project=base/'project with spaces';project.mkdir()
            for command in ('codex','claude'):
                p=fake/command
                p.write_text('''#!/usr/bin/env python3
import json,os,sys,time,subprocess
from pathlib import Path
command=Path(sys.argv[0]).name
harness='codex' if command=='codex' else 'claude-code'
plugin=Path(os.environ['MEETING_FIXTURE_ROOT'])/'plugins'/harness/'squad'
env={**os.environ,'PLUGIN_ROOT':str(plugin),'CLAUDE_PLUGIN_ROOT':str(plugin)}
sid='12345678-1234-4234-8234-123456789abc'
for hook in ('session-start','pre-compact','stop-dirty-tree','session-end'):
 subprocess.run(['bash',str(plugin/'hooks/scripts'/f'{hook}.sh')],input=json.dumps({'session_id':sid}),text=True,env=env,check=True,capture_output=True)
out=Path(os.environ['MEETING_FIXTURE'])/command
out.write_text(json.dumps({'argv':sys.argv,'cwd':os.getcwd(),'settings':os.environ.get('SQUAD_SETTINGS'),'tty':sys.stdin.isatty(),'id':os.environ.get('SQUAD_MEETING_ID')}))
while not out.with_suffix('.stop').exists(): time.sleep(.1)
''');p.chmod(0o700)
            session='squad-fixture-'+uuid.uuid4().hex[:12]
            env={**os.environ,'PATH':str(fake)+os.pathsep+os.environ['PATH'],'MEETING_FIXTURE':str(base),'MEETING_FIXTURE_ROOT':str(ROOT),
                 'ZELLIJ_SESSION_NAME':session}
            # Avoid inheriting this test runner's Squad project selection.
            env={k:v for k,v in env.items() if not k.startswith(('SQUAD_','ZELLIJ'))}
            created=subprocess.run(['zellij','attach','--create-background',session],env=env,capture_output=True,text=True)
            self.assertEqual(created.returncode,0,created.stderr)
            env['ZELLIJ_SESSION_NAME']=session
            try:
                for harness,command,model,directory in [('codex','codex','gpt-6-astra','.codex'),('claude-code','claude','fable','.claude')]:
                    settings=project/directory/'squad.local.md';settings.parent.mkdir()
                    settings.write_text(f'---\nrepository: fixture/example\nscratch_root: {base}/scratch\nproject_manager_model: {model}\nmeeting_zellij_session: {session}\n---\n')
                    script=ROOT/'plugins'/harness/'squad/scripts/meeting.sh'
                    def invoke(*args):
                        return json.loads(subprocess.check_output(['bash',str(script),*args],cwd=project,env=env,text=True))
                    first=invoke('start','planning')
                    out=base/command;deadline=time.monotonic()+10
                    while not out.exists() and time.monotonic()<deadline:time.sleep(.1)
                    self.assertTrue(out.exists(),'new tab did not execute the fixture CLI')
                    evidence=json.loads(out.read_text())
                    self.assertTrue(evidence['tty']);self.assertEqual(evidence['cwd'],str(project))
                    self.assertEqual(evidence['settings'],str(settings));self.assertIn(model,evidence['argv'])
                    second=invoke('start','planning');self.assertEqual(second['action'],'focused')
                    self.assertEqual(first['tab'],second['tab'])
                    record=invoke('status','planning')
                    self.assertEqual(record['session_id'],'12345678-1234-4234-8234-123456789abc')
                    out.with_suffix('.stop').touch()
            finally:
                subprocess.run(['zellij','kill-session',session],capture_output=True)
                subprocess.run(['zellij','delete-session',session,'--force'],capture_output=True)

if __name__=='__main__':unittest.main()
