#!/usr/bin/env python3
"""Launch direct Project Manager conversations in project-scoped Zellij tabs."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import time
import uuid

from squad_runtime import atomic, event, read, root, settings, transaction

KINDS = ('planning', 'retro')


def call(argv):
    p = subprocess.run(argv, text=True, capture_output=True)
    if p.returncode:
        raise ValueError(p.stderr.strip() or p.stdout.strip() or 'Command failed: '+argv[0])
    return p.stdout.strip()


def namespace(config, harness):
    project = str(Path(config['project_dir']).expanduser().resolve())
    key = hashlib.sha256((project+'\0'+harness).encode()).hexdigest()[:12]
    return root(config)/'meetings'/key


@contextlib.contextmanager
def locked(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    with (directory/'lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def zellij(session, *args):
    return call(['zellij', '--session', session, 'action', *args])


def model_config(config, harness):
    model = config.get('project_manager_model')
    if not model or model.startswith('-') or any(c.isspace() for c in model):
        raise ValueError('Set project_manager_model to an explicit model identifier')
    effort = config.get('project_manager_effort', 'high')
    allowed = ('low','medium','high','xhigh','max') if harness == 'claude-code' else ('low','medium','high','xhigh','max','ultra')
    if effort not in allowed:
        raise ValueError('Unsupported project_manager_effort: '+effort)
    return model, effort


def harness_argv(record):
    prompt = record['prompt']
    if record['harness'] == 'codex':
        args = ['codex']
        if record.get('session_id'):
            args += ['resume', record['session_id']]
        return args + ['-C', record['project'], '-m', record['model'], '-c',
                       'model_reasoning_effort='+json.dumps(record['effort']), prompt]
    args = ['claude', '--model', record['model'], '--effort', record['effort']]
    if record.get('session_id'):
        args += ['--resume', record['session_id']]
    return args + [prompt]


def prompt_for(record, scripts):
    skill = 'plan' if record['kind'] == 'planning' else 'retro'
    plugin = scripts.parent
    helper = shlex.quote(str(scripts/'meeting.sh'))
    return f'''You are the Squad Project Manager in a direct, interactive {record['kind']} meeting with the user.
This is a main session, not an Administrator or a delegated worker. Do not launch another meeting.
Read AGENTS.md/CLAUDE.md if present, {record['settings_file']},
{plugin}/skills/project-manager/SKILL.md and {plugin}/skills/{skill}/SKILL.md.
Use scripts from {scripts}. Read current project records and previous decisions; do not invent board state if unavailable.
Meeting record: {record['record_path']}. Read its checkpoint/report references before asking the user to repeat anything.
Configured model: {record['model']}; effort: {record['effort']}. Do not silently switch models.
Have the conversation directly with the user. Proposals are not agreed scope.
Keep durable notes with: bash {helper} checkpoint {record['kind']} --file /absolute/path/to/notes.md
If the harness exposes your exact session UUID, add --session-id UUID to enable exact transcript resume.
When the user concludes the meeting, save the agreed decisions and outstanding questions in project records,
then run: bash {helper} complete {record['kind']} --file /absolute/path/to/outcome.md
The completion command records a durable Administrator event. Do not claim a worker job or resume paused execution.
Already agreed execution can continue independently; do not edit implementation files or stop workers for this meeting.
'''


def launch(config, harness, kind, dry_run=False):
    model, effort = model_config(config, harness)
    directory = namespace(config, harness)
    path = directory/(kind+'.json')
    project = str(Path(config['project_dir']).expanduser().resolve())
    session = config.get('meeting_zellij_session') or os.environ.get('ZELLIJ_SESSION_NAME')
    if not session:
        raise ValueError('Run inside Zellij or set meeting_zellij_session in project settings')
    label = re.sub(r'[^A-Za-z0-9_-]', '-', Path(project).name)[:35]
    scripts = Path(__file__).resolve().parent
    tab = f'squad-{label}-{directory.name}-{kind}'
    record = {'id':str(uuid.uuid4()), 'kind':kind, 'harness':harness, 'project':project,
              'settings_file':str(Path(config['settings_file']).resolve()), 'model':model, 'effort':effort,
              'zellij_session':session, 'tab':tab, 'record_path':str(path), 'status':'prepared',
              'config':config, 'created_at':time.time()}
    record['prompt'] = prompt_for(record, scripts)
    if dry_run:
        return {'tab':tab, 'zellij_session':session, 'project':project, 'model':model,
                'effort':effort, 'command':harness_argv(record), 'record_path':str(path)}
    for exe in ('zellij', 'codex' if harness == 'codex' else 'claude'):
        if not shutil.which(exe):
            raise ValueError('Required executable missing: '+exe)
    # Feature check before writing a pending launch record (older Zellij needs upgrading).
    if 'INITIAL_COMMAND' not in call(['zellij','action','new-tab','--help']):
        raise ValueError('Upgrade Zellij: new-tab must support an initial command after --')
    with locked(directory):
        old = read(path)
        if old and old['status'] != 'completed':
            tabs = zellij(old['zellij_session'], 'query-tab-names').splitlines()
            if old['tab'] in tabs and old['status'] in ('launching','running'):
                zellij(old['zellij_session'], 'go-to-tab-name', old['tab'])
                return {**{k:old[k] for k in ('id','tab','model','effort')}, 'action':'focused'}
            if old['status'] in ('launching','running'):
                raise ValueError('Meeting launch/session is unresolved; inspect it, then use meeting reconcile '+kind+' --reason TEXT before relaunching')
            record.update({k:old[k] for k in ('id','checkpoint','session_id') if k in old})
            if old['tab'] in tabs:
                record['tab'] += '-'+uuid.uuid4().hex[:8]
        # Completed tabs are kept for reading. A new meeting gets a distinct name.
        if old and old['status'] == 'completed':
            atomic(directory/(old['id']+'-completed.json'),old)
            record['tab'] += '-'+record['id'][:8]
        record['status'] = 'launching'
        atomic(path, record)
        # Zellij may have created the tab even if its response is lost. Keep launch ambiguous.
        output = zellij(session, 'new-tab', '--name', record['tab'], '--cwd', project,
                        '--', sys.executable, str(scripts/'meeting.py'), '_run', str(path))
        return {'action':'launched','tab':record['tab'],'model':model,'effort':effort,'record_path':str(path),'zellij_result':output}


def run_meeting(path):
    path = Path(path).resolve()
    with locked(path.parent):
        record = read(path)
        if record['status'] != 'launching':
            raise ValueError('Meeting is not awaiting launch')
        record['status']='running'; record['pid']=os.getpid()
        atomic(path,record)
    env = os.environ.copy()
    # A Zellij server can retain another project's environment. Pin this meeting.
    for key in list(env):
        if key.startswith('SQUAD_') or key in ('CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_PROJECT_DIR','CODEX_THREAD_ID','CODEX_PROJECT_DIR'):
            env.pop(key,None)
    env.update({'SQUAD_SETTINGS':record['settings_file'], 'SQUAD_PROJECT_DIR':record['project'],
                'SQUAD_MEETING_ID':record['id'], 'SQUAD_MEETING_RECORD':str(path),
                'SQUAD_HARNESS':record['harness'],
                'SQUAD_RUNTIME_DIR':str(root(record['config']))})
    try:
        code = subprocess.call(harness_argv(record), cwd=record['project'], env=env)
    except OSError as exc:
        print(str(exc),file=sys.stderr); code=127
    with locked(path.parent):
        current=read(path)
        if current['id']==record['id'] and current['status']!='completed':
            current.update(status='interrupted', exit_code=code)
            atomic(path,current)
    return code


def update(config,harness,kind,action,file=None,session_id=None,reason=None):
    directory=namespace(config,harness); path=directory/(kind+'.json')
    with locked(directory):
        record=read(path)
        if not record: raise ValueError('No meeting record for '+kind)
        identity=os.environ.get('SQUAD_MEETING_ID')
        if identity and identity!=record['id']: raise ValueError('This is an older meeting; refusing to update its replacement')
        if action=='status': return record
        if action=='reconcile':
            if record['tab'] in zellij(record['zellij_session'],'query-tab-names').splitlines():
                raise ValueError('Meeting tab still exists; return to it instead')
            record.update(status='interrupted', reconciliation=reason)
        else:
            if record['status']=='completed': return record
            if session_id: uuid.UUID(session_id)
            body=Path(file).expanduser().read_text()
            if not body.strip(): raise ValueError('Meeting notes cannot be empty')
            # Copy notes into private durable storage; do not rely on a temp file surviving.
            note=directory/(record['id']+'-'+action+'-'+str(time.time_ns())+'.json')
            atomic(note, {'text':body,'source':str(Path(file).resolve())})
            record['checkpoint' if action=='checkpoint' else 'report']=str(note)
            if session_id:
                uuid.UUID(session_id)
                record['session_id']=session_id
            if action=='complete':
                if record['status']=='completed': return record
                # Durable, idempotent event before completion marker: a crash can safely retry.
                with transaction(record['config']) as state:
                    external_id='meeting:'+record['id']
                    if not any(e.get('external_id')==external_id for e in state['events']):
                        event(state,'external',external_id=external_id,
                              reason=f"{kind} meeting concluded; read {note}")
                record['status']='completed'
        atomic(path,record)
        return record


def session_hook():
    """Bind only the ID supplied by this meeting's own native SessionStart event."""
    path=Path(os.environ['SQUAD_MEETING_RECORD']).resolve()
    try: payload=json.load(sys.stdin)
    except (ValueError, OSError): payload={}
    sid=payload.get('session_id')
    with locked(path.parent):
        record=read(path)
        if record['id']!=os.environ.get('SQUAD_MEETING_ID'):
            raise ValueError('Session hook belongs to an older meeting')
        if sid:
            uuid.UUID(sid)
            record['session_id']=sid
            atomic(path,record)
    print('Squad: direct Project Manager meeting. Keep the meeting tab name. '
          'Read the meeting record and checkpoints; do not coordinate workers or launch another meeting.')


