#!/usr/bin/env python3
"""Structured issue blockers: human-readable ownership and fail-closed readiness."""
import json
import re
import time

START='<!-- squad:blockers:v1 -->'
END='<!-- /squad:blockers -->'
CATEGORIES=('decision-required','missing-customer-input','missing-estimate','dependency-open',
            'provider-limited','review-required','acceptance-evidence-missing','metadata-repair-required')
ATTENTION='🟠 needs-your-action'


def validate(record):
    if not isinstance(record,dict): raise ValueError('blocker must be an object')
    for key in ('id','category','owner','next_action','why','recommendation','evidence'):
        if not isinstance(record.get(key),str) or not record[key].strip():
            raise ValueError('blocker requires nonempty '+key)
    if record['category'] not in CATEGORIES: raise ValueError('unknown blocker category')
    if not isinstance(record.get('requires_user'),bool): raise ValueError('requires_user must be boolean')
    if record['category'] in ('decision-required','missing-customer-input') and not record['requires_user']:
        raise ValueError('human decision/input blockers must name the user')
    if record.get('status','open') not in ('open','resolved'): raise ValueError('invalid blocker status')
    if record.get('status')=='resolved' and not record.get('resolution_evidence'):
        raise ValueError('resolved blocker requires resolution evidence')
    if any(x in json.dumps(record,ensure_ascii=False) for x in (START,END,'```')):
        raise ValueError('blocker content contains reserved delimiters')
    return record


def parse(body):
    body=body or ''
    if START not in body and END not in body: return []
    if body.count(START)!=1 or body.count(END)!=1: raise ValueError('invalid blocker section')
    section=body.split(START,1)[1].split(END,1)[0]
    m=re.search(r'```json\n(.*?)\n```',section,re.S)
    if not m: raise ValueError('missing structured blocker data')
    rows=json.loads(m[1])
    if not isinstance(rows,list): raise ValueError('blockers must be a list')
    for row in rows: validate(row)
    if len({r['id'] for r in rows})!=len(rows): raise ValueError('duplicate blocker IDs')
    return rows


def render(body,records):
    for r in records: validate(r)
    text=[START,'## Squad next actions','']
    for r in records:
        if r.get('status','open')=='resolved': continue
        text += [('### 🟠 Your action is needed' if r['requires_user'] else '### Action for '+r['owner']),
                 '**Owner:** '+r['owner'], '**What to do:** '+r['next_action'],
                 '**Why:** '+r['why'], '**PM recommendation:** '+r['recommendation'],
                 '**Needed by:** '+r.get('needed_by','Before this item can continue; no calendar commitment recorded.'),
                 '**Evidence:** '+r['evidence'],
                 *(['**Authority boundary:** '+r['authority_boundary']] if r.get('authority_boundary') else []),
                 *(['**If we wait:** '+r['consequence']] if r.get('consequence') else []),'']
    text += ['<details><summary>Squad blocker metadata</summary>','', '```json',
             json.dumps(records,ensure_ascii=False,indent=2),'```','</details>',END]
    section='\n'.join(text)
    if START in (body or ''):
        parse(body)
        begin=body.index(START);end=body.index(END,begin)+len(END)
        return body[:begin]+section+body[end:]
    return (body or '').rstrip()+'\n\n'+section+'\n'


def explicit(item,config):
    try:
        records=parse(item.get('body',''))
        rows=[{**r,'reason':r['id'],'claimable':False} for r in records if r.get('status','open')=='open']
    except (ValueError,TypeError) as exc:
        return [{'reason':'invalid-blocker-metadata','category':'metadata-repair-required','owner':'project-manager',
                 'next_action':'Repair the malformed blocker record before claiming work: '+str(exc),
                 'requires_user':False,'claimable':False}]
    labels={l['name'] if isinstance(l,dict) else l for l in item.get('labels',[])}
    if not rows and labels.intersection({'blocked',ATTENTION,config.get('decider_label','action-for-decider')}):
        rows.append({'reason':'unresolved-blocker-label','category':'metadata-repair-required','owner':'project-manager',
                     'next_action':'Reconcile the blocker label with an owned, structured next action; do not assume it is resolved.',
                     'requires_user':ATTENTION in labels or config.get('decider_label','action-for-decider') in labels,'claimable':False})
    return rows


