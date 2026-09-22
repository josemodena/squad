#!/usr/bin/env python3
"""Read-only exports and preflighted, journalled same-project board recovery."""
import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import time
import uuid

from squad_runtime import atomic, settings

PAGE = 'pageInfo { hasNextPage endCursor } nodes'
REF = '... on ProjectV2FieldCommon { id name dataType }'
FIELD = '__typename ' + REF + '''
... on ProjectV2SingleSelectField { options { id name color description } }
... on ProjectV2MultiSelectField { options: multiSelectOptions { id name color description } }
... on ProjectV2IterationField { configuration { duration startDay
iterations { id title startDate duration } completedIterations { id title startDate duration } } }
'''
SCALARS = {
 'ProjectV2ItemFieldTextValue': ('text', 'text'),
 'ProjectV2ItemFieldNumberValue': ('number', 'number'),
 'ProjectV2ItemFieldDateValue': ('date', 'date'),
 'ProjectV2ItemFieldSingleSelectValue': ('optionId', 'singleSelectOptionId'),
 'ProjectV2ItemFieldIterationValue': ('iterationId', 'iterationId'),
}
NESTED = {
 'ProjectV2ItemFieldLabelValue': ('labels', 'id name'),
 'ProjectV2ItemFieldUserValue': ('users', 'id login'),
 'ProjectV2ItemFieldPullRequestValue': ('pullRequests', 'id number url repository { nameWithOwner }'),
 'ProjectV2ItemFieldReviewerValue': ('reviewers', '__typename ... on User { id login } ... on Team { id name slug } ... on Mannequin { id login }'),
}
VALUE = '__typename ' + ' '.join('... on '+typ+' { field { '+REF+' } '+key+' }' for typ,(key,_) in SCALARS.items())
VALUE += ' ... on ProjectV2ItemFieldMultiSelectValue { field { '+REF+' } options { id name } }'
for typ,(key,sel) in NESTED.items():
    VALUE += ' ... on '+typ+' { field { '+REF+' } '+key+'(first:10) { '+PAGE+' { '+sel+' } } }'
VALUE += ''' ... on ProjectV2ItemFieldRepositoryValue { field { '''+REF+''' } repository { id nameWithOwner } }
... on ProjectV2ItemFieldMilestoneValue { field { '''+REF+''' } milestone { id title number dueOn state } }
'''
VALUE += ' ... on ProjectV2ItemIssueFieldValue { field { '+REF+' } issueFieldValue { __typename '
for typ in ('IssueFieldDateValue','IssueFieldNumberValue','IssueFieldTextValue'):
    VALUE += ' ... on '+typ+' { id '+typ.lower()+':value }'
VALUE += ' ... on IssueFieldSingleSelectValue { id singleValue:value optionId name color description }'
VALUE += ' ... on IssueFieldMultiSelectValue { id multiValue:value options { id name color description } } } }'

ITEM = '''id type isArchived content { __typename
... on Issue { id number title url repository { id nameWithOwner } }
... on PullRequest { id number title url repository { id nameWithOwner } }
... on DraftIssue { id title body } }
fieldValues(first:100) { '''+PAGE+' { '+VALUE+' } }'
VIEW_CONNECTIONS = {'fields': REF, 'groupByFields': REF, 'verticalGroupByFields': REF,
                    'sortByFields': 'direction field { '+REF+' }'}
