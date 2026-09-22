#!/usr/bin/env python3
"""Behavioural tests: no live GitHub, model calls, or project writes."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import squad_runtime as r

class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = {'scratch_root':self.tmp.name,'repository':'x/y','project_owner':'x','project_number':'1','engineer_model':'sol','engineering_reviewer_model':'sol','max_workers':'2'}
        self.item = {'number':1,'state':'OPEN','fields':{'Agreement':'Agreed','Stage':'engineering','Responsible role':'engineer','Design':'Existing','Status':'This sprint','Estimate (credits %)':2},'dependencies':[]}
        self.quota = {'verdict':'run','headroom':10,'policy':{'mode':'pacing'}}
        self.worktree = Path(self.tmp.name)/'repo'; self.worktree.mkdir()
        def git(*args): return subprocess.run(['git','-C',str(self.worktree),*args],check=True,capture_output=True)
        git('init'); git('config','user.email','test@example.org'); git('config','user.name','Test')
        (self.worktree/'a').write_text('initial\n'); git('add','a'); git('commit','-m','initial')
        self.brief = Path(self.tmp.name)/'brief.md'; self.brief.write_text('Do bounded work')
        self.report = Path(self.tmp.name)/'report.md'; self.report.write_text('Evidence')
    def cli(self,*args):
        with patch.object(sys,'argv',['runtime',*args]),patch.object(r,'settings',return_value=self.config),patch.object(r,'board',return_value=[self.item]),patch.object(r,'quota_read',return_value=self.quota), contextlib.redirect_stdout(io.StringIO()) as out:
            r.main()
            return json.loads(out.getvalue())
    def test_rest_pagination_supports_older_gh_without_slurp(self):
        stream = ' \n[{"title":"brackets ][ inside a string"}]\n[]\n[{"number":2}] \n'
        with patch.object(r, 'run', return_value=stream) as run:
            self.assertEqual(r.pages('repos/example/demo/issues'),
                             [{'title':'brackets ][ inside a string'}, {'number':2}])
        run.assert_called_once_with('gh', 'api', '--paginate', 'repos/example/demo/issues', json_output=False)
    def test_rest_pagination_rejects_malformed_or_non_array_pages(self):
        for stream in ('[] trailing', '[{}] {"message":"error"}', '[{}] ['):
            with self.subTest(stream=stream), patch.object(r, 'run', return_value=stream):
                with self.assertRaises(ValueError):
                    r.pages('repos/example/demo/issues')
    def test_rest_pagination_propagates_command_failure(self):
        with patch.object(r, 'run', side_effect=ValueError('authentication failed')):
            with self.assertRaisesRegex(ValueError, 'authentication failed'):
                r.pages('repos/example/demo/issues')
    def claim(self,job='j1'):
        return self.cli('claim',job,'--issue','1','--role','engineer','--worktree',str(self.worktree),'--brief',str(self.brief))
    def test_claim_blocks_duplicate_issue_and_id(self):
        self.claim()
        with self.assertRaises(ValueError): self.claim('j2')
        with self.assertRaises(ValueError): self.claim()
    def test_dependency_open_blocks_closed_unblocks(self):
        self.item['dependencies']=[{'state':'open'}]
        self.assertFalse(self.cli('ready')[0]['eligible'])
        self.item['dependencies'][0]['state']='closed'
        self.assertTrue(self.cli('ready')[0]['eligible'])
    def test_agreement_design_role_and_estimate_are_required(self):
        for key in ('Agreement','Design','Responsible role','Estimate (credits %)'):
            with self.subTest(key=key):
                old=self.item['fields'].pop(key)
                self.assertFalse(self.cli('ready')[0]['eligible'])
                self.item['fields'][key]=old
    def test_user_pause_survives_policy_and_capacity(self):
        self.cli('pause','--reason','user instruction')
        self.cli('policy','--mode','unrestricted','--reason','user override')
        self.assertFalse(self.cli('ready')[0]['eligible'])
        self.assertFalse(self.cli('wake')['ready'])
        self.cli('resume','--reason','user resumed')
        self.assertTrue(self.cli('ready')[0]['eligible'])
    def test_quota_override_never_overrides_hard_limit(self):
        self.cli('policy','--mode','unrestricted','--reason','user')
        now=time.time()
        value=r.apply_policy(self.config,{},14,88,now+1000,now,now)
        self.assertEqual(value['verdict'],'run')
        value=r.apply_policy(self.config,{'provider_windows':[{'used_percentage':100,'resets_at':now+100}]},14,88,now+1000,now,now)
        self.assertEqual(value['reason'],'provider-limit')
        self.assertEqual(value['verdict'],'suspend')
    def test_override_expiry_and_staleness(self):
        r.atomic(r.root(self.config)/'policy.json',{'mode':'unrestricted','until':time.time()-1})
        self.assertEqual(r.policy(self.config)['mode'],'pacing')
        now=time.time()
        self.assertEqual(r.apply_policy(self.config,{},100,20,now+1000,now-4000,now)['verdict'],'stale')
        self.assertEqual(r.apply_policy(self.config,{},100,20,now-1,now,now)['verdict'],'stale')
    def test_model_mismatch_and_binding_identity(self):
        self.claim()
        with self.assertRaises(ValueError): self.cli('bind','j1','--worker','w1','--model','luna')
        self.cli('bind','j1','--worker','w1','--model','sol')
        with self.assertRaises(ValueError): self.cli('bind','j1','--worker','w2','--model','sol')
    def test_completion_deduplicates_and_ack_removes_wake(self):
        self.claim()
        self.cli('complete','j1','--result','completed','--report',str(self.report))
        self.cli('complete','j1','--result','completed','--report',str(self.report))
        self.assertTrue(self.cli('wake')['ready'])
        self.cli('ack','j1')
        self.assertFalse(self.cli('wake')['ready'])
    def test_interruption_preserves_ownership_until_reconciled(self):
        self.claim()
        self.cli('complete','j1','--result','interrupted','--report',str(self.report))
        with self.assertRaises(ValueError): self.claim('j2')
        self.cli('retry','j1','--reason','verified no native worker or process')
        self.claim('j2')
    def test_checkpoint_preserves_uncommitted_tracked_and_new_files(self):
        self.claim()
        (self.worktree/'a').write_text('unsaved change\n'); (self.worktree/'new').write_text('new data')
        check=Path(self.tmp.name)/'check.json'; check.write_text(json.dumps({'next_step':'run the failing test','tests':['red: expected failure']}))
        job=self.cli('checkpoint','j1','--file',str(check))
        self.assertIn('unsaved change',Path(job['checkpoint']['patch']).read_text())
        import tarfile
        with tarfile.open(job['checkpoint']['untracked']) as archive: self.assertEqual(archive.extractfile('new').read(),b'new data')
        self.assertEqual((self.worktree/'a').read_text(),'unsaved change\n')
    def test_lost_final_report_is_recovered_from_exact_native_identity(self):
        self.claim(); rollout=Path(self.tmp.name)/'rollout'
        records=[{'type':'session_meta','payload':{'id':'t'}},{'type':'event_msg','payload':{'type':'task_complete','turn_id':'u'}}]
        rollout.write_text('\n'.join(json.dumps(i) for i in records))
        self.cli('bind','j1','--worker','w','--model','sol','--thread','t','--turn','u','--rollout',str(rollout))
        self.assertTrue(self.cli('wake')['ready'])
        self.assertEqual(self.cli('recover')['jobs'][0]['status'],'interrupted')
    def test_unrelated_rollout_never_marks_worker_finished(self):
        self.claim(); rollout=Path(self.tmp.name)/'rollout'
        rollout.write_text(json.dumps({'type':'session_meta','payload':{'id':'other'}}))
        self.cli('bind','j1','--worker','w','--model','sol','--thread','t','--turn','u','--rollout',str(rollout))
        self.cli('wake')
        self.assertEqual(self.cli('recover')['jobs'][0]['status'],'running')
    def test_settle_does_not_consume_later_external_events(self):
        self.cli('external','one','--reason','decision')
        rev=self.cli('state')['revision']
        self.cli('external','two','--reason','another decision')
        self.cli('settle','--through',str(rev))
        self.assertTrue(self.cli('wake')['ready'])
        self.cli('settle','--through',str(self.cli('state')['revision']))
        self.assertFalse(self.cli('wake')['ready'])
    def test_reviewer_cannot_be_the_author(self):
        self.claim(); self.cli('bind','j1','--worker','author','--model','sol')
        self.cli('complete','j1','--result','completed','--report',str(self.report)); self.cli('ack','j1')
        self.item['fields'].update({'Stage':'engineering-review','Responsible role':'engineering-reviewer'})
        self.cli('claim','r1','--issue','1','--role','engineering-reviewer','--worktree',str(self.worktree),'--brief',str(self.brief))
        with self.assertRaises(ValueError): self.cli('bind','r1','--worker','author','--model','sol')
    def test_changed_pr_head_rejects_review_without_comment(self):
        with patch.object(sys,'argv',['runtime','review-record','1','--head','old','--verdict','pass','--file',str(self.report)]),patch.object(r,'settings',return_value=self.config),patch.object(r,'gh',return_value={'headRefOid':'new'}) as mock:
            with self.assertRaises(ValueError): r.main()
            self.assertEqual(mock.call_count,1)
    def test_completed_unacknowledged_job_stays_owned(self):
        self.claim()
        self.cli('complete','j1','--result','completed','--report',str(self.report))
        self.assertIn('already-owned',self.cli('ready')[0]['reasons'])
        with self.assertRaises(ValueError): self.claim('duplicate')
    def test_recover_includes_revision_and_external_reason(self):
        self.cli('external','answer-1','--reason','user resolved dependency')
        recovery=self.cli('recover')
        self.assertIsInstance(recovery['revision'],int)
        self.assertEqual(recovery['external_events'][0]['reason'],'user resolved dependency')
    def test_claim_transition_ends_avoidable_idle_interval(self):
        self.cli('ready'); self.claim()
        self.assertEqual(self.cli('state')['observations'][-1]['active'],1)
    def test_native_conductor_queued_event_cannot_bypass_pause(self):
        repo=Path(__file__).resolve().parents[1]
        scripts=Path(__file__).resolve().parent
        if not (scripts/'conductor.sh').exists():
            self.skipTest('conductor integration runs from the packaged runtime tests')
        config=Path(self.tmp.name)/'settings.md'
        quota=Path(self.tmp.name)/'quota'
        quota.write_text('#!/usr/bin/env python3\nimport json\nprint(json.dumps(dict(verdict="run",headroom=100)))\n')
        quota.chmod(0o755)
        scratch=Path(self.tmp.name)/'conductor'; scratch.mkdir()
        config.write_text('---\nrepository: test/isolated\nproject_owner: test\nproject_number: 1\nscratch_root: '+str(scratch)+'\nquota_command: '+str(quota)+'\ncontinuation_mode: native\n---\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('SQUAD_')}
        env.update({'SQUAD_SETTINGS':str(config),'SQUAD_PROJECT_DIR':str(self.worktree),'SQUAD_CONDUCTOR_QUOTA':'run','SQUAD_CONDUCTOR_STATE':str(scratch/'conductor-state'),'SQUAD_CONDUCTOR_HOLD':str(scratch/'hold'),'SQUAD_CONDUCTOR_LOG':str(scratch/'log'),'SQUAD_CONDUCTOR_LEDGER':str(scratch/'ledger')})
        def call(script,*args):
            return subprocess.run(['bash',str(scripts/script),*args],env=env,text=True,capture_output=True,check=True)
        call('runtime.sh','pause','--reason','user pause')
        if (scripts/'conductor-event.sh').exists():
            call('conductor-event.sh','--id','old-event','--kind','quota','--reason','capacity reset')
        else:
            call('runtime.sh','external','old-event','--reason','capacity reset')
            fake_bin=Path(self.tmp.name)/'bin'; fake_bin.mkdir()
            zellij=fake_bin/'zellij'; zellij.write_text('#!/bin/sh\nexit 0\n'); zellij.chmod(0o755)
            env['PATH']=str(fake_bin)+os.pathsep+env['PATH']
        call('conductor.sh','--dry-run')
        log=(scratch/'log').read_text()
        self.assertIn('user-paused' if (scripts/'conductor-event.sh').exists() else 'no durable recovery work',log)
        self.assertNotIn('would start',log)
    def test_detached_review_checks_exact_head_on_current_main(self):
        origin=Path(self.tmp.name)/'origin.git'
        subprocess.run(['git','init','--bare',str(origin)],check=True,capture_output=True)
        def git(*a): return subprocess.run(['git','-C',str(self.worktree),*a],text=True,check=True,capture_output=True).stdout.strip()
        git('branch','-M','main'); git('remote','add','origin',str(origin)); git('push','origin','main')
        git('checkout','-b','piece'); (self.worktree/'feature').write_text('feature')
        git('add','feature'); git('commit','-m','feature'); head=git('rev-parse','HEAD'); git('push','origin','HEAD:refs/pull/1/head')
        git('checkout','main'); before=git('rev-parse','main')
        self.config['project_dir']=str(self.worktree)
        with patch.object(sys,'argv',['runtime','review-prepare','1']),patch.object(r,'settings',return_value=self.config),patch.object(r,'gh',return_value={'headRefOid':head,'baseRefName':'main'}),contextlib.redirect_stdout(io.StringIO()) as out:
            r.main(); result=json.loads(out.getvalue())
        self.assertEqual(git('rev-parse','main'),before)
        detached=subprocess.run(['git','-C',result['worktree'],'symbolic-ref','-q','HEAD'],capture_output=True)
        self.assertNotEqual(detached.returncode,0)
        self.assertEqual((Path(result['worktree'])/'feature').read_text(),'feature')

    def test_quota_wait_without_workers_recovers_when_capacity_returns(self):
        self.quota={'verdict':'suspend','reason':'provider-limit','headroom':0}
        self.assertFalse(self.cli('ready')[0]['eligible'])
        self.assertFalse(self.cli('wake')['ready'])
        self.quota={'verdict':'run','headroom':100}
        self.assertTrue(self.cli('wake')['ready'])
        self.cli('pause','--reason','user')
        self.assertFalse(self.cli('wake')['ready'])
    def test_durable_command_preserves_exit_status_and_log(self):
        self.claim()
        with self.assertRaises(SystemExit) as outcome:
            self.cli('run','j1','--',sys.executable,'-c','print("failure evidence"); raise SystemExit(7)')
        self.assertEqual(outcome.exception.code,1)
        records=self.cli('recover')['jobs'][0]['processes']
        result=json.loads(Path(records[0]).read_text())
        self.assertIn('command-finished',[e['kind'] for e in self.cli('state')['events']])
        self.assertEqual(result['exit_code'],7)
        self.assertIn('failure evidence',Path(result['log']).read_text())
    def test_issue_creation_reuses_stable_key_after_lost_response(self):
        with patch.object(sys,'argv',['runtime','issue-create','--key','task-1','--title','Task','--file',str(self.brief)]),patch.object(r,'settings',return_value=self.config),patch.object(r,'pages',return_value=[{'number':42,'html_url':'https://example.test/42','body':'<!-- squad-key:task-1 -->'}]),patch.object(r,'backup_board',return_value='snapshot'),patch.object(r,'run',return_value='') as command,contextlib.redirect_stdout(io.StringIO()) as output:
            r.main()
        self.assertEqual(json.loads(output.getvalue())['number'],42)
        self.assertEqual(command.call_count,1)
        self.assertIn('item-add',command.call_args.args)

    def test_insufficient_headroom_waits_for_real_capacity_transition(self):
        self.quota={'verdict':'run','headroom':1}
        self.cli('ready')
        self.assertFalse(self.cli('wake')['ready'])
        self.quota={'verdict':'run','headroom':10}
        first=self.cli('wake')
        self.assertTrue(first['ready'])
        self.assertEqual(first['id'],self.cli('wake')['id'])
        self.quota={'verdict':'run','headroom':1}
        self.assertFalse(self.cli('wake')['ready'])
        self.quota={'verdict':'run','headroom':10}
        self.assertNotEqual(first['id'],self.cli('wake')['id'])
    def test_process_finishing_after_interruption_changes_recovery_identity(self):
        self.claim()
        process=Path(self.tmp.name)/'process.json'
        r.atomic(process,{'status':'running'})
        with r.transaction(self.config) as state:
            state['jobs']['j1']['processes']=[str(process)]
        self.cli('complete','j1','--result','interrupted','--report',str(self.report))
        first=self.cli('wake')['id']
        r.atomic(process,{'status':'completed','exit_code':0})
        second=self.cli('wake')['id']
        self.assertNotEqual(first,second)
        self.assertEqual(second,self.cli('wake')['id'])

    def test_metrics_do_not_claim_unobserved_history(self):
        self.assertIsNone(self.cli('metrics')['avoidable_idle_percent'])
        self.cli('observe','--reason','ready','--eligible','1','--capacity','2')
        self.assertGreaterEqual(self.cli('metrics')['avoidable_idle_seconds'],0)

if __name__=='__main__': unittest.main()
