"""Local coordination for GitHub requests. Never stores tokens or response bodies."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import fcntl

from squad_runtime import atomic, read


class Deferred(ValueError):
    def __init__(self, until):
        self.retry_at = until
        super().__init__('GitHub API deferred until '+time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(until)))


def directory(config):
    # Default is deliberately conservative: one budget per host on this machine.
    # Projects sharing a credential must use the same key and state directory.
    host = os.environ.get('GH_HOST', 'github.com').lower()
    key = config.get('github_budget_key', 'default')
    base = Path(config.get('github_state_dir', '~/.local/state/squad/github')).expanduser()
    path = base / hashlib.sha256((host+'\0'+key).encode()).hexdigest()[:24]
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def status(config):
    return read(directory(config)/'budget.json', {})


@contextlib.contextmanager
def locked(config):
    path = directory(config)
    with (path/'request.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read(path/'budget.json', {})
        try:
            yield state
        finally:
            atomic(path/'budget.json', state)


def decode(output):
    body = output.replace('\r\n', '\n'); headers = {}; code = 0
    while body.startswith('HTTP/'):
        head, sep, body = body.partition('\n\n')
        if not sep: raise ValueError('Incomplete GitHub HTTP response')
        code = int(head.splitlines()[0].split()[1])
        headers.update({k.lower().strip():v.strip() for line in head.splitlines()[1:] if ':' in line for k,v in [line.split(':',1)]})
    return code, headers, body


def request(config, args, *, resource='graphql', mutation=False, stdin=None, cost_query=False, timeout=60):
    with locked(config) as state:
        now = time.time()
        bucket = state.setdefault(resource, {})
        until = max(state.get('retry_at', 0), bucket.get('retry_at', 0))
        if now < until:
            state.setdefault('waiters',{})[config.get('repository','unknown')] = until
            raise Deferred(until)
        if mutation:
            time.sleep(max(0, state.get('last_write', 0)+1-now))
        operation = os.environ.get('SQUAD_API_OPERATION', 'other')
        key = config.get('repository', 'unknown')+':'+operation+':'+resource
        counters = state.setdefault('operations', {}).setdefault(key, {'requests':0,'points':0,'limited':0,'errors':0})
        counters['requests'] += 1
        state['last_request_at'] = time.time()
        try:
            result = subprocess.run(['gh','api',*args,'--include'], input=stdin, capture_output=True, text=True, timeout=timeout)
            code, headers, body = decode(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            counters['errors'] += 1
            raise
        finally:
            if mutation: state['last_write'] = time.time()
        for name in ('remaining','limit','reset','used'):
            if 'x-ratelimit-'+name in headers:
                bucket[name] = int(headers['x-ratelimit-'+name])
        try: payload = json.loads(body) if body.strip() else None
        except ValueError:
            counters['errors'] += 1
            raise ValueError('Unreadable GitHub response')
        message = json.dumps(payload.get('errors',payload.get('message',''))) if isinstance(payload,dict) else ''
        limited = code == 429 or 'retry-after' in headers or any(x in (message+result.stderr).lower() for x in ('rate limit','rate_limit','abuse detection'))
        failed = result.returncode or code >= 400 or isinstance(payload,dict) and payload.get('errors')
        if failed and bucket.get('remaining') == 0: limited = True
        if cost_query and isinstance(payload,dict):
            cost = (payload.get('data') or {}).pop('_squadRate', None)
            if cost: counters['points'] += cost.get('cost',0)
        if limited:
            counters['limited'] += 1
            failures = bucket.get('failures',0)+1
            delay = max(min(3600,60*2**min(failures-1,6)), float(headers.get('retry-after',0)))
            if bucket.get('remaining') == 0:
                bucket['retry_at'] = max(time.time()+delay, bucket.get('reset',0)+1)
            else:
                state['retry_at'] = time.time()+delay  # Secondary limits affect both APIs.
            bucket['failures'] = failures
            until=max(state.get('retry_at',0),bucket.get('retry_at',0))
            state.setdefault('waiters',{})[config.get('repository','unknown')]=until
            raise Deferred(until)
        if failed:
            counters['errors'] += 1
            raise ValueError('GitHub request failed; no automatic mutation replay: '+message[:500])
        bucket['failures'] = 0
        if bucket.get('remaining') == 0: bucket['retry_at'] = bucket.get('reset',time.time()+60)+1
        return payload, headers, code