VIEW = 'id name number layout filter ' + ' '.join(k+'(first:100) { '+PAGE+' { '+v+' } }' for k,v in VIEW_CONNECTIONS.items())


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class API:
    def __init__(self, retries=3, max_wait=300, sleep=time.sleep):
        self.retries, self.max_wait, self.sleep = retries, max_wait, sleep
        self.remaining = None
        self.last_write = None

    def query(self, query, variables=None):
        mutation = query.lstrip().startswith('mutation')
        for attempt in range(self.retries+1):
            if mutation and self.last_write is not None:
                self.sleep(max(0, 1-(time.monotonic()-self.last_write)))
            result = subprocess.run(['gh','api','graphql','--include','--input','-'],
                input=json.dumps({'query':query,'variables':variables or {}}), capture_output=True, text=True)
            if mutation:
                self.last_write = time.monotonic()
            output = result.stdout.replace('\r\n','\n')
            headers = {}
            while output.startswith('HTTP/'):
                head, sep, output = output.partition('\n\n')
                if not sep: raise ValueError('Incomplete GitHub HTTP response')
                headers.update({k.lower().strip():v.strip() for line in head.splitlines()[1:] if ':' in line for k,v in [line.split(':',1)]})
            try: payload = json.loads(output)
            except ValueError: payload = {}
            if 'x-ratelimit-remaining' in headers:
                self.remaining = int(headers['x-ratelimit-remaining'])
            message = json.dumps(payload.get('errors',payload.get('message',''))) + result.stderr
            limited = any(s in message.lower() for s in ('rate limit','rate_limit','secondary limit','abuse detection'))
            limited |= 'retry-after' in headers or (self.remaining == 0 and bool(result.returncode or payload.get('errors')))
            if not result.returncode and not payload.get('errors') and isinstance(payload.get('data'),dict):
                return payload['data']
            # GraphQL can report partial success: never replay an ambiguous mutation.
            if limited and not (mutation and payload.get('data')) and attempt < self.retries:
                delay = max(60 * 2**attempt, float(headers.get('retry-after',0)))
                if self.remaining == 0 and 'x-ratelimit-reset' in headers:
                    delay = max(delay, float(headers['x-ratelimit-reset'])-time.time()+1)
                if delay > self.max_wait:
                    raise ValueError(f'GitHub rate limit: retry after at least {delay:.0f}s; required wait exceeds bounded retry window')
                print(f'GitHub rate limited; waiting {delay:.0f}s before retry {attempt+1}/{self.retries}', file=sys.stderr, flush=True)
                self.sleep(delay)
                continue
            raise ValueError('GitHub request failed; no further writes: '+message[:1500])
        raise ValueError('GitHub retry budget exhausted')

    def preflight(self, writes):
        if writes and (self.remaining is None or self.remaining < writes+20):
            raise ValueError('Insufficient known GraphQL budget for the complete operation; no writes started')


def connection(api, pid, key, selection, size=100):
    rows, cursor, seen = [], None, set()
    while True:
        extra=',archivedStates:[ARCHIVED,NOT_ARCHIVED]' if key=='items' else ''
        query = 'query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{'+key+'(first:'+str(size)+',after:$cursor'+extra+'){'+PAGE+'{'+selection+'}}}}}'
        node = api.query(query, {'id':pid,'cursor':cursor}).get('node')
        if not node: raise ValueError('Project missing or inaccessible')
        page = node[key]
        if any(v is None for v in page['nodes']): raise ValueError('Redacted connection entry; snapshot incomplete')
        rows.extend(page['nodes'])
        info = page['pageInfo']
        if not info['hasNextPage']: return rows
        cursor = info['endCursor']
        if not cursor or cursor in seen: raise ValueError('Invalid or repeated pagination cursor')
        seen.add(cursor)


def finish_nested(api, requests):
    """Batch only overflow connections. Normal boards need no per-item reads."""
    seen = set()
    while requests:
        batch, requests = requests[:20], requests[20:]
        aliases = []
        for i,(obj, owner, typename, key, selection, wrapper) in enumerate(batch):
            cursor = obj['pageInfo']['endCursor']
            marker=(owner,key,wrapper,cursor)
            if not cursor or marker in seen: raise ValueError('Invalid nested pagination cursor')
            seen.add(marker)
            body=key+'(first:100,after:'+json.dumps(cursor)+'){'+PAGE+'{'+selection+'}}'
            if wrapper: body=wrapper[0]+body+wrapper[1]
            aliases.append(f'p{i}:node(id:{json.dumps(owner)})'+'{... on '+typename+'{'+body+'}}')
        data=api.query('query{'+''.join(aliases)+'}')
        for i, request in enumerate(batch):
            obj,owner,typename,key,selection,wrapper=request
            node=data['p'+str(i)]
            if wrapper: node=node['fieldValueByName']
            page=node[key]
            if any(x is None for x in page['nodes']): raise ValueError('Incomplete nested connection')
            obj['nodes'].extend(page['nodes']);obj['pageInfo']=page['pageInfo']
            if page['pageInfo']['hasNextPage']: requests.append(request)


