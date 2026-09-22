#!/usr/bin/env python3
"""Board safety fixtures. No GitHub credentials, requests or live board writes."""
import contextlib
import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import board_backup as b


def conn(nodes,more=False,cursor=None):
    return {'nodes':nodes,'pageInfo':{'hasNextPage':more,'endCursor':cursor}}


def fixture():
    f={'id':'STATUS','name':'Status','dataType':'SINGLE_SELECT','__typename':'ProjectV2SingleSelectField',
       'options':[{'id':'OPT1','name':'Done','color':'GREEN','description':'Finished'},
                  {'id':'OPT2','name':'Backlog','color':'GRAY','description':'Not started'}]}
    v={'__typename':'ProjectV2ItemFieldSingleSelectValue','field':{'id':'STATUS','name':'Status','dataType':'SINGLE_SELECT'},'optionId':'OPT1'}
    s={'schema_version':1,'captured_at':'2026-01-01T00:00:00Z',
       'project':{'id':'P','updatedAt':'a','number':1,'title':'Fixture'},'fields':[f],
       'items':[{'id':'I','type':'ISSUE','isArchived':False,'content':{'__typename':'Issue','id':'ISSUE','number':1,'url':'https://example.test/1'},'fieldValues':conn([v])}],
       'views':[{'id':'V','name':'Board','number':1,'layout':'BOARD_LAYOUT','filter':'status:Done',
                 'fields':conn([{'id':'STATUS','name':'Status','dataType':'SINGLE_SELECT'}]),
                 'groupByFields':conn([{'id':'STATUS'}]),'verticalGroupByFields':conn([]),'sortByFields':conn([])}]}
    s['sha256']=b.digest(s);return s


class FakeAPI:
    def __init__(self,state=None,remaining=100):
        self.state=state or fixture();self.remaining=remaining;self.calls=[]
    def preflight(self,writes):
        if self.remaining < writes+20: raise ValueError('budget')
    def query(self,query,variables=None):
        self.calls.append((query,variables));s=self.state
        if query.startswith('mutation'):
            x=variables['input']
            if 'updateProjectV2Field(' in query:
                field=next(f for f in s['fields'] if f['id']==x['fieldId'])
                options=copy.deepcopy(x['singleSelectOptions'])
                for i,o in enumerate(options):o.setdefault('id','GENERATED'+str(i))
                field['options']=options
                valid={o['id'] for o in options}
                for item in s['items']:
                    item['fieldValues']['nodes']=[v for v in item['fieldValues']['nodes'] if v.get('optionId') in valid]
                if 'name' in x:field['name']=x['name']
            elif 'updateProjectV2ItemFieldValue(' in query:
                item=next(i for i in s['items'] if i['id']==x['itemId'])
                item['fieldValues']['nodes']=copy.deepcopy(fixture()['items'][0]['fieldValues']['nodes'])
                item['fieldValues']['nodes'][0]['optionId']=x['value']['singleSelectOptionId']
            elif 'updateProjectV2View(' in query:
                view=next(v for v in s['views'] if v['id']==x['viewId'])
                for k in ('name','layout','filter'):view[k]=x[k]
            return {'ok':True}
        if 'projectV2(number' in query:return {'user':{'projectV2':copy.deepcopy(s['project'])}}
        for key in ('views','items','fields'):
            if key+'(first:' in query:return {'node':{key:conn(copy.deepcopy(s[key]))}}
        return {'node':{'updatedAt':s['project']['updatedAt']}}


