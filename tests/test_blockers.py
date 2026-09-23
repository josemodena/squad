import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'shared/runtime'))
import blockers as b
import squad_runtime as r

class Blockers(unittest.TestCase):
    def setUp(self):
        self.record={'id':'missing-record','category':'missing-customer-input','owner':'Project owner','next_action':'Supply the original conversation and its matching output.','why':'A truthful acceptance check needs the real input.','recommendation':'Locate the original first; if absent, run a new genuine session.','evidence':'fixture:input-readiness','requires_user':True}
    def test_round_trip_preserves_user_text_and_one_section(self):
        body='Existing scope and decisions.\n'
        result=b.render(body,[self.record]);self.assertTrue(result.startswith(body))
        self.assertEqual(b.parse(result),[self.record]);self.assertEqual(b.render(result,[self.record]),result)
        self.assertIn('🟠 Your action is needed',result);self.assertIn('PM recommendation',result)
    def test_malformed_section_fails_closed(self):
        result=b.explicit({'body':b.START+'broken'+b.END},{})
        self.assertEqual(result[0]['category'],'metadata-repair-required');self.assertFalse(result[0]['claimable'])
    def test_bare_blocked_label_prevents_silent_dispatch(self):
        result=b.explicit({'labels':[b.ATTENTION]},{});self.assertTrue(result[0]['requires_user'])
    def test_resolved_decision_needs_evidence(self):
        with self.assertRaises(ValueError):b.validate({**self.record,'status':'resolved'})
    def test_blocker_cannot_hide_in_delimiters(self):
        with self.assertRaises(ValueError):b.validate({**self.record,'next_action':'```'})
    def test_missing_owner_rejected(self):
        with self.assertRaises(ValueError):b.validate({**self.record,'owner':''})
    def test_readiness_uses_two_batched_reads_without_per_item_dependencies(self):
        class API:
            def __init__(self):self.calls=[]
            def query(self,q,v=None):
                self.calls.append(q)
                if 'projectV2(number:' in q:return {'user':{'projectV2':{'id':'P'}}}
                content={'__typename':'Issue','id':'I','number':1,'title':'Fixture','state':'OPEN','url':'fixture','body':'','repository':{'nameWithOwner':'x/y'},'labels':{'nodes':[],'pageInfo':{'hasNextPage':False}},'blockedBy':{'nodes':[{'state':'OPEN','number':2}],'pageInfo':{'hasNextPage':False}}}
                fields=[{'__typename':'ProjectV2ItemFieldSingleSelectValue','field':{'name':'Status'},'optionId':'original-id','name':'In progress'}]
                return {'node':{'items':{'nodes':[{'id':'PI','isArchived':False,'content':content,'fieldValues':{'nodes':fields,'pageInfo':{'hasNextPage':False}}}], 'pageInfo':{'hasNextPage':False}}}}
        api=API()
        with patch('board_backup.API',return_value=api):items=r.fetch_board({'project_owner':'x','project_number':'1','repository':'x/y'})
        self.assertEqual(len(api.calls),2);self.assertIn('blockedBy(first:20)',api.calls[1])
        self.assertEqual(items[0]['fields']['Status'],'In progress');self.assertEqual(items[0]['dependencies'][0]['state'],'OPEN')

if __name__=='__main__':unittest.main()

class BlockerWrites(unittest.TestCase):
    def test_backup_failure_prevents_any_issue_write(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            config={'scratch_root':tmp,'project_owner':'fixture','project_number':'1','repository':'fixture/demo'}
            with patch('board_backup.API') as api,patch('board_backup.Store.save',side_effect=ValueError('backup failed')):
                api.return_value.query.return_value={'repository':{'id':'R','issue':{'id':'I','body':'','labels':{'nodes':[],'pageInfo':{'hasNextPage':False}}}}}
                with self.assertRaises(ValueError):b.edit(config,1,record={})
                self.assertFalse(any(call.args[0].startswith('mutation') for call in api.return_value.query.call_args_list))
    def test_issue_edit_preserves_text_unrelated_labels_and_project_options(self):
        import tempfile
        class API:
            def __init__(self):self.calls=[]
            def preflight(self,n):pass
            def query(self,q,v=None):
                self.calls.append((q,v))
                issue={'id':'I','body':'Original scope.','labels':{'nodes':[{'id':'L','name':'component:core'}],'pageInfo':{'hasNextPage':False}}}
                if 'repository(owner:' in q:return {'repository':{'id':'R','l0':{'id':'B'},'l1':{'id':'U'},'l2':{'id':'D'},'issue':issue}}
                if 'node(id:' in q:return {'node':issue}
                if 'updateIssue' in q:return {'updateIssue':{'issue':{'id':'I'}}}
                raise AssertionError(q)
        api=API();snapshot={'project':{'id':'P'},'host':'github.com','fields':[{'options':[{'id':'original-option'}]}]}
        with tempfile.TemporaryDirectory() as tmp:
            config={'scratch_root':tmp,'project_owner':'fixture','project_number':'1','repository':'fixture/demo'}
            record={'id':'need-input','category':'missing-customer-input','owner':'Project owner','next_action':'Supply source','why':'Truthful proof','recommendation':'Locate original','evidence':'report','requires_user':True,'authority_boundary':'User input required','consequence':'Acceptance waits'}
            with patch('board_backup.API',return_value=api),patch('board_backup.capture',return_value=snapshot),patch('knowledge.pm_source',return_value={'role':'project-manager','job':'pm'}):result=b.edit(config,1,record=record,pm_job='pm')
            mutations=[(q,v) for q,v in api.calls if q.startswith('mutation')]
            self.assertEqual(len(mutations),1);value=mutations[0][1]['input']
            self.assertTrue(value['body'].startswith('Original scope.'));self.assertEqual(set(value['labelIds']),{'L','B','U','D'})
            self.assertFalse(result['project_status_changed']);self.assertTrue(Path(result['snapshot']).exists())
            self.assertEqual(snapshot['fields'][0]['options'][0]['id'],'original-option')