def main():
    if len(sys.argv)>1 and sys.argv[1]=='_hook':
        session_hook(); return 0
    if len(sys.argv)>1 and sys.argv[1]=='_run':
        return run_meeting(sys.argv[2])
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--harness',choices=('codex','claude-code'),required=True)
    sub=p.add_subparsers(dest='action',required=True)
    for action in ('start','status','checkpoint','complete','reconcile'):
        s=sub.add_parser(action);s.add_argument('kind',choices=KINDS)
        if action=='start': s.add_argument('--dry-run',action='store_true')
        if action in ('checkpoint','complete'): s.add_argument('--file',required=True)
        if action=='checkpoint': s.add_argument('--session-id')
        if action=='reconcile': s.add_argument('--reason',required=True)
    a=p.parse_args()
    config=settings(os.environ.get('SQUAD_SETTINGS_FILE'))
    if a.action=='start': result=launch(config,a.harness,a.kind,a.dry_run)
    else: result=update(config,a.harness,a.kind,a.action,getattr(a,'file',None),getattr(a,'session_id',None),getattr(a,'reason',None))
    print(json.dumps(result,indent=2))
    return 0


if __name__=='__main__':
    try: sys.exit(main())
    except (ValueError,OSError,KeyError) as exc:
        print('squad meeting: '+str(exc),file=sys.stderr);sys.exit(1)
