"""Request budgets, fresh claims and safe grouped writes, without network access."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'shared/runtime'))
import squad_runtime as r
import github_io as g
import tracker_cache as c
import board_backup as b
from test_board_backup import FakeAPI, fixture, conn


class Efficiency(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.config={'repository':'example/demo','project_owner':'example','project_number':'1',
                     'runtime_dir':self.tmp.name+'/runtime','github_state_dir':self.tmp.name+'/api',
                     'scratch_root':self.tmp.name}
    def response(self,body,headers='',code=200,rc=0):
        return subprocess.CompletedProcess([],rc,f'HTTP/2.0 {code} OK\nx-ratelimit-remaining: 100\n'+headers+'\n'+json.dumps(body),'')
    def test_board_cached_once_and_isolated_by_project_and_host(self):
        with patch.object(r,'fetch_board',return_value=[{'number':1}]) as fetch:
            r.board(self.config);r.board(self.config)
            self.assertEqual(fetch.call_count,1)
            r.board({**self.config,'project_number':'2'})
            with patch.dict(os.environ,{'GH_HOST':'example.test'}):r.board(self.config)
            self.assertEqual(fetch.call_count,3)
    def test_expiry_forced_refresh_and_failed_refresh_never_serve_stale(self):
        with patch.object(r,'fetch_board',return_value=[]) as fetch:
            r.board(self.config);r.board(self.config,fresh=True)
            self.assertEqual(fetch.call_count,2)
        with patch.object(r,'fetch_board',side_effect=ValueError('incomplete')):
            with self.assertRaises(ValueError):r.board({**self.config,'github_cache_seconds':0})
    def test_claim_reads_selected_issue_even_with_cached_eligible_data(self):
        with patch.object(r,'fetch_board',return_value=[{'number':1,'body':'agreed'}]):r.board(self.config)
        with patch.object(r,'fetch_board',return_value=[{'number':1,'body':'blocked'}]) as fetch:
            self.assertEqual(r.board(self.config,issue=1)[0]['body'],'blocked')
            fetch.assert_called_once_with(self.config,True,1)
    def test_selected_issue_read_revalidates_membership_and_dependencies(self):
        content={'id':'ISSUE','number':1,'title':'One','state':'OPEN','url':'fixture','body':'',
                 'repository':{'nameWithOwner':'example/demo'},'labels':conn([]),
                 'blockedBy':conn([{'number':2,'state':'OPEN'}]),
                 'projectItems':conn([{'id':'ITEM','isArchived':False,'project':{'id':'P','number':1,'owner':{'login':'example'}},
                     'fieldValues':conn([{'__typename':'ProjectV2ItemFieldSingleSelectValue','field':{'name':'Status'},'name':'In progress','optionId':'S'}])}])}
        with patch.object(b,'API') as api:
            api.return_value.query.return_value={'repository':{'issue':copy.deepcopy(content)}}
            result=r.fetch_board(self.config,issue=1)
            self.assertEqual(api.return_value.query.call_count,1)
            self.assertEqual(result[0]['dependencies'][0]['state'],'OPEN')
            content['projectItems']['nodes'][0]['project']['number']=2
            api.return_value.query.return_value={'repository':{'issue':content}}
            self.assertEqual(r.fetch_board(self.config,issue=1),[])
    def test_api_query_cost_is_recorded_without_response_data(self):
        response=self.response({'data':{'_squadRate':{'cost':7},'private':'not-in-metrics'}})
        with patch.object(g.subprocess,'run',return_value=response):
            self.assertEqual(b.API(config=self.config).query('query{x}'),{'private':'not-in-metrics'})
        metrics=g.status(self.config)
        self.assertEqual(sum(x['points'] for x in metrics['operations'].values()),7)
        self.assertNotIn('not-in-metrics',json.dumps(metrics))
    def test_limit_is_shared_across_projects_and_retries_defer(self):
        response=self.response({'errors':[{'message':'secondary rate limit'}]},'Retry-After: 120\n',rc=1)
        with patch.object(g.subprocess,'run',return_value=response) as call:
            with self.assertRaises(g.Deferred):b.API(config=self.config).query('query{x}')
            with self.assertRaises(g.Deferred):b.API(config={**self.config,'repository':'example/other'}).query('query{x}')
            self.assertEqual(call.call_count,1)
        self.assertEqual(len(g.status(self.config)['waiters']),2)
    def test_primary_exhaustion_does_not_block_rest_and_reset_resumes(self):
        response=self.response({'errors':[{'message':'rate limit'}]},f'x-ratelimit-remaining: 0\nx-ratelimit-reset: {int(time.time())+600}\n',rc=1)
        with patch.object(g.subprocess,'run',return_value=response):
            with self.assertRaises(g.Deferred):b.API(config=self.config).query('query{x}')
        with patch.object(g.subprocess,'run',return_value=self.response([])) as call:
            g.request(self.config,['repos/example/demo/issues'],resource='core')
            self.assertEqual(call.call_count,1)
        with patch.object(g.time,'time',return_value=time.time()+1000),patch.object(g.subprocess,'run',return_value=self.response({'data':{'x':1}})):
            self.assertEqual(b.API(config=self.config).query('query{x}'),{'x':1})
    def test_partial_mutation_is_not_replayed_and_invalidates_cache(self):
        c.get(self.config,lambda:[{'number':1}])
        response=self.response({'data':{'write':1},'errors':[{'message':'rate limit'}]},rc=1)
        with patch.object(g.subprocess,'run',return_value=response) as call:
            with self.assertRaises(g.Deferred):b.API(config=self.config).query('mutation{x}')
            self.assertEqual(call.call_count,1)
        self.assertFalse((c.directory(self.config)/'board.json').exists())
    def test_grouped_fields_validate_all_before_any_mutation(self):
        api=FakeAPI();api.state['items'][0]['content']['repository']={'nameWithOwner':'example/demo'}
        with patch.object(b,'API',return_value=api):
            with self.assertRaisesRegex(ValueError,'Field not found'):
                r.fields_set(self.config,1,{'Status':'Backlog','Missing':'invalid'})
        self.assertFalse(any(q.startswith('mutation') for q,v in api.calls))
    def test_repeated_identical_handoff_does_not_write_again(self):
        api=FakeAPI();api.state['items'][0]['content']['repository']={'nameWithOwner':'example/demo'}
        with patch.object(b,'API',return_value=api):
            self.assertEqual(r.fields_set(self.config,1,{'Status':'Backlog'})['changed'],1)
            self.assertEqual(r.fields_set(self.config,1,{'Status':'Backlog'})['changed'],0)
        self.assertEqual(sum(q.startswith('mutation') for q,v in api.calls),1)
    def test_verification_failure_keeps_journal_and_never_replays(self):
        api=FakeAPI();api.state['items'][0]['content']['repository']={'nameWithOwner':'example/demo'}
        original=api.query
        def query(q,v=None):
            if q.startswith('mutation'):api.calls.append((q,v));return {'ok':True}
            return original(q,v)
        api.query=query
        with patch.object(b,'API',return_value=api):
            with self.assertRaisesRegex(ValueError,'verification failed'):r.fields_set(self.config,1,{'Status':'Backlog'})
        self.assertEqual(sum(q.startswith('mutation') for q,v in api.calls),1)
        self.assertTrue(list(b.Store(self.config).path.glob('*field-verification*')))

    def test_conditional_reply_poll_reuses_validated_page(self):
        import inbox
        reply={'id':1}
        responses=[self.response([reply],'ETag: "same"\n'),self.response(None,code=304)]
        with patch.object(g.subprocess,'run',side_effect=responses) as call:
            self.assertEqual(inbox.comments(self.config,0),[reply])
            self.assertEqual(inbox.comments(self.config,0),[reply])
            self.assertIn('If-None-Match: "same"',call.call_args.args[0])
    def test_claim_nested_pagination_is_completed(self):
        # More than twenty dependency edges must never be silently treated as closed.
        content={'id':'ISSUE','number':1,'title':'One','state':'OPEN','url':'fixture','body':'',
                 'repository':{'nameWithOwner':'example/demo'},'labels':conn([]),
                 'blockedBy':conn([{'number':2,'state':'CLOSED'}],True,'next'),
                 'projectItems':conn([{'id':'ITEM','isArchived':False,'project':{'id':'P','number':1,'owner':{'login':'example'}},'fieldValues':conn([])}])}
        with patch.object(b,'API') as api:
            api.return_value.query.side_effect=[{'repository':{'issue':content}}, {'p0':{'blockedBy':conn([{'number':3,'state':'OPEN'}])}}]
            result=r.fetch_board(self.config,issue=1)
        self.assertEqual(result[0]['dependencies'][-1]['state'],'OPEN')
    def test_rest_pr_reads_refuse_truncated_files(self):
        data={'number':1,'title':'One','body':'','state':'open','changed_files':2,'head':{'sha':'a','ref':'work'},'base':{'ref':'main'}}
        with patch.object(r,'gh',return_value=data),patch.object(r,'pages',side_effect=[[],[{'filename':'a','additions':1,'deletions':0}]]):
            with self.assertRaisesRegex(ValueError,'incomplete'):r.tracker_read(self.config,1,pr=True)
    def test_api_reset_wakes_once_and_preserves_user_pause(self):
        import contextlib,io
        config={**self.config,'quota_mode':'unrestricted'}
        quota={'verdict':'run','policy':{'mode':'unrestricted'}}
        def wake():
            with patch.object(sys,'argv',['runtime','wake']),patch.object(r,'settings',return_value=config),patch.object(r,'quota_read',return_value=quota),contextlib.redirect_stdout(io.StringIO()) as out:
                r.main();return json.loads(out.getvalue())
        with g.locked(config) as state:state['waiters']={'example/demo':time.time()+60}
        self.assertFalse(wake()['ready'])
        with g.locked(config) as state:state['waiters']={'example/demo':time.time()-1}
        self.assertTrue(wake()['ready'])
        rev=r.read(r.root(config)/'state.json')['revision']
        wake();self.assertEqual(r.read(r.root(config)/'state.json')['revision'],rev)
        with r.transaction(config) as state:state['paused']=True
        self.assertFalse(wake()['ready'])

    def test_two_field_handoff_uses_one_snapshot_preserves_status_and_options(self):
        api=FakeAPI();api.state['items'][0]['content']['repository']={'nameWithOwner':'example/demo'}
        for name in ('Stage','Responsible role'):
            api.state['fields'].append({'id':name,'name':name,'dataType':'SINGLE_SELECT','__typename':'ProjectV2SingleSelectField',
                                        'options':[{'id':name+'-id','name':'review','color':'BLUE','description':''}]})
        original=b.capture
        with patch.object(b,'API',return_value=api),patch.object(b,'capture',wraps=original) as capture:
            result=r.fields_set(self.config,1,{'Stage':'review','Responsible role':'review'})
        self.assertEqual(result['changed'],2);capture.assert_called_once()
        status=next(v for v in api.state['items'][0]['fieldValues']['nodes'] if v['field']['id']=='STATUS')
        self.assertEqual(status['optionId'],'OPT1')
        self.assertEqual(api.state['fields'][0]['options'],fixture()['fields'][0]['options'])
