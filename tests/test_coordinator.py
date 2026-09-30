import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'shared/runtime'))
import coordinator as c
import knowledge
import meeting
import squad_runtime as r


class Coordinator(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.project=self.base/'project with spaces';self.project.mkdir()
        self.client=self.base/'client';self.client.touch()
        self.state=self.base/'conductor';self.state.mkdir()
        self.config={'project_dir':str(self.project),'runtime_dir':str(self.base/'runtime'),
                     'settings_file':str(self.project/'settings.md'),'conductor_state':str(self.state),
                     'project_manager_model':'gpt-6-astra','project_manager_effort':'high',
                     'conductor_app_server_client':str(self.client),'conductor_app_server_url':'unix://fixture',
                     'meeting_zellij_session':'test'}
        self.tabs=[];self.calls=[]
        def zellij(session,*args):
            self.calls.append((session,args))
            if args[0]=='query-tab-names':return '\n'.join(self.tabs)
            if args[0]=='new-tab':self.tabs.append(args[args.index('--name')+1]);return '1'
            return ''
        for p in (patch.object(c,'zellij',side_effect=zellij),patch.object(c.shutil,'which',return_value='/fixture')):
            p.start();self.addCleanup(p.stop)
    def saved(self,model='gpt-6-astra',effort='high',role='project-manager'):
        r.atomic(self.state/'pm-authority.json',{'thread_id':'native-pm','role':role,'model':model,'effort':effort,'cwd':str(self.project)})
        r.atomic(self.state/'chief-of-staff-thread.json',{'thread_id':'native-pm','attachable':True,
                 'resolved':{'model':model,'reasoningEffort':effort,'cwd':str(self.project),'coordinatorRole':role}})
    def test_dry_run_does_not_write_or_launch(self):
        result=c.launch(self.config,'codex',dry_run=True)
        self.assertEqual(result['effort'],'high');self.assertEqual(self.calls,[])
        self.assertEqual(list(self.state.iterdir()),[])
    def test_existing_pm_focused_without_spawning_or_topic_injection(self):
        self.saved()
        with patch.object(c,'call',side_effect=AssertionError('must not create a controller')):
            first=c.launch(self.config,'codex','planning')
            again=c.launch(self.config,'codex','retro')
        self.assertEqual(again['action'],'focused');self.assertEqual(first['thread_id'],'native-pm')
        self.assertEqual(sum(args[0]=='new-tab' for _,args in self.calls),1)
    def test_initial_controller_explicit_model_effort_and_pause_preserved(self):
        r.atomic(r.root(self.config)/'state.json',{'paused':True})
        def call(argv):
            self.assertIn('gpt-6-astra',argv);self.assertIn('high',argv)
            self.assertIn(str(self.project),argv)
            self.assertIn('Respect the persisted user pause',argv[-1]);self.saved()
        with patch.object(c,'call',side_effect=call) as launch:
            c.launch(self.config,'codex')
        self.assertEqual(launch.call_count,1)
        self.assertTrue(r.read(r.root(self.config)/'state.json')['paused'])
        current=r.read(self.state/'current.json');self.assertEqual(current['phase'],'controller-starting')
    def test_wrong_model_effort_or_role_refuses_before_any_launch(self):
        for values in [('gpt-6-luna','high','administrator'),('gpt-6-astra','low','project-manager'),('gpt-6-astra','high','administrator')]:
            self.saved(*values)
            with self.assertRaisesRegex(ValueError,'different role/model/effort'):c.launch(self.config,'codex')
        self.assertEqual(self.calls,[])
    def test_ambiguous_controller_launch_never_repeated(self):
        with patch.object(c,'call',side_effect=ValueError('response lost')) as launch:
            with self.assertRaisesRegex(ValueError,'response lost'):c.launch(self.config,'codex')
            with patch.object(c.time,'sleep'),self.assertRaisesRegex(ValueError,'not attachable yet'):c.launch(self.config,'codex')
        self.assertEqual(launch.call_count,1)
    def test_failed_tab_response_never_repeated(self):
        self.saved()
        def broken(session,*args):
            if args[0]=='query-tab-names':return ''
            raise ValueError('response lost')
        with patch.object(c,'zellij',side_effect=broken):
            with self.assertRaisesRegex(ValueError,'response lost'):c.launch(self.config,'codex')
            with self.assertRaisesRegex(ValueError,'ambiguous'):c.launch(self.config,'codex')
    def test_native_pm_provenance_and_other_project_rejected(self):
        self.saved()
        self.assertEqual(knowledge.pm_source(self.config,session='native-pm')['role'],'project-manager')
        with self.assertRaises(ValueError):knowledge.pm_source({**self.config,'project_dir':str(self.base/'other')},session='native-pm')
        self.saved(role='administrator')
        with self.assertRaises(ValueError):knowledge.pm_source(self.config,session='native-pm')
    def test_claude_start_and_recovery_share_one_record(self):
        with patch.object(meeting,'launch',return_value={}) as launch:
            c.launch(self.config,'claude-code','retro')
        self.assertEqual(launch.call_args.args[2],'pm')
        self.assertEqual(launch.call_args.args[0]['pm_topic'],'retro')
    def test_attached_terminal_does_not_inherit_another_projects_state(self):
        self.saved();c.launch(self.config,'codex')
        with patch.dict(os.environ,{'SQUAD_RUNTIME_DIR':'wrong-project','CODEX_THREAD_ID':'parent'}),patch.object(c.subprocess,'call',return_value=0) as run:
            c.attach(self.state/'pm-tab.json')
        env=run.call_args.kwargs['env']
        self.assertNotIn('SQUAD_RUNTIME_DIR',env);self.assertNotIn('CODEX_THREAD_ID',env)
        self.assertEqual(env['SQUAD_SETTINGS'],self.config['settings_file'])
        self.assertEqual(env['SQUAD_PM_MAIN'],'1')
    def test_manual_completion_finalised_only_by_exact_native_ack(self):
        current={'id':'pm-start-fixture','thread_id':'native-pm','turn_id':'turn'}
        r.atomic(self.state/'current.json',current)
        ack={**current,'turn_status':'completed','turn_id':'wrong'}
        r.atomic(self.state/'acks/pm-start-fixture.json',ack)
        self.assertFalse(c.reap_manual(self.state));self.assertTrue((self.state/'current.json').exists())
        ack['turn_id']='turn';r.atomic(self.state/'acks/pm-start-fixture.json',ack)
        self.assertTrue(c.reap_manual(self.state));self.assertFalse((self.state/'current.json').exists())
        self.assertEqual(r.read(self.state/'manual-results/pm-start-fixture.json')['ack'],ack)
    def test_sol_configuration_overrides_conflicting_effort(self):
        with patch.dict(os.environ,{'SQUAD_ENGINEER_MODEL':'gpt-6.1-sol','SQUAD_ENGINEER_EFFORT':'low',
                                    'SQUAD_ENGINEERING_REVIEWER_MODEL':'gpt-6.1-sol','SQUAD_ENGINEERING_REVIEWER_EFFORT':'high'},clear=True):
            config=r.settings()
        self.assertEqual(config['engineer_effort'],'medium')
        self.assertEqual(config['engineering_reviewer_effort'],'medium')

if __name__=='__main__': unittest.main()
