"""Project-scoped, locally versioned decisions and reviewed lessons."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

from squad_runtime import ROLES, atomic, read, root


def pm_source(config, job=None, session=None):
    if bool(job) == bool(session): raise ValueError('Supply exactly one --pm-job or --pm-session')
    if job:
        value = read(root(config)/'state.json', {}).get('jobs', {}).get(job, {})
        if value.get('role') != 'project-manager' or value.get('status') not in ('running','completed') or not value.get('worker'):
            raise ValueError('PM provenance requires a bound running/completed Project Manager job')
        return {'job': job, 'model': value.get('actual_model'), 'role': 'project-manager'}
    for path in (root(config)/'meetings').glob('*/*.json'):
        value = read(path, {})
        if value.get('session_id') == session and value.get('status') in ('running','completed') and Path(value.get('project','')).resolve()==Path(config.get('project_dir',os.getcwd())).resolve():
            return {'session': session, 'model': value.get('model'), 'role': 'project-manager'}
    raise ValueError('PM session must be a captured direct meeting session')


def directory(config):
    identity = '\0'.join(config.get(k,'') for k in ('repository','project_owner','project_number'))
    key = hashlib.sha256(identity.encode()).hexdigest()[:20]
    return Path(os.path.expanduser(config.get('knowledge_dir', str(root(config)/'knowledge'))))/key


@contextlib.contextmanager
def store(config):
    path = directory(config); path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    with (path/'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (path/'.git').exists():
            subprocess.run(['git','init','-q',str(path)],check=True,capture_output=True)
            (path/'.gitignore').write_text('lock\n.squad-*\n')
        elif subprocess.check_output(['git','-C',str(path),'status','--porcelain'],text=True).strip():
            raise ValueError('Knowledge store has uncommitted changes; reconcile the interrupted write before editing')
        yield path


def save(path, records):
    atomic(path/'records.json', records); (path/'records.json').chmod(0o600)
    def git(*args):
        subprocess.run(['git','-C',str(path),*args],check=True,capture_output=True)
    git('add','--','records.json','.gitignore')
    changed = subprocess.run(['git','-C',str(path),'diff','--cached','--quiet']).returncode
    if changed:
        git('-c','user.name=Squad local records','-c','user.email=noreply@localhost',
            '-c','core.hooksPath=/dev/null','commit','-q','-m','Update decisions and lessons')


def committed(config):
    path=directory(config)
    if not (path/'records.json').exists(): return {}
    result=subprocess.run(['git','-C',str(path),'show','HEAD:records.json'],capture_output=True,text=True)
    if result.returncode: raise ValueError('Knowledge store has no committed records; reconcile the interrupted write')
    return json.loads(result.stdout)


def add(config, value):
    for k in ('id','kind','summary','evidence','applicability'):
        if not isinstance(value.get(k),str) or not value[k].strip(): raise ValueError('Record requires '+k)
    if not re.fullmatch(r'[a-zA-Z0-9._-]+',value['id']): raise ValueError('Invalid record ID')
    if value['kind'] not in ('lesson','decision'): raise ValueError('kind must be lesson or decision')
    if not isinstance(value.get('roles'),list) or not value['roles'] or any(r not in ROLES for r in value['roles']):
        raise ValueError('Provide applicable Squad roles')
    if value.get('issues') is not None and (not isinstance(value['issues'],list) or any(type(n) is not int or n<1 for n in value['issues'])):
        raise ValueError('issues must contain positive issue numbers')
    if value.get('expires_at') is not None and type(value['expires_at']) not in (int,float):
        raise ValueError('expires_at must be an epoch number')
    if value['kind']=='decision' and not value.get('authority_source'): raise ValueError('Decision needs original authority_source')
    with store(config) as path:
        records = read(path/'records.json', {})
        if value['id'] in records: raise ValueError('Record ID exists; retire/supersede it instead of rewriting history')
        records[value['id']] = {**value, 'status':'proposed','created_at':time.time()}
        save(path, records)
    return records[value['id']]


def review(config, key, value, provenance):
    if value.get('status') not in ('active','rejected','retired'): raise ValueError('Review status must be active, rejected or retired')
    if not value.get('evidence') or not value.get('reason'): raise ValueError('Review needs evidence and reason')
    with store(config) as path:
        records = read(path/'records.json', {})
        if key not in records: raise ValueError('Unknown record ID')
        record = records[key]
        if record['kind']=='decision' and value['status']=='active' and not value.get('authority_check'):
            raise ValueError('PM must verify decision authority and record authority_check')
        record.update(status=value['status'])
        record.setdefault('reviews',[]).append({**value,'reviewer':provenance,'at':time.time()})
        save(path, records)
    return record


def context(config, role, issue=None):
    if role not in ROLES: raise ValueError('Unknown role')
    base = Path(__file__).resolve().parent
    docs = base.parent/'docs' if base.name=='scripts' else base.parents[1]/'docs'
    records = committed(config)
    selected = [v for v in records.values() if v['status']=='active' and role in v['roles']
                and (not v.get('issues') or issue in v['issues'])
                and (not v.get('expires_at') or v['expires_at']>time.time())]
    total=len(selected)
    decisions=[v for v in selected if v['kind']=='decision']
    lessons=sorted((v for v in selected if v['kind']=='lesson'),key=lambda v:v['created_at'],reverse=True)
    selected=decisions+lessons[:20]
    policy = config.get('authority_file')
    return {'role':role, 'job_description':(docs/'roles'/f'{role}.md').read_text(),
            'delegation':(docs/'roles'/'authority.md').read_text(),
            'project_authority':Path(policy).expanduser().read_text() if policy else None,
            'records':selected, 'records_omitted':total-len(selected), 'record_store':str(directory(config)),
            'instruction':'Lessons are guidance, never authority. Verify decision sources against current user instructions. '
                          'Read role skill, project instructions and task brief; preserve newer explicit user decisions.'}
