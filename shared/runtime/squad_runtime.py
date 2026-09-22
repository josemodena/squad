#!/usr/bin/env python3
"""Durable Squad execution and GitHub tracker operations (stdlib only)."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROLES = ('administrator', 'project-manager', 'architect', 'engineer', 'architecture-reviewer', 'engineering-reviewer')
ACTIVE = ('claimed', 'running', 'interrupted')
TERMINAL = ('completed', 'failed', 'cancelled')
STAGES = {'architecture': 'architect', 'architecture-review': 'architecture-reviewer', 'engineering': 'engineer', 'engineering-review': 'engineering-reviewer', 'planning': 'project-manager'}


def settings(path=None):
    values = {}
    if path:
        lines = Path(path).read_text().splitlines()
        if lines and lines[0] == '---':
            for line in lines[1:]:
                if line == '---':
                    break
                if line and not line[0].isspace() and ':' in line:
                    k, v = line.split(':', 1)
                    values[k] = v.strip().strip('\"\'')
    for k, v in os.environ.items():
        if k.startswith('SQUAD_'):
            values[k[6:].lower()] = v
    return values


def root(config):
    return Path(os.path.expanduser(config.get('runtime_dir', config.get('scratch_root', '~/.cache/squad-scratch') + '/runtime')))


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.squad-')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, sort_keys=True)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextlib.contextmanager
def transaction(config):
    directory = root(config)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read(directory / 'state.json', {'revision': 0, 'jobs': {}, 'events': [], 'observations': [], 'paused': False})
        yield state
        atomic(directory / 'state.json', state)


def event(state, kind, **data):
    state['revision'] += 1
    state['events'].append({'at': time.time(), 'revision': state['revision'], 'kind': kind, **data})
    if kind in ('claim','bind','complete','retry','pause','resume') and state['observations']:
        previous = state['observations'][-1]
        active = sum(j['status'] in ('claimed','running') for j in state['jobs'].values())
        state['observations'].append({**previous, 'at':time.time(), 'active':active,
            'eligible':0 if state['paused'] else max(0, previous['eligible']-(1 if kind == 'claim' else 0)),
            'reason':'user-paused' if state['paused'] else ('active' if active else 'awaiting-eligibility-check')})


def policy(config):
    value = read(root(config) / 'policy.json', {'mode': config.get('quota_mode', 'pacing')})
    if value.get('until') and time.time() >= value['until']:
        return {'mode': config.get('quota_mode', 'pacing'), 'expired_override': value}
    return value


def apply_policy(config, data, allowance, used, resets_at, captured, now):
    """A voluntary override can never override provider exhaustion or freshness."""
    p = policy(config)
    mode = p['mode']
    if mode not in ('pacing', 'weekly', 'unrestricted'):
        raise ValueError('unknown quota mode')
    if mode == 'weekly':
        allowance = float(config.get('quota_weekly_cap_percent', 85))
    elif mode == 'unrestricted':
        allowance = 100.0
    windows = data.get('provider_windows', [])
    blocked = [w for w in windows if float(w['used_percentage']) >= 100]
    if used >= 100:
        blocked.append({'resets_at': resets_at})
    stale = now - captured > 3600 or captured > now + 60 or resets_at <= now
    reason = 'provider-limit' if blocked else ('policy' if used >= allowance else 'available')
    result = 'stale' if stale else ('suspend' if blocked or used >= allowance else 'run')
    resume_at = max((int(w['resets_at']) for w in blocked), default=0)
    return {'verdict': result, 'reason': 'stale' if stale else reason, 'policy': p,
            'allowance_to_date': allowance, 'headroom': round(allowance-used, 3), 'resume_at': resume_at}


def run(*args, json_output=True):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip() or 'command failed')
    return json.loads(result.stdout) if json_output else result.stdout


def gh(*args):
    return run('gh', *args)


def pages(endpoint):
    # Older supported gh versions emit successive JSON arrays without --slurp.
    stream = run('gh', 'api', '--paginate', endpoint, json_output=False)
    decoder, offset, items = json.JSONDecoder(), 0, []
    while offset < len(stream):
        if stream[offset].isspace():
            offset += 1
            continue
        page, offset = decoder.raw_decode(stream, offset)
        if not isinstance(page, list):
            raise ValueError('Expected a JSON array from paginated GitHub REST endpoint')
        items.extend(page)
    return items


def board(config, dependencies=True):
    """Paginated batched readiness reads with the same bounded API retries as backups."""
    import board_backup as b
    api=b.API()
    owner='organization' if config.get('project_owner_type') in ('org','organization') else 'user'
    data=api.query('query($owner:String!,$number:Int!){'+owner+'(login:$owner){projectV2(number:$number){id}}}',
                   {'owner':config['project_owner'],'number':int(config['project_number'])})
    project=(data.get(owner) or {}).get('projectV2')
    if not project: raise ValueError('Project missing or inaccessible')
    issue='id number title state url body repository{nameWithOwner} labels(first:100){'+b.PAGE+'{name}}'
    if dependencies: issue+=' blockedBy(first:100){'+b.PAGE+'{id number state url}}'
    values=b.VALUE.replace(' optionId }',' optionId name }')
    selection='id isArchived content{__typename ... on Issue{'+issue+'}} fieldValues(first:100){'+b.PAGE+'{'+values+'}}'
    nodes=b.connection(api,project['id'],'items',selection,50)
    requests=[];items=[]
    for node in nodes:
        content=node['content']
        if not content: raise ValueError('Unreadable Project item; readiness is incomplete')
        if content['__typename']!='Issue' or content['repository']['nameWithOwner']!=config['repository']:continue
        if node['fieldValues']['pageInfo']['hasNextPage']:
            requests.append((node['fieldValues'],node['id'],'ProjectV2Item','fieldValues',values,None))
        for key,sel in [('labels','name')]+([('blockedBy','id number state url')] if dependencies else []):
            if content[key]['pageInfo']['hasNextPage']: requests.append((content[key],content['id'],'Issue',key,sel,None))
        items.append(node)
    b.finish_nested(api,requests)
    result=[]
    for node in items:
        content=node['content'];fields={}
        for value in node['fieldValues']['nodes']:
            if not value or 'field' not in value:raise ValueError('Unreadable Project field value')
            name=value['field']['name']
            if value['__typename']=='ProjectV2ItemFieldSingleSelectValue':
                # Readiness needs names as well as immutable option IDs.
                fields[name]=value.get('name')
            else: fields[name]=next((value[k] for k in ('text','date','number') if k in value),None)
        result.append({**content,'labels':content['labels']['nodes'],'fields':fields,
                       'dependencies':content['blockedBy']['nodes'] if dependencies else [],
                       'item_id':node['id'],'project_id':project['id'],'archived':node['isArchived']})
    return result


def eligible(items, state, config, quota=None):
    answer = []
    for item in items:
        f = item['fields']
        import blockers
        records=blockers.explicit(item,config)
        related=[j for j in state['jobs'].values() if j['issue']==item['number'] and j.get('handoff')]
        if related:
            last=max(related,key=lambda j:j.get('claimed_at',0))
            h=last['handoff']
            if not h['fresh_job_allowed']:
                try:
                    resolved=any(r['id']==h['tracking'] and r.get('status')=='resolved' for r in blockers.parse(item.get('body','')))
                except ValueError:resolved=False
                if not resolved and not any(r['reason']==h['tracking'] for r in records):
                    records.append({'reason':'handoff-unresolved','category':'metadata-repair-required','owner':h['owner'],
                                    'next_action':h['next_action'],'requires_user':h.get('requires_user',False),'claimable':False})
        reasons = []
        stage = f.get('Stage')
        role = f.get('Responsible role')
        if item.get('archived'): reasons.append('outside-active-work')
        if item['state'].upper() != 'OPEN': reasons.append('closed')
        if f.get('Agreement') != 'Agreed': reasons.append('not-agreed')
        if f.get(config.get('status_field', 'Status')) not in ('This sprint', 'In progress', 'In review'): reasons.append('outside-active-work')
        if role not in ROLES or STAGES.get(stage) != role: reasons.append('role-stage-mismatch')
        if stage == 'engineering' and f.get('Design') not in ('Approved', 'Existing'): reasons.append('design-not-approved')
        if any(d['state'].upper() != 'CLOSED' for d in item['dependencies']): reasons.append('dependencies-open')
        if any(j['issue'] == item['number'] and (j['status'] in ACTIVE or not j.get('handled')) for j in state['jobs'].values()): reasons.append('already-owned')
        if state.get('paused'): reasons.append('user-paused')
        if quota and quota.get('verdict') != 'run': reasons.append(quota.get('reason', 'quota'))
        estimate = f.get(config.get('estimate_field', 'Estimate (credits %)'))
        if not isinstance(estimate, (float, int)) or not math.isfinite(estimate) or estimate < 0:
            reasons.append('missing-estimate')
        elif quota and quota.get('policy', {}).get('mode') != 'unrestricted' and quota.get('headroom', 0) < estimate:
            reasons.append('insufficient-headroom')
        records += [blockers.describe(reason,item,config) for reason in reasons]
        reasons = list(dict.fromkeys([r['reason'] for r in records]))
        repair_reasons={'missing-estimate','role-stage-mismatch','invalid-blocker-metadata','unresolved-blocker-label'}
        repairable=f.get('Agreement')=='Agreed' and bool(set(reasons)&repair_reasons) and not state.get('paused') and not any(r in reasons for r in ('already-owned','closed','outside-active-work')) and (not quota or quota.get('verdict')=='run')
        answer.append({**item, 'role': role, 'stage': stage, 'eligible': not reasons, 'claimable':not reasons,
                       'reasons': reasons, 'blockers':records, 'requires_user':any(r['requires_user'] for r in records),
                       'next_actions':records, 'metadata_repair':{'owner':'project-manager','claimable':repairable,
                       'next_action':'Repair metadata from existing authority without changing scope or explicit Status; refresh readiness.'} if set(reasons)&repair_reasons else None})
    return sorted(answer, key=lambda i: (str(i['fields'].get('Priority', 'P2')), i['fields'].get('Needed by') or '9999', i['number']))


def quota_read(config):
    command = config.get('quota_command', 'codex-quota')
    if '/' not in command and (Path(__file__).parent / command).exists():
        command = str(Path(__file__).parent / command)
    p = subprocess.run([command, '--json'], text=True, capture_output=True)
    try:
        value = json.loads(p.stdout)
        if value.get('verdict') not in ('run', 'suspend', 'stale', 'missing'):
            raise ValueError('unknown quota verdict')
        return value
    except (ValueError, TypeError):
        return {'verdict': 'missing', 'reason': 'quota-unreadable', 'detail': p.stderr.strip()}


def backup_board(config):
    import board_backup as backup
    api=backup.API();store=backup.Store(config)
    with store.lock():
        snapshot=backup.capture(api,config)
        api.preflight(10)
        return store.save(snapshot,'before-board-write')


def field_set(config, issue, field, value):
    import board_backup as backup
    api=backup.API();store=backup.Store(config)
    with store.lock():
        snapshot=backup.capture(api,config)
        item=next((i for i in snapshot['items'] if i['content'].get('number')==issue
                   and i['content'].get('repository',{}).get('nameWithOwner')==config['repository']),None)
        entry=next((f for f in snapshot['fields'] if f['name']==field),None)
        if not item or not entry: raise ValueError('Issue or field not found on project')
        kind=entry['dataType']
        if kind=='SINGLE_SELECT':
            option=next((o for o in entry['options'] if o['name']==value),None)
            if not option: raise ValueError('Unknown option for '+field)
            new={'singleSelectOptionId':option['id']}
        elif kind=='DATE':
            dt.date.fromisoformat(value);new={'date':value}
        elif kind=='NUMBER':
            number=float(value)
            if not math.isfinite(number): raise ValueError('Invalid number')
            if field.startswith('Estimate') and number<0: raise ValueError('Invalid estimate')
            new={'number':number}
        elif kind=='TEXT': new={'text':value}
        else: raise ValueError('Unsupported field type '+kind)
        before=store.save(snapshot,'before-field')
        args={'projectId':snapshot['project']['id'],'itemId':item['id'],'fieldId':entry['id'],'value':new}
        backup.execute(api,store,{'blocked':[],'snapshot':before,'changes':[{'kind':'value','input':args}]})
    return {'issue':issue,'field':field,'value':value,'snapshot':before}


def checkpoint(job, source):
    evidence = read(source)
    if not isinstance(evidence, dict) or not evidence.get('next_step'):
        raise ValueError('checkpoint needs next_step and may include tests, report, remaining and blocker')
    cwd = job['worktree']
    # Binary and untracked changes survive even without a model-authored commit.
    git = lambda *args: run('git', '-C', cwd, *args, json_output=False)
    head = git('rev-parse', 'HEAD').strip()
    target = Path(job['artifacts'])
    target.mkdir(parents=True, exist_ok=True)
    stamp = str(time.time_ns())
    patch = target / (stamp+'.patch')
    with patch.open('w') as f:
        p = subprocess.run(['git', '-C', cwd, 'diff', '--binary', 'HEAD'], stdout=f, text=True)
    if p.returncode: raise ValueError('could not preserve tracked changes')
    # Preserve new files without following symlinks; excluded/ignored files stay in worktree.
    import tarfile
    paths = git('ls-files', '--others', '--exclude-standard', '-z').split('\0')
    archive = target / (stamp+'.tar')
    with tarfile.open(archive, 'w') as tar:
        for name in filter(None, paths):
            tar.add(Path(cwd)/name, arcname=name, recursive=False)
    value = {**evidence, 'head': head, 'patch': str(patch), 'untracked': str(archive), 'at': time.time()}
    atomic(target / 'checkpoint.json', value)
    return value


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    for name in ('ready', 'next', 'recover', 'metrics', 'wake', 'state', 'models'):
        sub.add_parser(name)
    pol = sub.add_parser('policy')
    pol.add_argument('--mode', choices=('pacing', 'weekly', 'unrestricted'))
    pol.add_argument('--reason')
    pol.add_argument('--until', type=int, help='UTC epoch expiry; omitted means until explicitly changed')
    for name in ('pause', 'resume'):
        s = sub.add_parser(name); s.add_argument('--reason', required=True)
    s = sub.add_parser('observe'); s.add_argument('--reason', required=True); s.add_argument('--eligible', type=int, required=True); s.add_argument('--capacity', type=int, required=True)
    s = sub.add_parser('issue-create'); s.add_argument('--key', required=True); s.add_argument('--title', required=True); s.add_argument('--file', required=True)
    s = sub.add_parser('run'); s.add_argument('job'); s.add_argument('argv', nargs=argparse.REMAINDER)
    s = sub.add_parser('comment'); s.add_argument('issue', type=int); s.add_argument('--file', required=True)
    s = sub.add_parser('issue-read'); s.add_argument('issue', type=int)
    s = sub.add_parser('pr-read'); s.add_argument('pr', type=int)
    s = sub.add_parser('review-prepare'); s.add_argument('pr', type=int)
    s = sub.add_parser('review-record'); s.add_argument('pr', type=int); s.add_argument('--head', required=True); s.add_argument('--verdict', choices=('pass','fixes-required','do-not-merge'), required=True); s.add_argument('--file', required=True)
    s = sub.add_parser('field'); s.add_argument('issue', type=int); s.add_argument('name'); s.add_argument('value')
    s = sub.add_parser('dependency'); s.add_argument('action', choices=('list','add','remove')); s.add_argument('issue', type=int); s.add_argument('prerequisite', nargs='?', type=int)
    s = sub.add_parser('claim'); s.add_argument('job'); s.add_argument('--issue', type=int, required=True); s.add_argument('--role', choices=ROLES, required=True); s.add_argument('--worktree', required=True); s.add_argument('--brief', required=True); s.add_argument('--readiness')
    s = sub.add_parser('repair-claim'); s.add_argument('job'); s.add_argument('--issue',type=int,required=True); s.add_argument('--worktree',required=True); s.add_argument('--brief',required=True)
    s = sub.add_parser('bind'); s.add_argument('job'); s.add_argument('--worker', required=True); s.add_argument('--model', required=True); s.add_argument('--thread'); s.add_argument('--turn'); s.add_argument('--rollout')
    s = sub.add_parser('checkpoint'); s.add_argument('job'); s.add_argument('--file', required=True)
    s = sub.add_parser('complete'); s.add_argument('job'); s.add_argument('--result', choices=('completed','failed','interrupted','cancelled'), required=True); s.add_argument('--report', required=True)
    s = sub.add_parser('settle'); s.add_argument('--through', type=int, required=True)
    s = sub.add_parser('handoff'); s.add_argument('job'); s.add_argument('--file',required=True)
    s = sub.add_parser('ack'); s.add_argument('job')
    s = sub.add_parser('retry'); s.add_argument('job'); s.add_argument('--reason', required=True)
    s = sub.add_parser('external'); s.add_argument('id'); s.add_argument('--reason', required=True)
    return p


def main():
    args = parser().parse_args()
    config = settings(os.environ.get('SQUAD_SETTINGS_FILE'))
    cmd = args.command
    if cmd == 'models':
        result = {role: config.get(role.replace('-', '_')+'_model') for role in ROLES}
    elif cmd == 'policy':
        if args.mode:
            if not args.reason: raise ValueError('--reason is required for policy changes')
            if args.until and args.until <= time.time(): raise ValueError('expiry must be in the future')
            with transaction(config) as state:
                value = {'mode': args.mode, 'reason': args.reason, 'until': args.until, 'at': time.time()}
                atomic(root(config)/'policy.json', value)
                event(state, 'policy', **value)
        result = policy(config)
    elif cmd == 'issue-create':
        if not args.key or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in args.key): raise ValueError('invalid stable issue key')
        marker = '<!-- squad-key:'+args.key+' -->'
        body = marker+'\n'+Path(args.file).read_text()
        with transaction(config) as state:
            # Paginated REST read avoids dependence on search-index freshness after
            # a successful creation whose network response was lost.
            matches = [i for i in pages('repos/'+config['repository']+'/issues?state=all&per_page=100') if marker in (i.get('body') or '') and not i.get('pull_request')]
            if len(matches) > 1: raise ValueError('ambiguous issue key; reconcile duplicates')
            if matches: issue = matches[0]
            else:
                issue = gh('api','repos/'+config['repository']+'/issues','-f','title='+args.title,'-f','body='+body)
                event(state,'issue-create',issue=issue['number'],key=args.key)
            backup_board(config)
            run('gh','project','item-add',config['project_number'],'--owner',config['project_owner'],'--url',issue['html_url'],json_output=False)
            result = {'number':issue['number'],'url':issue['html_url'],'key':args.key}
    elif cmd == 'run':
        command = args.argv[1:] if args.argv and args.argv[0] == '--' else args.argv
        if not command: raise ValueError('provide a command after --')
        with transaction(config) as state:
            job = state['jobs'].get(args.job)
            if not job or job['status'] not in ('claimed','running'): raise ValueError('job is not active')
            directory = Path(job['artifacts']); directory.mkdir(parents=True,exist_ok=True)
            stamp = str(time.time_ns())
            record = directory/(stamp+'-process.json')
            log = directory/(stamp+'.log')
            process = {'command':command,'cwd':job['worktree'],'supervisor_pid':os.getpid(),'log':str(log),'status':'starting','started_at':time.time()}
            atomic(record,process)
            job.setdefault('processes',[]).append(str(record))
            event(state,'command-start',job=args.job,record=str(record))
        with log.open('ab',buffering=0) as output:
            child = subprocess.Popen(command,cwd=job['worktree'],stdout=output,stderr=subprocess.STDOUT)
            process.update({'pid':child.pid,'status':'running'}); atomic(record,process)
            try: status = child.wait()
            except BaseException:
                process['status']='unknown'; atomic(record,process); raise
        process.update({'status':'completed' if status == 0 else 'failed','exit_code':status,'finished_at':time.time()}); atomic(record,process)
        with transaction(config) as state:
            state['jobs'][args.job].setdefault('process_results',{})[str(record)] = status
            event(state,'command-finished',job=args.job,record=str(record),exit_code=status)
        result = process
        print(json.dumps(result)); sys.exit(0 if status == 0 else 1)
    elif cmd in ('issue-read','pr-read'):
        kind = 'issue' if cmd == 'issue-read' else 'pr'
        fields = 'number,title,body,state,comments' if kind == 'issue' else 'number,title,body,state,headRefOid,headRefName,baseRefName,comments,files'
        result = gh(kind, 'view', str(args.issue if kind == 'issue' else args.pr), '--repo', config['repository'], '--json', fields)
    elif cmd == 'comment':
        result = run('gh', 'issue', 'comment', str(args.issue), '--repo', config['repository'], '--body-file', str(Path(args.file).resolve()), json_output=False)
    elif cmd == 'review-prepare':
        pr = gh('pr', 'view', str(args.pr), '--repo', config['repository'], '--json', 'headRefOid,baseRefName')
        if pr['baseRefName'] != 'main': raise ValueError('review expects main as the integration base')
        cwd = config.get('project_dir', os.getcwd())
        run('git','-C',cwd,'fetch','origin','--prune',json_output=False)
        run('git','-C',cwd,'fetch','origin','pull/'+str(args.pr)+'/head',json_output=False)
        fetched = run('git','-C',cwd,'rev-parse','FETCH_HEAD',json_output=False).strip()
        if fetched != pr['headRefOid']: raise ValueError('PR changed while fetching; prepare again')
        target = root(config)/('review-'+str(args.pr)+'-'+fetched[:12])
        if target.exists(): raise ValueError('review worktree already exists; inspect rather than overwrite')
        target.parent.mkdir(parents=True,exist_ok=True)
        run('git','-C',cwd,'worktree','add','--detach',target,'origin/main',json_output=False)
        run('git','-C',target,'merge','--no-ff','--no-edit',fetched,json_output=False)
        result = {'worktree':str(target),'head':fetched,'base':run('git','-C',cwd,'rev-parse','origin/main',json_output=False).strip()}
    elif cmd == 'review-record':
        root(config).mkdir(parents=True, exist_ok=True)
        report = Path(args.file).read_text()
        actual = gh('pr','view',str(args.pr),'--repo',config['repository'],'--json','headRefOid')['headRefOid']
        if actual != args.head: raise ValueError('PR head changed after review; review the new head')
        marker = '<!-- squad-review-passed:'+args.head+' -->' if args.verdict == 'pass' else '<!-- squad-review-failed:'+args.head+' -->'
        # Stable marker + verdict avoids duplicate comments when a client loses its response.
        comments = gh('pr','view',str(args.pr),'--repo',config['repository'],'--json','comments')['comments']
        body = marker+'\nVerdict: '+args.verdict+'\n\n'+report
        if not any(c['body'] == body for c in comments):
            with tempfile.NamedTemporaryFile(mode='w', dir=root(config), suffix='.md') as f:
                f.write(body); f.flush()
                run('gh','pr','comment',str(args.pr),'--repo',config['repository'],'--body-file',f.name,json_output=False)
        run('gh','pr','edit',str(args.pr),'--repo',config['repository'],'--add-label' if args.verdict == 'pass' else '--remove-label','review:passed',json_output=False)
        result = {'pr':args.pr,'head':args.head,'verdict':args.verdict}
    elif cmd == 'field':
        result = field_set(config, args.issue, args.name, args.value)
    elif cmd == 'dependency':
        endpoint = 'repos/'+config['repository']+'/issues/'+str(args.issue)+'/dependencies/blocked_by'
        if args.action == 'list': result = pages(endpoint+'?per_page=100')
        else:
            if not args.prerequisite or args.prerequisite == args.issue: raise ValueError('a different prerequisite issue is required')
            # GitHub validates cycles, existence and permissions; use numeric issue ID, not number.
            dep = gh('api', 'repos/'+config['repository']+'/issues/'+str(args.prerequisite))
            result = gh('api', endpoint, '-X', 'POST', '-F', 'issue_id='+str(dep['id'])) if args.action == 'add' else run('gh', 'api', endpoint+'/'+str(dep['id']), '-X', 'DELETE', json_output=False)
    else:
        items = board(config) if cmd in ('ready', 'next', 'claim', 'repair-claim') else None
        quota = quota_read(config) if cmd in ('ready', 'next', 'claim', 'repair-claim', 'wake') else None
        with transaction(config) as state:
            jobs = state['jobs']
            if cmd in ('ready','next'):
                result = eligible(items, state, config, quota)
                waiting = any(i['reasons'] and set(i['reasons']) <= {'policy','provider-limit','stale','missing','quota','quota-unreadable','insufficient-headroom'} for i in result)
                required = min((i['fields'][config.get('estimate_field','Estimate (credits %)')] for i in result if i['reasons'] and set(i['reasons']) <= {'policy','provider-limit','stale','missing','quota','quota-unreadable','insufficient-headroom'}), default=0)
                if waiting != state.get('capacity_wait',False) or required != state.get('capacity_required',0):
                    state['capacity_wait'] = waiting
                    state['capacity_required'] = required
                    event(state,'capacity-wait',waiting=waiting,required=required)
                state['readiness']={'captured_at':time.time(),'items':[{k:i[k] for k in ('number','url','stage','role','blockers','metadata_repair') if k in i} for i in result if i['fields'].get('Agreement')=='Agreed' and not i['eligible']]}
                active = sum(j['status'] in ('claimed','running') for j in jobs.values())
                count = sum(i['eligible'] for i in result)
                state['observations'].append({'at':time.time(), 'eligible':count, 'capacity':int(config.get('max_workers',3))-active, 'active':active, 'reason':'ready' if count else ('user-paused' if state['paused'] else quota.get('reason','blocked'))})
                if cmd=='next':
                    actions=[]
                    for i in result:
                        if i.get('archived') or i['state'].upper()!='OPEN' or 'outside-active-work' in i['reasons']:continue
                        if i['eligible']: actions.append({'issue':i['number'],'action':'dispatch','owner':i['role'],'next_action':'Claim eligible work with a verified readiness assessment.','requires_user':False})
                        elif i.get('metadata_repair') and i['metadata_repair']['claimable']:
                            actions.append({'issue':i['number'],'action':'repair-metadata',**i['metadata_repair'],'requires_user':False})
                            actions.extend({'issue':i['number'],'action':'request-user',**b} for b in i['blockers'] if b['requires_user'])
                        else:
                            actions.extend({'issue':i['number'],'action':'request-user' if b['requires_user'] else 'resolve-or-wait',**b} for b in i['blockers'])
                    result={'actions':actions,'can_continue':any(a['action'] in ('dispatch','repair-metadata') for a in actions),
                            'instruction':'Process all actionable handoffs; only wait on named external dependencies, user decisions, pause or capacity.'}
            elif cmd in ('pause','resume'):
                state['paused'] = cmd == 'pause'; event(state, cmd, reason=args.reason); result = {'paused': state['paused']}
            elif cmd in ('claim','repair-claim'):
                if not args.job or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in args.job): raise ValueError('invalid job id')
                if sum(j['status'] in ('claimed','running') for j in jobs.values()) >= int(config.get('max_workers',3)): raise ValueError('worker capacity is full')
                if args.job in jobs: raise ValueError('job id already exists; inspect it, do not launch twice')
                item = next((i for i in eligible(items, state, config, quota) if i['number'] == args.issue), None)
                repair=cmd=='repair-claim'
                if not item or not (item.get('metadata_repair') and item['metadata_repair']['claimable'] if repair else item['eligible']): raise ValueError('not eligible: '+str(item and item['reasons']))
                role='project-manager' if repair else args.role
                if not repair and item['role'] != role: raise ValueError('assignment does not match responsible role')
                import blockers
                assessment={'kind':'metadata-repair','scope':'existing authority only'} if repair else blockers.verify_claim_inputs(args.readiness)
                if repair and quota.get('policy',{}).get('mode')!='unrestricted' and quota.get('headroom',0)<float(config.get('metadata_repair_estimate',0.5)):
                    raise ValueError('insufficient headroom for bounded metadata repair')
                model = config.get(role.replace('-', '_')+'_model')
                if not model: raise ValueError('role model is not configured')
                brief = Path(args.brief).read_text()
                worktree = str(Path(args.worktree).resolve())
                if not Path(worktree).is_dir(): raise ValueError('worktree must exist before claim')
                job = {'id': args.job, 'issue': args.issue, 'role': role, 'kind':'metadata-repair' if repair else 'delivery', 'readiness_assessment':assessment, 'model': model, 'status': 'claimed', 'worktree': worktree, 'brief': brief, 'artifacts': str(root(config)/'jobs'/args.job), 'claimed_at': time.time(), 'handled': False}
                jobs[args.job] = job; event(state, 'claim', job=args.job); result = job
            elif cmd == 'settle':
                if args.through > state['revision']: raise ValueError('cannot settle a future revision')
                state['settled'] = max(state.get('settled', 0), args.through)
                result = {'settled': state['settled']}
            elif cmd == 'external':
                if not any(e.get('external_id') == args.id for e in state['events']): event(state, 'external', external_id=args.id, reason=args.reason)
                result = {'recorded': args.id}
            elif cmd in ('bind','checkpoint','complete','handoff','ack','retry'):
                job = jobs.get(args.job)
                if not job: raise ValueError('unknown job')
                if cmd == 'bind':
                    if job['status'] not in ('claimed','running'): raise ValueError('job is terminal')
                    if job['role'].endswith('reviewer') and any(j.get('worker') == args.worker and j['issue'] == job['issue'] and j['role'] in ('architect','engineer') for j in jobs.values()): raise ValueError('author cannot review their own work')
                    if args.model != job['model']: raise ValueError('actual model differs from configured role; stop and resolve explicitly')
                    if job.get('worker') and job['worker'] != args.worker: raise ValueError('job already bound to another worker')
                    job.update({'worker': args.worker, 'actual_model': args.model, 'thread': args.thread, 'turn': args.turn, 'rollout': args.rollout, 'status': 'running'})
                elif cmd == 'checkpoint':
                    job['checkpoint'] = checkpoint(job, args.file)
                elif cmd == 'complete':
                    report = str(Path(args.report).resolve())
                    if not Path(report).is_file(): raise ValueError('report must be durable before completion')
                    if job['status'] in TERMINAL:
                        if job['status'] != args.result or job.get('report') != report: raise ValueError('conflicting completion')
                        print(json.dumps(job)); return
                    job.update({'status': args.result, 'report': report, 'completed_at': time.time(), 'handled': False})
                elif cmd == 'handoff':
                    handoff=read(args.file)
                    required=('completed','not_completed','evidence','next_action','owner','fresh_job_allowed','transition','tracking')
                    if not isinstance(handoff,dict) or any(k not in handoff for k in required):raise ValueError('handoff requires '+', '.join(required))
                    for key in ('evidence','next_action','owner','tracking'):
                        if not isinstance(handoff[key],str) or not handoff[key].strip():raise ValueError('handoff requires nonempty '+key)
                    if not isinstance(handoff['fresh_job_allowed'],bool):raise ValueError('fresh_job_allowed must be boolean')
                    job['handoff']=handoff
                elif cmd == 'ack':
                    if job['status'] not in TERMINAL: raise ValueError('only a terminal job can be acknowledged')
                    if not job.get('handoff'):raise ValueError('record an owned handoff before acknowledging completion')
                    job['handled'] = True
                elif cmd == 'retry':
                    if job['status'] != 'interrupted': raise ValueError('only interrupted jobs can be released after checking native worker and processes')
                    job.update({'status':'cancelled', 'handled': True, 'recovery_reason': args.reason})
                event(state, cmd, job=args.job); result = job
            elif cmd in ('state','recover'): result = state if cmd == 'state' else {'revision': state['revision'], 'external_events': [e for e in state['events'] if e['kind'] in ('external','resume','policy') and e.get('revision',0) > state.get('settled',0)], 'paused': state['paused'], 'jobs': [j for j in jobs.values() if j['status'] in ACTIVE or not j.get('handled')], 'policy': policy(config), 'readiness':state.get('readiness',{'captured_at':None,'items':[]})}
            elif cmd == 'observe':
                if min(args.eligible, args.capacity) < 0: raise ValueError('counts cannot be negative')
                observation = {'at': time.time(), 'eligible': args.eligible, 'capacity': args.capacity, 'active': sum(j['status'] in ('claimed','running') for j in jobs.values()), 'reason': args.reason}
                state['observations'].append(observation); result = observation
            elif cmd == 'metrics':
                observations = state['observations']; totals = {}; avoidable = 0; observed = 0
                for i, o in enumerate(observations):
                    end = observations[i+1]['at'] if i+1 < len(observations) else time.time()
                    duration = max(0, end-o['at']); observed += duration
                    totals[o['reason']] = totals.get(o['reason'], 0)+duration
                    if o['eligible'] and o['capacity'] and not o['active']: avoidable += duration
                handoffs = []
                for job in jobs.values():
                    prior = [j for j in jobs.values() if j['id'] != job['id'] and j['issue'] == job['issue'] and j.get('completed_at',float('inf')) <= job['claimed_at']]
                    if prior: handoffs.append(job['claimed_at']-max(j['completed_at'] for j in prior))
                result = {'handoff_seconds': handoffs, 'completed_review_assignments':sum(j['role'].endswith('reviewer') and j['status'] == 'completed' for j in jobs.values()), 'observed_seconds': observed, 'avoidable_idle_seconds': avoidable, 'by_reason_seconds': totals, 'avoidable_idle_percent': 100*avoidable/observed if observed else None, 'note': 'Intervals between explicit observations, not inferred historical utilisation.'}
            elif cmd == 'wake':
                # A native turn remains the launch authority. This only requests recovery;
                # the gateway must refuse it while the Administrator is active.
                for j in jobs.values():
                    if j['status'] not in ('claimed','running') or not all(j.get(k) for k in ('rollout','thread','turn')):
                        continue
                    try:
                        records = [json.loads(line) for line in Path(j['rollout']).read_text().splitlines()]
                    except (OSError, ValueError):
                        continue
                    identities = {r['payload'].get('id') for r in records if r.get('type') == 'session_meta'}
                    ends = [r['payload'] for r in records if r.get('type') == 'event_msg' and r.get('payload',{}).get('type') == 'task_complete' and r['payload'].get('turn_id') == j['turn']]
                    if identities == {j['thread']} and len(ends) == 1:
                        j['status'] = 'interrupted'
                        j['native_result'] = ends[0]
                        j['recovery_required'] = 'Worker ended without a durable completion; inspect output and checkpoint before retry.'
                        event(state, 'native-ended', job=j['id'])
                # Reconcile a process result even if its supervisor died after
                # writing the result but before journalling the completion.
                for j in jobs.values():
                    for path in j.get('processes',[]):
                        process = read(path,{})
                        if 'exit_code' in process and path not in j.get('process_results',{}):
                            j.setdefault('process_results',{})[path] = process['exit_code']
                            event(state,'command-finished',job=j['id'],record=path,exit_code=process['exit_code'])
                capacity_ready = state.get('capacity_wait',False) and quota['verdict'] == 'run' and (quota.get('policy',{}).get('mode') == 'unrestricted' or quota.get('headroom',0) >= state.get('capacity_required',0))
                if capacity_ready and not state.get('capacity_ready',False):
                    event(state,'capacity-available',required=state.get('capacity_required',0))
                state['capacity_ready'] = capacity_ready
                actionable = any(j['status'] in ACTIVE or not j.get('handled') for j in jobs.values())
                external = any(e['kind'] in ('external','resume','policy') and e.get('revision',0) > state.get('settled',0) for e in state['events'])
                result = {'ready': not state['paused'] and quota['verdict'] == 'run' and (actionable or external or capacity_ready), 'reason': 'reconcile durable execution and external changes', 'id': 'runtime-'+str(state['revision']), 'quota': quota}
            else: raise ValueError('unsupported command')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(json.dumps({'error': str(exc)}), file=sys.stderr)
        sys.exit(1)