def describe(reason,item,config):
    user=config.get('decider','user')
    mapping={
      'missing-estimate':('missing-estimate','project-manager','Estimate the remaining agreed work, record it, then refresh readiness.',False),
      'role-stage-mismatch':('metadata-repair-required','project-manager','Reconcile Stage and Responsible role from the agreed handoff; preserve explicit Status.',False),
      'not-agreed':('metadata-repair-required','project-manager','Recover existing scope authority; if agreement is genuinely absent, prepare a PM-owned user request.',False),
      'dependencies-open':('dependency-open','administrator','Complete or route the open prerequisites; then refresh readiness.',False),
      'design-not-approved':('review-required','architect','Provide sufficient design and obtain independent architecture review.',False),
      'already-owned':('review-required','administrator','Process the existing job and its report; reconcile and acknowledge it before a fresh claim.',False),
      'user-paused':('decision-required',user,'Wait for the user to resume the project; do not treat quota policy as permission.',True),
      'outside-active-work':('metadata-repair-required','project-manager','Leave explicit Status unchanged; review scheduling with the user if this should be active.',False),
      'closed':('metadata-repair-required','administrator','Reconcile the closed issue with its explicit Project Status; do not reopen or move it by inference.',False),
    }
    category,owner,action,needs=mapping.get(reason,('provider-limited','administrator','Resolve capacity/freshness through the configured quota policy; do not manufacture an override.',False))
    return {'reason':reason,'category':category,'owner':owner,'next_action':action,'requires_user':needs,'claimable':False}


def verify_claim_inputs(path):
    if not path: raise ValueError('claim requires --readiness FILE: verified inputs, authority and brief blockers')
    from pathlib import Path
    data=json.loads(Path(path).read_text())
    if data.get('inputs') not in ('verified','not-required') or data.get('authority') not in ('verified','not-required'):
        raise ValueError('required inputs or authority are unresolved')
    if data.get('brief_blockers')!=[]: raise ValueError('unresolved or unassessed brief blockers')
    if not isinstance(data.get('evidence'),list) or not data['evidence'] or any(not isinstance(x,str) or not x.strip() for x in data['evidence']):
        raise ValueError('readiness evidence references are required')
    return data


def edit(config,issue,record=None,resolution=None,blocker_id=None,pm_job=None,pm_session=None):
    """Back up the affected issue; no Project field, option or view is mutated."""
    import board_backup as b
    if record is not None and record.get('requires_user'):
        from knowledge import pm_source
        source=pm_source(config,pm_job,pm_session)
        for key in ('authority_boundary','consequence'):
            if not record.get(key): raise ValueError('PM user request requires '+key)
        record={**record,'pm_review':source,'created_at':time.time()}
    api=b.API(config=config);store=b.Store(config)
    with store.lock():
        owner,repo=config['repository'].split('/',1)
        decider_label=config.get('decider_label','action-for-decider')
        names=['blocked',ATTENTION,decider_label]
        aliases=' '.join('l'+str(i)+':label(name:'+json.dumps(n)+'){id}' for i,n in enumerate(names))
        query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){id '+aliases+' issue(number:$number){id body labels(first:100){'+b.PAGE+'{id name}}}}}'
        data=api.query(query,{'owner':owner,'repo':repo,'number':issue})['repository']
        item=data['issue']
        if not item:raise ValueError('Issue not found')
        if item['labels']['pageInfo']['hasNextPage']:
            b.finish_nested(api,[(item['labels'],item['id'],'Issue','labels','id name',None)])
        before=store.save({'kind':'issue-backup','repository':config['repository'],'issue':issue,'item':item},'before-blocker-write')
        rows=parse(item['body'])
        if record is not None:
            validate(record)
            if record.get('status','open')!='open':raise ValueError('Use resolve with explicit evidence to close a blocker')
            rows=[r for r in rows if r['id']!=record['id']]+[record]
        else:
            old=next((r for r in rows if r['id']==blocker_id),None)
            if not old:raise ValueError('Unknown blocker ID')
            if not isinstance(resolution,dict) or not resolution.get('evidence'):raise ValueError('Resolution evidence is required')
            if old['requires_user'] and not resolution.get('user_authority'):
                raise ValueError('User-owned blocker needs the specific user authority/input confirmation reference')
            old.update(status='resolved',resolution_evidence=resolution)
        opened=[r for r in rows if r.get('status','open')=='open']
        desired=['blocked'] if opened else []
        if any(r['requires_user'] for r in opened):desired += [ATTENTION,decider_label]
        api.preflight(5)
        # Labels are issue metadata, never rebuilt Project single-select options.
        ids={n:(data['l'+str(i)] or {}).get('id') for i,n in enumerate(names)}
        for n in desired:
            if ids[n]:continue
            created=api.query('mutation($input:CreateLabelInput!){createLabel(input:$input){label{id}}}',
                {'input':{'repositoryId':data['id'],'name':n,'color':'D93F0B' if n!= 'blocked' else 'B60205',
                          'description':'Your decision or input is needed; read the Squad next action.' if n!= 'blocked' else 'Waiting on an owned Squad next action.'}})
            ids[n]=created['createLabel']['label']['id']
        labels=[l['id'] for l in item['labels']['nodes'] if l['name'] not in names]+[ids[n] for n in desired]
        body=render(item['body'],rows)
        # Detect concurrent body/label edits rather than overwriting another agent's work.
        latest=api.query('query($id:ID!){node(id:$id){... on Issue{body labels(first:100){'+b.PAGE+'{id name}}}}}',{'id':item['id']})['node']
        if latest['labels']['pageInfo']['hasNextPage']:
            b.finish_nested(api,[(latest['labels'],item['id'],'Issue','labels','id name',None)])
        if latest['body']!=item['body'] or {l['id'] for l in latest['labels']['nodes']}!={l['id'] for l in item['labels']['nodes']}:
            raise ValueError('Issue changed during preflight; no issue update applied; inspect and retry')
        journal={'kind':'blocker-edit','issue':issue,'before_body':item['body'],'before_labels':item['labels']['nodes'],
                 'after_body':body,'after_labels':labels,'snapshot':before,'status':'in-flight'}
        path=store.save(journal,'blocker-journal')
        try:
            api.query('mutation($input:UpdateIssueInput!){updateIssue(input:$input){issue{id}}}',
                      {'input':{'id':item['id'],'body':body,'labelIds':labels}})
        except Exception:
            store.save({**journal,'status':'interrupted','previous':path},'blocker-journal');raise
        store.save({**journal,'status':'completed','previous':path},'blocker-journal')
        from squad_runtime import transaction
        with transaction(config) as state:
            watches=state.setdefault('reply_watches',{})
            user_rows=[r for r in opened if r['requires_user']]
            if user_rows: watches[str(issue)]={'since':min(r.get('created_at',time.time()) for r in user_rows)}
            else: watches.pop(str(issue),None)
        return {'issue':issue,'blockers':rows,'snapshot':before,'project_status_changed':False}