def capture(api, config):
    owner='organization' if config.get('project_owner_type') in ('org','organization') else 'user'
    query='query($owner:String!,$number:Int!){'+owner+'(login:$owner){projectV2(number:$number){id number title url public closed shortDescription readme updatedAt}}}'
    data=api.query(query,{'owner':config['project_owner'],'number':int(config['project_number'])})
    project=(data.get(owner) or {}).get('projectV2')
    if not project: raise ValueError('Project missing or inaccessible')
    pid=project['id']
    fields=connection(api,pid,'fields',FIELD)
    views=connection(api,pid,'views',VIEW,20)
    item_selection=ITEM.replace('fieldValues(first:100)', 'fieldValues(first:'+str(max(1,min(len(fields),100)))+')')
    items=connection(api,pid,'items',item_selection,50)
    requests=[]
    for item in items:
        if item['content'] is None or item['content']['__typename']=='RedactedProjectV2Item':
            raise ValueError('Inaccessible project item; snapshot incomplete')
        if item['fieldValues']['pageInfo']['hasNextPage']:
            requests.append((item['fieldValues'],item['id'],'ProjectV2Item','fieldValues',VALUE,None))
    for view in views:
        for key,sel in VIEW_CONNECTIONS.items():
            if view[key]['pageInfo']['hasNextPage']:
                requests.append((view[key],view['id'],'ProjectV2View',key,sel,None))
    finish_nested(api,requests)
    requests=[]
    for item in items:
        for value in item['fieldValues']['nodes']:
            if not value or 'field' not in value:
                raise ValueError('Unsupported or unreadable item field value; snapshot incomplete')
            if value['__typename'] in NESTED:
                key,sel=NESTED[value['__typename']]
                obj=value[key]
                if obj and obj['pageInfo']['hasNextPage']:
                    wrapper=('fieldValueByName(name:'+json.dumps(value['field']['name'])+'){... on '+value['__typename']+'{','}}')
                    requests.append((obj,item['id'],'ProjectV2Item',key,sel,wrapper))
    finish_nested(api,requests)
    # A changed board during pagination is not a valid point-in-time backup.
    final=api.query('query($id:ID!){node(id:$id){... on ProjectV2{updatedAt}}}',{'id':pid})['node']
    if final['updatedAt']!=project['updatedAt']:
        raise ValueError('Project changed during snapshot; no writes allowed; retry when board is quiet')
    snapshot={'schema_version':1,'host':os.environ.get('GH_HOST','github.com').lower(),'captured_at':dt.datetime.now(dt.timezone.utc).isoformat(),
              'project':project,'fields':fields,'items':items,'views':views,
              'limits':['API-visible data only; no view aggregations, hidden UI settings or workflows',
                        'GitHub has no cross-request snapshot isolation; stop other board writers during recovery']}
    snapshot['sha256']=digest(snapshot)
    return snapshot


def load_snapshot(path):
    s=json.loads(Path(path).read_text())
    checksum=s.pop('sha256',None)
    if s.get('schema_version')!=1 or checksum!=digest(s): raise ValueError('Invalid snapshot schema or checksum')
    s['sha256']=checksum
    return s


