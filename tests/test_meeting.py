import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'shared/runtime'))
import meeting as m


class Meetings(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name);self.project=self.base/'project with spaces';self.project.mkdir()
        self.config={'project_dir':str(self.project),'settings_file':str(self.project/'settings.md'),
                     'runtime_dir':str(self.base/'runtime'),'project_manager_model':'gpt-6-astra',
                     'meeting_zellij_session':'fixture'}
        self.tabs=[];self.calls=[]
        def zellij(session,*args):
            self.calls.append((session,args))
            if args[0]=='query-tab-names':return '\n'.join(self.tabs)
            if args[0]=='new-tab':self.tabs.append(args[args.index('--name')+1]);return '3'
            return ''
        for p in (patch.object(m,'zellij',side_effect=zellij),patch.object(m,'call',return_value='INITIAL_COMMAND'),patch.object(m.shutil,'which',return_value='/bin/fixture')):
            p.start();self.addCleanup(p.stop)
    def record(self,harness='codex',kind='planning'):
        return m.read(m.namespace(self.config,harness)/(kind+'.json'))
    def notes(self):
        p=self.base/'notes.md';p.write_text('Agreed scope; unresolved question.');return str(p)
    def test_launch_and_duplicate_focus(self):
        first=m.launch(self.config,'codex','planning')
        second=m.launch(self.config,'codex','planning')
        self.assertEqual(second['action'],'focused');self.assertEqual(first['tab'],second['tab'])
        self.assertEqual(sum(a[0]=='new-tab' for _,a in self.calls),1)
    def test_project_and_harness_isolation(self):
        other={**self.config,'project_dir':str(self.base/'different')}
        self.assertNotEqual(m.namespace(other,'codex'),m.namespace(self.config,'codex'))
        self.assertNotEqual(m.namespace(self.config,'codex'),m.namespace(self.config,'claude-code'))
    def test_dry_run_no_state_or_zellij(self):
        m.launch(self.config,'codex','retro',True)
        self.assertEqual(self.calls,[]);self.assertFalse((self.base/'runtime').exists())
    def test_explicit_models_efforts_and_safe_argv(self):
        for harness,model in [('codex','gpt-6-astra'),('claude-code','fable')]:
            m.launch({**self.config,'project_manager_model':model,'project_manager_effort':'high'},harness,'planning')
            record=self.record(harness);argv=m.harness_argv(record)
            self.assertIn(model,argv);self.assertNotIn('--print',argv);self.assertNotIn('exec',argv)
            self.assertEqual(record['project'],str(self.project))
            self.assertIn('high',' '.join(argv));self.assertIn('skills/plan/SKILL.md',argv[-1])
    def test_invalid_effort_no_launch(self):
        with self.assertRaises(ValueError):m.launch({**self.config,'project_manager_effort':'typo'},'codex','planning')
        self.assertEqual(self.calls,[])
    def test_missing_session_fails(self):
        with patch.dict(os.environ,{},clear=True),self.assertRaises(ValueError):
            m.launch({k:v for k,v in self.config.items() if k!='meeting_zellij_session'},'codex','planning')
    def test_ambiguous_launch_not_repeated(self):
        with patch.object(m,'zellij',side_effect=ValueError('response lost')):
            with self.assertRaises(ValueError):m.launch(self.config,'codex','planning')
        with self.assertRaisesRegex(ValueError,'unresolved'):m.launch(self.config,'codex','planning')
    def test_checkpoint_exact_resume(self):
        m.launch(self.config,'codex','planning')
        sid='12345678-1234-4234-8234-123456789abc'
        m.update(self.config,'codex','planning','checkpoint',self.notes(),sid)
        self.tabs.clear();m.update(self.config,'codex','planning','reconcile',reason='Closed tab; confirmed no process')
        m.launch(self.config,'codex','planning')
        argv=m.harness_argv(self.record());self.assertEqual(argv[1:3],['resume',sid])
        self.assertTrue(Path(self.record()['checkpoint']).exists())
    def test_complete_event_idempotent_and_preserves_pause(self):
        m.launch(self.config,'codex','retro')
        with m.transaction(self.config) as state:state['paused']=True
        for _ in range(2):m.update(self.config,'codex','retro','complete',self.notes())
        state=m.read(m.root(self.config)/'state.json')
        self.assertTrue(state['paused']);self.assertEqual(len(state['events']),1)
        self.assertEqual(state['events'][0]['kind'],'external')
        old=self.record(kind='retro');m.launch(self.config,'codex','retro')
        self.assertNotEqual(old['tab'],self.record(kind='retro')['tab'])
    def test_old_meeting_cannot_complete_replacement(self):
        m.launch(self.config,'codex','planning')
        with patch.dict(os.environ,{'SQUAD_MEETING_ID':'stale'}),self.assertRaises(ValueError):
            m.update(self.config,'codex','planning','complete',self.notes())
    def test_runner_pins_environment_and_keeps_interruption(self):
        m.launch(self.config,'codex','planning');r=self.record()
        with patch.dict(os.environ,{'SQUAD_SETTINGS':'wrong','CLAUDECODE':'1','CODEX_THREAD_ID':'parent'}),patch.object(m.subprocess,'call',return_value=1) as call:
            self.assertEqual(m.run_meeting(r['record_path']),1)
        env=call.call_args.kwargs['env'];self.assertEqual(env['SQUAD_SETTINGS'],self.config['settings_file'])
        self.assertNotIn('CODEX_THREAD_ID',env);self.assertNotIn('CLAUDECODE',env)
        self.assertEqual(self.record()['status'],'interrupted')
    def test_hook_binds_native_session_id(self):
        m.launch(self.config,'codex','planning');r=self.record()
        sid='12345678-1234-4234-8234-123456789abc'
        with patch.dict(os.environ,{'SQUAD_MEETING_ID':r['id'],'SQUAD_MEETING_RECORD':r['record_path']}),patch.object(sys,'stdin',io.StringIO(json.dumps({'session_id':sid}))),patch('builtins.print'):
            m.session_hook()
        self.assertEqual(self.record()['session_id'],sid)
    def test_interrupted_existing_tab_reopens_instead_of_focusing_dead_pane(self):
        m.launch(self.config,'codex','planning');r=self.record()
        r['status']='interrupted';m.atomic(r['record_path'],r)
        again=m.launch(self.config,'codex','planning')
        self.assertEqual(again['action'],'launched');self.assertNotEqual(again['tab'],r['tab'])
    def test_reconcile_rejects_live_tab(self):
        m.launch(self.config,'codex','planning')
        with self.assertRaises(ValueError):m.update(self.config,'codex','planning','reconcile',reason='test')

if __name__=='__main__':unittest.main()
