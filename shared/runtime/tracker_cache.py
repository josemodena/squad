"""Short-lived, project-scoped read cache; never a substitute for a backup."""
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import time
from squad_runtime import atomic, read, root


def directory(config):
    identity = [os.environ.get('GH_HOST','github.com').lower(), config.get('github_budget_key','default'),
                config.get('repository'), config.get('project_owner'), str(config.get('project_number'))]
    import json
    key = hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:24]
    path = root(config)/'tracker-cache'/key
    path.mkdir(parents=True,exist_ok=True,mode=0o700)
    path.chmod(0o700)
    return path


@contextlib.contextmanager
def lock(config):
    path = directory(config)
    with (path/'lock').open('a') as f:
        fcntl.flock(f,fcntl.LOCK_EX)
        yield path


def invalidate(config):
    with lock(config) as path:
        (path/'board.json').unlink(missing_ok=True)


def get(config, fetch, fresh=False):
    with lock(config) as path:
        saved = read(path/'board.json', {})
        age = time.time()-saved.get('captured_at',0)
        ttl = max(0,min(300,int(config.get('github_cache_seconds',60))))
        if not fresh and saved.get('schema') == 1 and 0 <= age < ttl:
            return saved['items'], {'source':'cache','captured_at':saved['captured_at'],'age_seconds':round(age,2)}
        items = fetch()
        now = time.time()
        atomic(path/'board.json', {'schema':1,'captured_at':now,'items':items})
        return items, {'source':'github','captured_at':now,'age_seconds':0}