class Store:
    def __init__(self,config):
        base=Path(config.get('board_backup_dir') or str(Path(config.get('scratch_root') or '~/.local/state/squad').expanduser()/'board-backups')).expanduser()
        host=os.environ.get('GH_HOST','github.com').lower()
        owner=config['project_owner'].lower();number=str(int(config['project_number']))
        if not re.fullmatch(r'[a-z0-9.-]+',host) or not re.fullmatch(r'[a-z0-9-]+',owner) or int(number)<1:
            raise ValueError('Invalid backup namespace')
        self.path=base/host/(owner+'-'+number)
        self.path.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.path.chmod(0o700)
    @contextlib.contextmanager
    def lock(self):
        with (self.path/'.lock').open('a') as f:
            fcntl.flock(f,fcntl.LOCK_EX)
            if not (self.path/'.git').exists():
                self.git('init','-q','-b','main')
            yield
    def git(self,*args):
        out=subprocess.run(['git','-C',str(self.path),'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false',
            '-c','user.name=Squad backup','-c','user.email=noreply@localhost',*args],capture_output=True,text=True,env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')})
        if out.returncode: raise ValueError('Local backup Git operation failed: '+out.stderr)
        return out.stdout
    def save(self,data,label):
        name=dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')+'-'+label+'-'+uuid.uuid4().hex[:8]+'.json'
        if 'project' in data:
            identity={'host':data.get('host','github.com'),'project_id':data['project']['id']}
            identity_path=self.path/'identity.json'
            if identity_path.exists() and json.loads(identity_path.read_text())!=identity:
                raise ValueError('Backup namespace belongs to another project; choose a new directory')
            atomic(identity_path,identity)
        atomic(self.path/name,data)
        self.git('add','--',name)
        self.git('commit','-q','--only','-m',label,'--',name)
        return str(self.path/name)


def merge_options(existing,names):
    result=copy.deepcopy(existing)
    if any(not all(k in o for k in ('id','name','color','description')) for o in result):
        raise ValueError('Cannot preserve incomplete single-select option metadata')
    if len({o['id'] for o in result})!=len(result): raise ValueError('Duplicate option IDs')
    known={o['name'] for o in result}
    for name in names:
        if name and name not in known:
            result.append({'name':name,'color':'BLUE','description':''});known.add(name)
    return result


def mutation(api,kind,values):
    types={'field':'UpdateProjectV2FieldInput','value':'UpdateProjectV2ItemFieldValueInput',
           'clear':'ClearProjectV2ItemFieldValueInput','view':'UpdateProjectV2ViewInput'}
    methods={'field':('updateProjectV2Field','projectV2Field{... on ProjectV2FieldCommon{id}}'),
             'value':('updateProjectV2ItemFieldValue','projectV2Item{id}'),
             'clear':('clearProjectV2ItemFieldValue','projectV2Item{id}'),
             'view':('updateProjectV2View','projectV2View{id}')}
    method,ret=methods[kind]
    return api.query('mutation($input:'+types[kind]+'!){'+method+'(input:$input){'+ret+'}}',{'input':values})


def values_of(item):
    return {v['field']['id']:v for v in item['fieldValues']['nodes']}


def value_input(value):
    if value['__typename'] in SCALARS:
        source,target=SCALARS[value['__typename']];return {target:value[source]}
    if value['__typename']=='ProjectV2ItemFieldMultiSelectValue':
        return {'multiSelectOptionIds':[o['id'] for o in value['options']]}
    return None


def plan_restore(saved,current,status_only=False,status_field='Status'):
    changes,blocked=[],[]
    if saved.get('host','github.com')!=current.get('host','github.com') or saved['project']['id']!=current['project']['id']: raise ValueError('Snapshot belongs to another project')
    pid=current['project']['id']
    oldfields={f['id']:f for f in saved['fields']};newfields={f['id']:f for f in current['fields']}
    scope={f['id'] for f in saved['fields'] if not status_only or f['name']==status_field}
    if not scope: blocked.append('No matching fields in snapshot')
    for fid in sorted(scope):
        old=oldfields[fid];new=newfields.get(fid)
        if new is None or old['dataType']!=new['dataType']:
            blocked.append('Missing/replaced field '+old['name']);continue
        if 'options' in old:
            if {o['id'] for o in old['options']}!={o['id'] for o in new['options']}:
                blocked.append('Option identity changed for '+old['name']+'; explicit manual mapping required');continue
            if old!=new:
                if old['dataType']!='SINGLE_SELECT': blocked.append('Unsupported field metadata change '+old['name'])
                else: changes.append({'kind':'field','input':{'fieldId':fid,'name':old['name'],'singleSelectOptions':old['options']},'before':new})
        elif old!=new: blocked.append('Unsupported field metadata change '+old['name'])
    olditems={i['id']:i for i in saved['items']};newitems={i['id']:i for i in current['items']}
    if olditems.keys()!=newitems.keys(): blocked.append('Project item membership changed; reconcile before restoring')
    for iid,old in olditems.items():
        if iid not in newitems: continue
        new=newitems[iid]
        if (old['content'] or {}).get('id')!=(new['content'] or {}).get('id') or old['isArchived']!=new['isArchived']:
            blocked.append('Item identity/archive state changed '+iid)
        a,b=values_of(old),values_of(new)
        for fid in sorted(scope & (a.keys()|b.keys())):
            av,bv=a.get(fid),b.get(fid)
            if av==bv: continue
            if oldfields[fid]['dataType'] not in ('TEXT','NUMBER','DATE','SINGLE_SELECT','MULTI_SELECT','ITERATION'):
                blocked.append('Derived/read-only field differs on '+iid+': '+oldfields[fid]['name']);continue
            value=value_input(av) if av else None
            if av and value is None:
                blocked.append('Read-only/unsupported field differs on item '+iid+': '+oldfields[fid]['name']);continue
            if not av and bv and value_input(bv) is None:
                blocked.append('Cannot clear derived field '+fid);continue
            if value is not None:
                field=oldfields[fid]
                ids={o['id'] for o in field.get('options',[])}
                if 'singleSelectOptionId' in value and value['singleSelectOptionId'] not in ids:
                    blocked.append('Unknown single-select option on '+iid)
                if 'multiSelectOptionIds' in value and not set(value['multiSelectOptionIds'])<=ids:
                    blocked.append('Unknown multi-select option on '+iid)
                if 'iterationId' in value:
                    cfg=field.get('configuration',{})
                    if value['iterationId'] not in {i['id'] for i in cfg.get('iterations',[])+cfg.get('completedIterations',[])}:
                        blocked.append('Unknown iteration on '+iid)
                if 'number' in value and (not isinstance(value['number'],(int,float)) or not math.isfinite(value['number'])):
                    blocked.append('Invalid numeric value on '+iid)
                if 'date' in value:
                    try: dt.date.fromisoformat(value['date'])
                    except (ValueError,TypeError): blocked.append('Invalid date on '+iid)
                if 'text' in value and not isinstance(value['text'],str): blocked.append('Invalid text on '+iid)
            args={'projectId':pid,'itemId':iid,'fieldId':fid}
            if value is not None: args['value']=value
            changes.append({'kind':'value' if value is not None else 'clear','input':args,'before':bv})
    if not status_only:
        oldviews={v['id']:v for v in saved['views']};newviews={v['id']:v for v in current['views']}
        if oldviews.keys()!=newviews.keys(): blocked.append('View membership changed; cannot recreate original IDs')
        for vid,old in oldviews.items():
            new=newviews.get(vid)
            if not new: continue
            for key in ('groupByFields','verticalGroupByFields','sortByFields'):
                if old[key]!=new[key]: blocked.append('View '+old['name']+': '+key+' is export-only; restore it in GitHub first')
            keys=('name','layout','filter','fields')
            if any(old[k]!=new[k] for k in keys):
                args={k:old[k] for k in ('name','layout','filter')};args['filter']=args['filter'] or ''
                args.update(viewId=vid,configuration={'visibleFieldIds':[f['id'] for f in old['fields']['nodes']]})
                changes.append({'kind':'view','input':args,'before':new})
    plan={'project_id':pid,'source_sha256':saved['sha256'],'current_sha256':current['sha256'],
          'scope':'Status only' if status_only else 'supported field values and views',
          'changes':changes,'blocked':blocked}
    plan['confirmation']=digest({'source':saved['sha256'],'project_id':pid,'scope':plan['scope'],
        'fields':current['fields'],'items':current['items'],'views':current['views'],
        'changes':changes,'blocked':blocked})
    return plan


def execute(api,store,plan):
    if plan['blocked']: raise ValueError('Restore preflight blocked: '+'; '.join(plan['blocked']))
    api.preflight(len(plan['changes']))
    journal={'plan':plan,'completed':0,'state':'prepared'}
    store.save(journal,'restore-journal')
    try:
        for change in plan['changes']:
            journal['state']='in-flight';store.save(journal,'restore-journal')
            mutation(api,change['kind'],change['input'])
            journal['completed']+=1;journal['state']='applied';store.save(journal,'restore-journal')
    except Exception as exc:
        journal['state']='interrupted';journal['error']=str(exc);store.save(journal,'restore-journal')
        raise ValueError('Restore interrupted; inspect journal and take a new dry-run before continuing: '+str(exc)) from exc
    journal['state']='writes-complete';store.save(journal,'restore-journal')


def main():
    if len(sys.argv)>1 and sys.argv[1]=='api':
        args=sys.argv[2:];variables={};query=None
        while args:
            flag,value,*args=args
            if flag not in ('-f','-F'): raise ValueError('Unsupported GraphQL adapter argument')
            key,val=value.split('=',1)
            if key=='query': query=val
            else: variables[key]=int(val) if flag=='-F' and val.isdigit() else val
        if not query: raise ValueError('Missing query')
        if query.lstrip().startswith('mutation'): time.sleep(1)
        print(json.dumps({'data':API().query(query,variables)}));return
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    guard=sub.add_parser('guard');guard.add_argument('--writes',type=int,default=20)
    snap=sub.add_parser('snapshot');snap.add_argument('--dry-run',action='store_true',help='Read/export JSON to stdout without saving a local snapshot')
    restore=sub.add_parser('restore');restore.add_argument('snapshot');restore.add_argument('--dry-run',action='store_true')
    restore.add_argument('--apply',action='store_true');restore.add_argument('--confirm',help='Exact project node ID, required for apply')
    restore.add_argument('--status-only',action='store_true');restore.add_argument('--plan',help='Confirmation hash from the reviewed dry-run')
    opts=sub.add_parser('options');opts.add_argument('field');opts.add_argument('--names',required=True);opts.add_argument('--apply',action='store_true')
    args=parser.parse_args();config=settings(os.environ.get('SQUAD_SETTINGS_FILE') or os.environ.get('SQUAD_SETTINGS'))
    api=API();store=Store(config)
    with store.lock():
        current=capture(api,config)
        if args.command=='guard':
            api.preflight(args.writes)
            print(json.dumps({'snapshot':store.save(current,'before-board-write')}));return
        if args.command=='snapshot':
            print(json.dumps(current,indent=2) if args.dry_run else json.dumps({'snapshot':store.save(current,'snapshot')}));return
        before=store.save(current,'before-'+args.command)
        if args.command=='options':
            field=next((f for f in current['fields'] if f['name']==args.field),None)
            if not field or field['dataType']!='SINGLE_SELECT': raise ValueError('Single-select field not found')
            options=merge_options(field['options'],args.names.splitlines())
            plan={'project_id':current['project']['id'],'blocked':[],'changes':[],'snapshot':before}
            if options!=field['options']:
                plan['changes']=[{'kind':'field','input':{'fieldId':field['id'],'singleSelectOptions':options}}]
        else:
            saved=load_snapshot(args.snapshot)
            plan=plan_restore(saved,current,args.status_only,config.get('status_field','Status'));plan['snapshot']=before
        print(json.dumps(plan,indent=2),flush=True)
        if not args.apply: return
        if args.command=='restore' and (args.dry_run or args.confirm!=current['project']['id'] or args.plan!=plan['confirmation']):
            raise ValueError('Apply requires --confirm PROJECT_ID and --plan HASH from the current reviewed dry-run; no --dry-run')
        if not plan['changes'] and not plan['blocked']:
            print(json.dumps({'verified':True,'snapshot':before,'unchanged':True}));return
        execute(api,store,plan)
        after=capture(api,config);path=store.save(after,'after-'+args.command)
        if args.command=='restore':
            remaining=plan_restore(saved,after,args.status_only,config.get('status_field','Status'))
            if remaining['changes'] or remaining['blocked']: raise ValueError('Post-restore verification failed; inspect '+path)
        else:
            updated=next(f for f in after['fields'] if f['id']==field['id'])
            if any(o not in updated['options'] for o in field['options']): raise ValueError('Option identity changed unexpectedly; inspect '+path)
            if after['items']!=current['items']: raise ValueError('Item values changed unexpectedly; inspect '+path)
        print(json.dumps({'verified':True,'snapshot':path}))


if __name__=='__main__':
    try: main()
    except (ValueError,KeyError,OSError) as exc:
        print('squad board backup: '+str(exc),file=sys.stderr);sys.exit(1)
