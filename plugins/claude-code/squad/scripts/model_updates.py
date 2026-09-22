"""Read-only model upgrade reporting. Never select or launch a replacement model."""
import json
import subprocess
import time


def catalogue():
    try:
        result = subprocess.run(['codex', 'debug', 'models'], text=True,
                                capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError('Could not read Codex model catalogue; no settings changed') from exc
    if result.returncode:
        raise ValueError('Codex model catalogue failed; check Codex installation and login')
    try:
        data = json.loads(result.stdout)
        models = data['models']
        if not isinstance(models, list) or not models:
            raise ValueError('empty model list')
        index = {}
        for model in models:
            slug = model['slug']
            if not isinstance(slug, str) or not slug or slug in index:
                raise ValueError('invalid or duplicate model identifier')
            upgrade = model.get('upgrade')
            if upgrade is not None and (not isinstance(upgrade, dict) or
                    not isinstance(upgrade.get('model'), str) or not upgrade['model']):
                raise ValueError('invalid upgrade metadata')
            index[slug] = model
        return index
    except (ValueError, KeyError, TypeError) as exc:
        raise ValueError('Invalid Codex model catalogue; no settings changed') from exc


def check_upgrades(config, assignments, state):
    harness = config.get('harness_name', '').lower()
    report = {'checked_at': time.time(), 'automatic_changes': False,
              'roles': {}, 'active_jobs': [
                  {'id': j['id'], 'model': j.get('model'), 'actual_model': j.get('actual_model')}
                  for j in state.get('jobs', {}).values()
                  if j.get('status') in ('claimed', 'running', 'interrupted')],
              'next_action': 'Reconcile workers and checkpoint work before changing settings. '
                             'Keep each existing job on its recorded model. '
                             'Roll over a managed Administrator only when idle.'}
    if harness != 'codex':
        report.update(status='unsupported', source=None,
                      reason='Automatic upgrade discovery is available only for Codex. '
                             'Claude aliases depend on provider, CLI version and overrides; '
                             'verify the resolved model in the native session.')
        report['roles'] = {role: {'configured_model': model, 'status': 'not-checked'}
                           for role, model in assignments.items()}
        return report
    models = catalogue()
    report.update(status='checked', source='codex debug models',
                  note='Catalogue presence is not a successful model-access test. '
                       'Codex may serve a cached catalogue; check time is not catalogue freshness. '
                       'Upgrade suggestions are not moving aliases or automatic approvals.')
    for role, slug in assignments.items():
        entry = {'configured_model': slug}
        if slug not in models:
            entry['status'] = 'not-in-catalogue'
        else:
            upgrade = models[slug].get('upgrade')
            if upgrade and upgrade['model'] != slug:
                target = upgrade['model']
                entry.update(status='upgrade-suggested', suggested_model=target,
                             target_in_catalogue=target in models)
                if upgrade.get('retirement_at'):
                    entry['retirement_at'] = upgrade['retirement_at']
            else:
                entry['status'] = 'no-upgrade-advertised'
        report['roles'][role] = entry
    return report