def visibility(config):
    import board_backup as b
    api=b.API(config=config);store=b.Store(config)
    with store.lock():
        snapshot=b.capture(api,config);before=store.save(snapshot,'before-blocker-visibility')
        label=next((f for f in snapshot['fields'] if f.get('dataType')=='LABELS'),None)
        if not label:raise ValueError('Project Labels field not found')
        changes=[]
        for view in snapshot['views']:
            ids=[f['id'] for f in view['fields']['nodes']]
            if label['id'] not in ids:
                changes.append({'kind':'view','input':{'viewId':view['id'],'configuration':{'visibleFieldIds':ids+[label['id']]}},'before':view})
        if changes:b.execute(api,store,{'snapshot':before,'blocked':[],'changes':changes})
        after=b.capture(api,config);path=store.save(after,'after-blocker-visibility')
        if any(label['id'] not in [f['id'] for f in v['fields']['nodes']] for v in after['views']):
            raise ValueError('Labels visibility verification failed; inspect '+path)
        return {'snapshot':before,'verified_snapshot':path,'changed_views':len(changes),'project_status_changed':False}


def main():
    import argparse,os
    from pathlib import Path
    from squad_runtime import settings
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='action',required=True)
    s=sub.add_parser('set');s.add_argument('issue',type=int);s.add_argument('--file',required=True);s.add_argument('--pm-job');s.add_argument('--pm-session')
    s=sub.add_parser('resolve');s.add_argument('issue',type=int);s.add_argument('--id',required=True);s.add_argument('--file',required=True)
    sub.add_parser('visibility')
    a=p.parse_args();config=settings(os.environ.get('SQUAD_SETTINGS_FILE'))
    os.environ['SQUAD_API_OPERATION']='blocker-'+a.action
    if a.action=='visibility':print(json.dumps(visibility(config)));return
    value=json.loads(Path(a.file).read_text())
    result=edit(config,a.issue,record=value,pm_job=a.pm_job,pm_session=a.pm_session) if a.action=='set' else edit(config,a.issue,resolution=value,blocker_id=a.id)
    print(json.dumps(result,ensure_ascii=False,indent=2))


if __name__=='__main__':
    import sys
    try:main()
    except (ValueError,OSError,KeyError) as exc:
        print('squad blocker: '+str(exc),file=sys.stderr);sys.exit(1)