class BoardBackup(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.config={'scratch_root':self.tmp.name,'project_owner':'example','project_number':'1'}
        self.store=b.Store(self.config)
    def test_legacy_replacement_demonstrates_data_loss_new_update_preserves_everything(self):
        old=fixture();legacy=FakeAPI(copy.deepcopy(old))
        b.mutation(legacy,'field',{'fieldId':'STATUS','singleSelectOptions':[{'name':'Done','color':'BLUE','description':''}]})
        self.assertEqual(legacy.state['items'][0]['fieldValues']['nodes'],[])
        api=FakeAPI(copy.deepcopy(old))
        options=b.merge_options(old['fields'][0]['options'],['Done','In review'])
        b.mutation(api,'field',{'fieldId':'STATUS','singleSelectOptions':options})
        self.assertEqual(api.state['items'],old['items'])
        self.assertEqual(api.state['views'],old['views'])
        self.assertEqual(api.state['fields'][0]['options'][:2],old['fields'][0]['options'])
        updated=api.state['fields'][0]['options']
        self.assertEqual(b.merge_options(updated,['Done','In review']),updated)
    def test_incomplete_options_fail_instead_of_generating_new_ids(self):
        with self.assertRaises(ValueError):b.merge_options([{'name':'Done'}],['Done'])
    def test_complete_capture_and_versioned_local_history(self):
        api=FakeAPI();snapshot=b.capture(api,self.config)
        self.assertEqual(len(api.calls),5)
        self.assertTrue(any('archivedStates:[ARCHIVED,NOT_ARCHIVED]' in q for q,_ in api.calls))
        with self.store.lock():
            a=self.store.save(snapshot,'snapshot');self.store.save(snapshot,'snapshot')
            self.assertEqual(self.store.git('rev-list','--count','HEAD').strip(),'2')
        self.assertEqual(b.load_snapshot(a),snapshot)
        self.assertFalse((self.store.path/'.git/config').read_text().find('[remote ')>=0)
    def test_multiple_projects_have_independent_histories_and_locks(self):
        other=b.Store({**self.config,'project_number':'2'})
        s1=fixture();s2=fixture();s2['project']['id']='OTHER'
        with self.store.lock():
            self.store.save(s1,'snapshot')
            with other.lock():
                other.save(s2,'snapshot')
                self.assertNotEqual(self.store.path,other.path)
        self.assertEqual(self.store.git('rev-list','--count','HEAD').strip(),'1')
        self.assertEqual(other.git('rev-list','--count','HEAD').strip(),'1')
        with self.assertRaisesRegex(ValueError,'another project'):b.plan_restore(s1,s2)
        with self.store.lock(),self.assertRaisesRegex(ValueError,'another project'):self.store.save(s2,'snapshot')
    def test_host_is_part_of_backup_and_restore_identity(self):
        with patch.dict(b.os.environ,{'GH_HOST':'enterprise.example'}):
            other=b.Store(self.config)
        self.assertNotEqual(self.store.path,other.path)
        saved=fixture();current=copy.deepcopy(saved);current['host']='enterprise.example'
        with self.assertRaisesRegex(ValueError,'another project'):b.plan_restore(saved,current)
    def test_corrupt_snapshot_refused(self):
        p=Path(self.tmp.name)/'bad.json';s=fixture();s['project']['id']='OTHER';p.write_text(json.dumps(s))
        with self.assertRaisesRegex(ValueError,'checksum'):b.load_snapshot(p)
    def test_cleared_status_restored_exactly(self):
        saved=fixture();current=copy.deepcopy(saved);current['items'][0]['fieldValues']=conn([])
        plan=b.plan_restore(saved,current)
        self.assertFalse(plan['blocked']);self.assertEqual(len(plan['changes']),1)
        api=FakeAPI(current)
        with self.store.lock():b.execute(api,self.store,plan)
        self.assertEqual(current['items'],saved['items'])
        self.assertFalse(b.plan_restore(saved,current)['changes'])
    def test_view_filter_restored_without_changing_grouping(self):
        saved=fixture();current=copy.deepcopy(saved);current['views'][0]['filter']=''
        api=FakeAPI(current)
        with self.store.lock():b.execute(api,self.store,b.plan_restore(saved,current))
        self.assertEqual(current['views'],saved['views'])
    def test_unsupported_grouping_change_blocks_entire_restore(self):
        saved=fixture();current=copy.deepcopy(saved);current['views'][0]['groupByFields']=conn([])
        current['items'][0]['fieldValues']=conn([]);plan=b.plan_restore(saved,current);api=FakeAPI(current)
        with self.store.lock(),self.assertRaises(ValueError):b.execute(api,self.store,plan)
        self.assertEqual(api.calls,[])
        self.assertFalse(b.plan_restore(saved,current,True)['blocked'])
    def test_deleted_option_id_cannot_be_silently_matched_by_name(self):
        saved=fixture();current=copy.deepcopy(saved);current['fields'][0]['options'][0]['id']='REPLACED'
        self.assertTrue(b.plan_restore(saved,current)['blocked'])
    def test_confirmation_is_stable_across_reads_but_changes_with_board_state(self):
        saved=fixture();current=copy.deepcopy(saved);current['items'][0]['fieldValues']=conn([])
        first=b.plan_restore(saved,current)['confirmation']
        current['captured_at']='later';current['sha256']='different'
        self.assertEqual(b.plan_restore(saved,current)['confirmation'],first)
        current['views'][0]['filter']='new filter'
        self.assertNotEqual(b.plan_restore(saved,current)['confirmation'],first)
    def test_bad_option_value_blocks_whole_restore_before_writes(self):
        saved=fixture();saved['items'][0]['fieldValues']['nodes'][0]['optionId']='UNKNOWN'
        current=fixture();current['items'][0]['fieldValues']=conn([])
        self.assertTrue(b.plan_restore(saved,current)['blocked'])
    def test_missing_item_blocks_complete_restore(self):
        saved=fixture();current=copy.deepcopy(saved);current['items']=[]
        self.assertTrue(b.plan_restore(saved,current)['blocked'])
    def test_preflight_rate_limit_starts_no_writes(self):
        saved=fixture();current=copy.deepcopy(saved);current['items'][0]['fieldValues']=conn([])
        api=FakeAPI(current,remaining=1)
        with self.store.lock(),self.assertRaises(ValueError):b.execute(api,self.store,b.plan_restore(saved,current))
        self.assertEqual(api.calls,[])
    def test_lost_mutation_response_leaves_journal_and_stops(self):
        api=FakeAPI();plan={'blocked':[],'changes':[{'kind':'value','input':{}},{'kind':'value','input':{}}]}
        with self.store.lock(),patch.object(api,'query',side_effect=ValueError('lost response')) as call:
            with self.assertRaisesRegex(ValueError,'interrupted'):b.execute(api,self.store,plan)
            self.assertEqual(call.call_count,1)
        records=[json.loads(p.read_text()) for p in self.store.path.glob('*.json')]
        self.assertTrue(any(r.get('state')=='interrupted' for r in records))
    def test_paginated_reads_and_repeated_cursor_rejection(self):
        api=FakeAPI()
        with patch.object(api,'query',side_effect=[{'node':{'items':conn([{'id':'1'}],True,'next')}},{'node':{'items':conn([{'id':'2'}])}}]):
            self.assertEqual(len(b.connection(api,'P','items','id')),2)
        with patch.object(api,'query',return_value={'node':{'items':conn([],True,'same')}}):
            with self.assertRaisesRegex(ValueError,'cursor'):b.connection(api,'P','items','id')
    def test_nested_overflow_requests_are_batched(self):
        api=FakeAPI();objects=[conn([{'id':'a'}],True,'next') for _ in range(3)]
        requests=[(obj,'I'+str(i),'ProjectV2Item','fieldValues',b.VALUE,None) for i,obj in enumerate(objects)]
        with patch.object(api,'query',return_value={'p'+str(i):{'fieldValues':conn([{'id':'b'}])} for i in range(3)}) as call:
            b.finish_nested(api,requests);self.assertEqual(call.call_count,1)
        self.assertTrue(all(len(o['nodes'])==2 for o in objects))
    def test_changed_project_or_unknown_value_prevents_snapshot(self):
        api=FakeAPI()
        original=api.query
        def query(q,v=None):
            if 'ProjectV2{updatedAt}' in q:return {'node':{'updatedAt':'changed'}}
            return original(q,v)
        with patch.object(api,'query',side_effect=query),self.assertRaisesRegex(ValueError,'changed'):b.capture(api,self.config)
        api=FakeAPI();api.state['items'][0]['fieldValues']['nodes']=[{'__typename':'FutureValue'}]
        with self.assertRaisesRegex(ValueError,'Unsupported'):b.capture(api,self.config)
    def test_restore_defaults_to_dry_run_and_confirmation_is_required(self):
        saved=fixture();path=Path(self.tmp.name)/'saved.json';path.write_text(json.dumps(saved))
        current=copy.deepcopy(saved);current['items'][0]['fieldValues']=conn([])
        for extra,raises in [([],False),(['--apply'],True),(['--apply','--confirm','WRONG'],True),(['--apply','--confirm','P','--dry-run'],True)]:
            with patch.object(sys,'argv',['board','restore',str(path),*extra]),patch.object(b,'settings',return_value=self.config),patch.object(b,'capture',return_value=current),patch.object(b,'execute') as execute,contextlib.redirect_stdout(io.StringIO()) as out:
                if raises:
                    with self.assertRaises(ValueError):b.main()
                else:b.main()
                self.assertIn('changes',out.getvalue());execute.assert_not_called()
    def test_snapshot_failure_prevents_restore_and_journal(self):
        with patch.object(sys,'argv',['board','restore','missing','--apply','--confirm','P']),patch.object(b,'settings',return_value=self.config),patch.object(b,'capture',side_effect=ValueError('limit')),patch.object(b,'execute') as execute:
            with self.assertRaisesRegex(ValueError,'limit'):b.main()
            execute.assert_not_called()
        self.assertEqual(list(self.store.path.glob('*-snapshot-*.json')),[])


class RateLimits(unittest.TestCase):
    def response(self,body,headers='',code=0):
        return subprocess.CompletedProcess([],code,'HTTP/2.0 200 OK\nx-ratelimit-remaining: 100\n'+headers+'\n'+json.dumps(body),'')
    def test_secondary_backoff_is_bounded(self):
        sleeps=[];api=b.API(retries=2,sleep=sleeps.append)
        response=self.response({'errors':[{'message':'secondary rate limit'}]})
        with patch.object(b.subprocess,'run',return_value=response) as run:
            with self.assertRaises(ValueError):api.query('query{viewer{login}}')
        self.assertEqual(run.call_count,3);self.assertEqual(sleeps,[60,120])
    def test_retry_after_is_respected(self):
        sleeps=[];api=b.API(sleep=sleeps.append)
        with patch.object(b.subprocess,'run',side_effect=[self.response({'message':'rate limit'},'retry-after: 90\n',1),self.response({'data':{'ok':True}})]):
            self.assertEqual(api.query('query{viewer{login}}'),{'ok':True})
        self.assertEqual(sleeps,[90])
    def test_long_primary_reset_does_not_spin(self):
        response=self.response({'errors':[{'message':'rate limit'}]},'x-ratelimit-remaining: 0\nx-ratelimit-reset: 9999999999\n')
        with patch.object(b.subprocess,'run',return_value=response) as run:
            with self.assertRaisesRegex(ValueError,'bounded'):b.API(sleep=lambda _:self.fail('must not sleep')).query('query{x}')
            self.assertEqual(run.call_count,1)
    def test_partial_mutation_error_is_never_retried(self):
        response=self.response({'data':{'write':{'id':'x'}},'errors':[{'message':'rate limit'}]})
        with patch.object(b.subprocess,'run',return_value=response) as run:
            with self.assertRaises(ValueError):b.API().query('mutation{x}')
            self.assertEqual(run.call_count,1)
    def test_permission_error_is_not_retried(self):
        with patch.object(b.subprocess,'run',return_value=self.response({'errors':[{'message':'forbidden'}]})) as run:
            with self.assertRaises(ValueError):b.API().query('query{x}')
            self.assertEqual(run.call_count,1)


if __name__=='__main__':unittest.main()
