"""Launch or focus the single Project Manager session; no model makes this decision."""
import argparse
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import time
import uuid

from meeting import call, locked, model_config, zellij
from squad_runtime import atomic, read, root, settings


def prompt(config, topic):
    cli='bash '+shlex.quote(str(Path(__file__).resolve().parent/'squad.sh'))
    return (f'Use the Squad project-manager skill as the main Project Manager. Requested conversation: {topic}. '
            f'Read project instructions, {cli} context project-manager, {cli} recover and {cli} next. '
            'You own planning, delivery continuity and user decisions. Use CLI checks and native specialist subagents. '
            'Reconcile existing workers before dispatch. Never infer new scope, authority or a resume from this launch. '
            'Respect the persisted user pause. Plan and discuss even while execution is paused. '
            'Handle native completions directly, obtain independent review and record owned next actions. '
            'Checkpoint before stopping; the conductor is only external recovery.')


def verified_pm(state, record, model, effort, project):
    authority=read(state/'pm-authority.json',{})
    resolved=record.get('resolved',{})
    return (authority.get('thread_id')==record.get('thread_id') and authority.get('role')=='project-manager'
            and authority.get('model')==model and authority.get('effort')==effort
            and resolved.get('model')==model and resolved.get('reasoningEffort')==effort
            and Path(resolved.get('cwd','')).resolve()==Path(project).resolve())


def reap_manual(state):
    """Finalise only a native acknowledgement for an explicit PM bootstrap.

    Called under the same lock as conductor.sh. Scheduler events remain the
    conductor's responsibility; a process exit alone is never completion.
    """
    current=read(state/'current.json',{})
    launch_id=current.get('id','')
    if not launch_id.startswith('pm-start-'): return False
    ack_path=state/'acks'/(launch_id+'.json');ack=read(ack_path,{})
    if (ack.get('id')!=launch_id or not current.get('thread_id') or not current.get('turn_id')
        or ack.get('thread_id')!=current['thread_id'] or ack.get('turn_id')!=current['turn_id']
        or ack.get('turn_status') not in ('completed','failed','interrupted')): return False
    atomic(state/'manual-results'/(launch_id+'.json'),{'launch':current,'ack':ack})
    (state/'current.json').unlink()
    ack_path.unlink()
    return True


