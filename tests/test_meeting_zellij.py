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
    def test_claude_main_pm_opens_interactive_command_and_focuses(self):
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
                for harness,command,model,directory in [('claude-code','claude','fable','.claude')]:
                    settings=project/directory/'squad.local.md';settings.parent.mkdir()
                    settings.write_text(f'---\nrepository: fixture/example\nscratch_root: {base}/scratch\nproject_manager_model: {model}\nmeeting_zellij_session: {session}\n---\n')
                    script=ROOT/'plugins'/harness/'squad/scripts/meeting.sh'
                    def invoke(*args):
                        return json.loads(subprocess.check_output(['bash',str(script),*args],cwd=project,env=env,text=True))
                    first=invoke('start','pm')
                    out=base/command;deadline=time.monotonic()+10
                    while not out.exists() and time.monotonic()<deadline:time.sleep(.1)
                    self.assertTrue(out.exists(),'new tab did not execute the fixture CLI')
                    evidence=json.loads(out.read_text())
                    self.assertTrue(evidence['tty']);self.assertEqual(evidence['cwd'],str(project))
                    self.assertEqual(evidence['settings'],str(settings));self.assertIn(model,evidence['argv'])
                    second=invoke('start','pm');self.assertEqual(second['action'],'focused')
                    self.assertEqual(first['tab'],second['tab'])
                    record=invoke('status','pm')
                    self.assertEqual(record['session_id'],'12345678-1234-4234-8234-123456789abc')
                    out.with_suffix('.stop').touch()
            finally:
                subprocess.run(['zellij','kill-session',session],capture_output=True)
                subprocess.run(['zellij','delete-session',session,'--force'],capture_output=True)


@unittest.skipUnless(os.environ.get('SQUAD_TEST_ZELLIJ')=='1' and shutil.which('zellij'),
                     'set SQUAD_TEST_ZELLIJ=1 for isolated real-Zellij validation')
class ManagedPMTab(unittest.TestCase):
    def test_codex_start_attaches_exact_pm_and_focuses(self):
        with tempfile.TemporaryDirectory(prefix='squad-pm-') as tmp:
            base=Path(tmp);fake=base/'bin';fake.mkdir();project=base/'project';project.mkdir()
            state=base/'state';state.mkdir();settings=project/'.codex/squad.local.md';settings.parent.mkdir()
            client=fake/'client';client.touch()
            model='gpt-6-astra';session='squad-fixture-'+uuid.uuid4().hex[:12]
            settings.write_text(f'---\nrepository: fixture/example\nscratch_root: {base}/scratch\nproject_manager_model: {model}\nconductor_state: {state}\nconductor_app_server_client: {client}\nconductor_app_server_url: unix://fixture\nmeeting_zellij_session: {session}\n---\n')
            runner=fake/'systemd-run';runner.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
a=sys.argv
state=Path(a[a.index('--state')+1]);cwd=a[a.index('--cwd')+1]
model=a[a.index('--model')+1];effort=a[a.index('--effort')+1]
(state/'chief-of-staff-thread.json').write_text(json.dumps({'thread_id':'fixture-pm','attachable':True,'resolved':{'model':model,'reasoningEffort':effort,'cwd':cwd}}))
(state/'pm-authority.json').write_text(json.dumps({'thread_id':'fixture-pm','role':'project-manager','model':model,'effort':effort,'cwd':cwd}))
''');runner.chmod(0o700)
            codex=fake/'codex';codex.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
out=Path(os.environ['PM_FIXTURE'])/'attached.json'
out.write_text(json.dumps({'argv':sys.argv,'cwd':os.getcwd(),'tty':sys.stdin.isatty(),'settings':os.environ.get('SQUAD_SETTINGS'),'foreign':os.environ.get('SQUAD_RUNTIME_DIR')}))
while not out.with_suffix('.stop').exists(): time.sleep(.1)
''');codex.chmod(0o700)
            env={k:v for k,v in os.environ.items() if not k.startswith(('SQUAD_','ZELLIJ'))}
            env.update(PATH=str(fake)+os.pathsep+os.environ['PATH'],PM_FIXTURE=str(base),SQUAD_RUNTIME_DIR='foreign-project')
            self.assertEqual(subprocess.run(['zellij','attach','--create-background',session],env=env,capture_output=True).returncode,0)
            env.pop('SQUAD_RUNTIME_DIR');env['ZELLIJ_SESSION_NAME']=session
            try:
                def start():
                    return json.loads(subprocess.check_output([str(ROOT/'bin/squad'),'--harness','codex','start'],cwd=project,env=env,text=True))
                first=start();out=base/'attached.json';deadline=time.monotonic()+10
                while not out.exists() and time.monotonic()<deadline:time.sleep(.1)
                self.assertTrue(out.exists(),'PM tab did not attach')
                evidence=json.loads(out.read_text())
                self.assertIn('--remote',evidence['argv']);self.assertEqual(evidence['argv'][-2:],['resume','fixture-pm'])
                self.assertIn('model_reasoning_effort=high',evidence['argv']);self.assertIn(model,evidence['argv'])
                self.assertTrue(evidence['tty']);self.assertIsNone(evidence['foreign'])
                self.assertEqual(evidence['settings'],str(settings));self.assertEqual(evidence['cwd'],str(project))
                again=start();self.assertEqual(again['action'],'focused');self.assertEqual(first['tab'],again['tab'])
                out.with_suffix('.stop').touch()
            finally:
                subprocess.run(['zellij','kill-session',session],capture_output=True)
                subprocess.run(['zellij','delete-session',session,'--force'],capture_output=True)

if __name__=='__main__':unittest.main()
