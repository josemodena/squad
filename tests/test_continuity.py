import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'shared/runtime'))
import inbox
import knowledge
import squad_runtime as r
import blockers


class Continuity(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.config={'runtime_dir':self.tmp.name+'/runtime','repository':'example/demo','project_owner':'example','project_number':'1'}
        self.since=time.time()-3600
        with r.transaction(self.config) as s:
            s['paused']=True
            s['reply_watches']={'42':{'since':self.since}}
        self.reply={'id':99,'created_at':inbox.stamp(self.since+10),'updated_at':inbox.stamp(self.since+10),
                    'issue_url':'https://api.github.com/repos/example/demo/issues/42',
                    'html_url':'https://github.com/example/demo/issues/42#issuecomment-99',
                    'user':{'login':'owner'},'body':'I approve the recommendation.'}
    def state(self):return r.read(r.root(self.config)/'state.json')
    def test_reply_wakes_once_without_approval_or_unpause(self):
        with patch.object(inbox,'comments',return_value=[self.reply]):
            self.assertEqual(len(inbox.poll(self.config,True)['replies']),1)
            self.assertEqual(inbox.poll(self.config,True)['replies'],[])
        s=self.state();self.assertTrue(s['paused'])
        self.assertEqual(s['pm_reply_pending']['42']['url'],self.reply['html_url'])
        self.assertEqual(len(s['events']),1);self.assertFalse(s['events'][0]['approval'])
        self.assertEqual(s['events'][0]['owner'],'project-manager')
    def test_new_edit_generates_new_evidence(self):
        with patch.object(inbox,'comments',return_value=[self.reply]):inbox.poll(self.config,True)
        self.reply['body']='Correction: do not proceed.'
        with patch.object(inbox,'comments',return_value=[self.reply]):inbox.poll(self.config,True)
        self.assertEqual(len(self.state()['events']),2)
    def test_failure_preserves_cursor_and_backs_off(self):
        with patch.object(inbox,'comments',side_effect=inbox.Limited(600)) as call:
            first=inbox.poll(self.config,True);second=inbox.poll(self.config,True)
        self.assertEqual(first['status'],'error');self.assertEqual(second['status'],'backoff')
        call.assert_called_once();self.assertNotIn('cursor',self.state()['reply_observer'])
        self.assertFalse(self.state()['events'])
    def test_partial_malformed_batch_emits_nothing(self):
        with patch.object(inbox,'comments',return_value=[self.reply,{'id':1}]):inbox.poll(self.config,True)
        self.assertFalse(self.state()['events'])
    def test_unrelated_and_old_comments_do_not_wake(self):
        old=copy.deepcopy(self.reply);old['created_at']=inbox.stamp(self.since-20);old['updated_at']=old['created_at']
        unrelated=copy.deepcopy(self.reply);unrelated['issue_url']=unrelated['issue_url'].replace('/42','/43')
        with patch.object(inbox,'comments',return_value=[old,unrelated]):
            self.assertFalse(inbox.poll(self.config,True)['replies'])
    def test_pm_provenance_rejects_administrator(self):
        with r.transaction(self.config) as s:
            s['jobs']['a']={'role':'administrator','status':'running','worker':'worker'}
        with self.assertRaises(ValueError):knowledge.pm_source(self.config,'a')
        with self.assertRaises(ValueError):blockers.edit(self.config,42,record={'requires_user':True},pm_job='a')
    def test_learning_requires_review_and_is_project_scoped(self):
        lesson={'id':'navigation','kind':'lesson','summary':'Exercise sequential navigation',
                'evidence':'review.md','applicability':'multi-surface UI','roles':['engineer'],'issues':[42]}
        knowledge.add(self.config,lesson)
        self.assertEqual(knowledge.context(self.config,'engineer',42)['records'],[])
        source={'role':'project-manager','job':'pm'}
        knowledge.review(self.config,'navigation',{'status':'active','evidence':'verified review','reason':'reproduced'},source)
        self.assertEqual(len(knowledge.context(self.config,'engineer',42)['records']),1)
        self.assertEqual(knowledge.context(self.config,'engineer',43)['records'],[])
        other={**self.config,'project_number':'2'}
        self.assertEqual(knowledge.context(other,'engineer',42)['records'],[])
        history=subprocess.check_output(['git','-C',str(knowledge.directory(self.config)),'rev-list','--count','HEAD'],text=True)
        self.assertEqual(history.strip(),'2')
        knowledge.review(self.config,'navigation',{'status':'retired','evidence':'new behaviour','reason':'superseded'},source)
        self.assertEqual(knowledge.context(self.config,'engineer',42)['records'],[])
    def test_uncommitted_learning_never_enters_context(self):
        lesson={'id':'one','kind':'lesson','summary':'Proposed lesson','evidence':'report',
                'applicability':'test','roles':['engineer']}
        knowledge.add(self.config,lesson)
        path=knowledge.directory(self.config)/'records.json'
        records=json.loads(path.read_text());records['one']['status']='active';path.write_text(json.dumps(records))
        self.assertEqual(knowledge.context(self.config,'engineer')['records'],[])
        with self.assertRaisesRegex(ValueError,'uncommitted'):knowledge.add(self.config,{**lesson,'id':'two'})

    def test_decision_cannot_be_promoted_without_authority_check(self):
        value={'id':'scope','kind':'decision','summary':'Scope agreed','evidence':'issue#comment',
               'authority_source':'user comment','applicability':'task','roles':['project-manager']}
        knowledge.add(self.config,value)
        with self.assertRaises(ValueError):knowledge.review(self.config,'scope',{'status':'active','evidence':'x','reason':'x'}, {})

class ObserverHTTP(unittest.TestCase):
    def response(self,data,headers='',status=0):
        return subprocess.CompletedProcess([],status,'HTTP/2 200 OK\n'+headers+'\n'+json.dumps(data),'')
    def test_paginated_repo_read(self):
        with patch.object(inbox.subprocess,'run',side_effect=[
            self.response([{'id':1}], 'Link: <next>; rel="next"\n'),
            self.response([{'id':2}])]) as run:
            self.assertEqual(inbox.comments({'repository':'example/demo'},0),[{'id':1},{'id':2}])
        self.assertEqual(run.call_count,2)
        self.assertIn('page=2',run.call_args.args[0][-1])
        self.assertEqual(run.call_args.kwargs['timeout'],30)
    def test_secondary_limit_defers_no_sleep_or_blind_retry(self):
        response=self.response({'message':'secondary rate limit'},'Retry-After: 120\n',1)
        with patch.object(inbox.subprocess,'run',return_value=response) as run:
            with self.assertRaises(inbox.Limited) as error:inbox.comments({'repository':'example/demo'},0)
        self.assertGreaterEqual(error.exception.delay,120);run.assert_called_once()
    def test_page_limit_fails_without_partial_result(self):
        with patch.object(inbox.subprocess,'run',return_value=self.response([{'id':1}], 'Link: <next>; rel="next"\n')) as run:
            with self.assertRaisesRegex(ValueError,'ten pages'):inbox.comments({'repository':'example/demo'},0)
        self.assertEqual(run.call_count,10)