def launch(config, harness, topic='planning', dry_run=False):
    if harness=='claude-code':
        from meeting import launch as meeting_launch
        return meeting_launch({**config, 'pm_topic':topic}, harness, 'pm', dry_run)
    model, effort=model_config(config,harness)
    project=str(Path(config.get('project_dir',os.getcwd())).resolve())
    state=Path(config.get('conductor_state',str(root(config).parent/'conductor-state')))
    session=config.get('meeting_zellij_session') or os.environ.get('ZELLIJ_SESSION_NAME')
    if not session: raise ValueError('Run squad start inside Zellij or configure meeting_zellij_session')
    scripts=Path(__file__).resolve().parent
    tab='squad-pm-'+__import__('hashlib').sha256(project.encode()).hexdigest()[:12]
    summary={'role':'project-manager','model':model,'effort':effort,'project':project,'tab':tab,'zellij_session':session}
    if dry_run: return {'action':'dry-run',**summary}
    for tool in ('codex','zellij','systemd-run'):
        if not shutil.which(tool): raise ValueError('Missing required tool: '+tool)
    client=config.get('conductor_app_server_client',str(Path.home()/'.config/squad/bin/squad-conductor-appserver'))
    url=config.get('conductor_app_server_url')
    if not url or not Path(client).is_file():
        raise ValueError('First run squad conductor install --no-enable and start its printed gateway service. This prepares the managed PM without enabling unattended recovery.')
    record_path=state/'chief-of-staff-thread.json' # Keep historical storage identity for recovery.
    with locked(state):
        reap_manual(state)
        record=read(record_path,{})
        current=read(state/'current.json',{})
        if record.get('thread_id'):
            resolved=record.get('resolved',{})
            if not verified_pm(state,record,model,effort,project):
                raise ValueError('Existing session has a different role/model/effort. Checkpoint and reconcile its workers, then use squad session rollover while idle and run squad start again. No worker was interrupted.')
        if not record.get('thread_id') and not current:
            launch_id='pm-start-'+uuid.uuid4().hex
            atomic(state/'current.json',{'id':launch_id,'events':[],'event_keys':[],
                   'claimed_at':time.time(),'phase':'controller-starting','attachable':False,
                   'unit':'squad-'+launch_id})
            # A launch error is deliberately left owned: do not blindly spawn again.
            call(['systemd-run','--user','--quiet','--collect','--unit','squad-'+launch_id,
                  client,'run','--model',model,'--effort',effort,'--url',url,'--state',str(state),
                  '--launch',launch_id,'--cwd',project,'--brief',prompt(config,topic)])
    # The controller writes identity only after the native server has accepted it.
    # Keep the shell bounded; a slow start can be inspected and attached later.
    for _ in range(100):
        record=read(record_path,{})
        if record.get('attachable'): break
        time.sleep(.1)
    if not record.get('attachable'):
        raise ValueError('PM launch is recorded but not attachable yet. Inspect squad session inspect and the controller logs; retry squad start after reconciliation. Do not launch another coordinator.')
    resolved=record.get('resolved',{})
    if not verified_pm(state,record,model,effort,project):
        raise ValueError('Native PM identity does not match configured role/model/effort; refusing to attach')
    # Serialise tab creation too, including launches from two terminals.
    with locked(state):
        presentation=read(state/'pm-tab.json',{})
        if presentation and presentation.get('session')!=session:
            previous=zellij(presentation['session'],'query-tab-names').splitlines()
            if tab in previous: return {'action':'already-open','thread_id':record['thread_id'],**summary,'zellij_session':presentation['session']}
        tabs=zellij(session,'query-tab-names').splitlines()
        if tab in tabs:
            zellij(session,'go-to-tab-name',tab)
            return {'action':'focused','thread_id':record['thread_id'],**summary}
        if presentation.get('status')=='launching':
            raise ValueError('PM tab launch is ambiguous; inspect Zellij and pm-tab.json before retrying')
        presentation={'session':session,'tab':tab,'status':'launching','config':config}
        atomic(state/'pm-tab.json',presentation)
        zellij(session,'new-tab','--name',tab,'--cwd',project,'--close-on-exit','--',
               sys.executable,str(scripts/'coordinator.py'),'_attach',str(state/'pm-tab.json'))
        atomic(state/'pm-tab.json',{**presentation,'status':'open'})
    return {'action':'launched','thread_id':record['thread_id'],**summary}


def attach(path):
    record=read(path);config=record['config']
    env={k:v for k,v in os.environ.items() if not k.startswith('SQUAD_')
         and k not in ('CODEX_THREAD_ID','CODEX_PROJECT_DIR','CLAUDE_PROJECT_DIR','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT')}
    env.update(SQUAD_PROJECT_DIR=config['project_dir'],SQUAD_SETTINGS=config['settings_file'],
               SQUAD_CONDUCTOR_STATE=config['conductor_state'],
               SQUAD_CONDUCTOR_APP_SERVER_URL=config['conductor_app_server_url'],SQUAD_PM_MAIN='1')
    script=Path(__file__).resolve().parent/'conductor-session.sh'
    return subprocess.call(['bash',str(script),'attach'],cwd=config['project_dir'],env=env)


def main():
    if len(sys.argv)>1 and sys.argv[1]=='_reap':
        state=Path(sys.argv[2])
        with locked(state):
            print(json.dumps({'reconciled':reap_manual(state)}))
        return 0
    if len(sys.argv)>1 and sys.argv[1]=='_attach':
        return attach(sys.argv[2])
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--harness',required=True,choices=('codex','claude-code'))
    parser.add_argument('topic',nargs='?',default='planning',choices=('planning','retro','delivery'))
    parser.add_argument('--dry-run',action='store_true')
    args=parser.parse_args()
    config=settings(os.environ.get('SQUAD_SETTINGS_FILE'))
    print(json.dumps(launch(config,args.harness,args.topic,args.dry_run),indent=2))

if __name__=='__main__':
    try: sys.exit(main())
    except (ValueError,OSError,KeyError) as exc:
        print('squad start: '+str(exc),file=sys.stderr);sys.exit(1)
