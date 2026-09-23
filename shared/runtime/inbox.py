"""Observe replies to owned user requests without interpreting them as authority."""
import datetime as dt
import hashlib
import json
import subprocess
import time
import urllib.parse

from squad_runtime import atomic, event, read, root, transaction


def stamp(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def epoch(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def watches(state):
    result = dict(state.get('reply_watches', {}))
    captured = state.get('readiness', {}).get('captured_at')
    for item in state.get('readiness', {}).get('items', []):
        for blocker in item.get('blockers', []):
            if blocker.get('requires_user') and blocker.get('reason') != 'user-paused':
                number = str(item['number'])
                since = blocker.get('created_at') or captured
                if since:
                    old = result.get(number, {})
                    result[number] = {'since': min(old.get('since', since), since)}
    return result


class Limited(ValueError):
    def __init__(self, delay):
        self.delay = delay
        super().__init__('GitHub rate limit; reply observation deferred')


def comments(config, since):
    rows = []
    for page in range(1, 11):
        query = urllib.parse.urlencode({'since': stamp(since), 'sort': 'updated',
                                      'direction': 'asc', 'per_page': 100, 'page': page})
        endpoint = 'repos/'+config['repository']+'/issues/comments?'+query
        import github_io, tracker_cache
        from squad_runtime import read
        cache=tracker_cache.directory(config)/'comments.json'
        saved=read(cache,{}) if page==1 else {}
        args=[endpoint]
        if saved.get('endpoint')==endpoint and saved.get('etag'):
            args+=['-H','If-None-Match: '+saved['etag']]
        try:
            data,headers,code=github_io.request(config,args,resource='core',timeout=30)
        except github_io.Deferred as exc:
            raise Limited(max(0,exc.retry_at-time.time())) from exc
        if code==304:
            if saved.get('endpoint')!=endpoint or not isinstance(saved.get('rows'),list):
                raise ValueError('Unusable conditional comments response')
            return saved['rows']
        if page==1 and 'rel="next"' not in headers.get('link','') and isinstance(data,list) and len(data)<100:
            atomic(cache,{'endpoint':endpoint,'etag':headers.get('etag'),'rows':data})
        if not isinstance(data, list): raise ValueError('Expected a GitHub comments list')
        rows.extend(data)
        if 'rel="next"' not in headers.get('link', '') and len(data) < 100:
            return rows
    raise ValueError('Reply pagination exceeded ten pages; cursor retained, narrow the watch interval')


def poll(config, force=False):
    # Reuse the runtime lock so two harnesses cannot emit the same reply twice.
    # No model call and no board mutation; failures retain the cursor for recovery.
    with transaction(config) as state:
        now = time.time()
        observer = state.setdefault('reply_observer', {})
        pending = watches(state)
        if str(config.get('github_reply_observer', 'true')).lower() == 'false':
            return {'status': 'disabled'}
        if not pending: return {'status': 'no-watches'}
        if now < observer.get('retry_at', 0): return {'status': 'backoff', 'retry_at': observer['retry_at']}
        interval = max(60, int(config.get('github_reply_interval', 300)))
        if not force and now < observer.get('next_poll', 0): return {'status': 'not-due'}
        known = observer.get('watches', {})
        new = [v['since'] for k,v in pending.items() if k not in known or v['since'] < known[k]['since']]
        since = min([observer.get('cursor', min(v['since'] for v in pending.values()))]+new)-1
        try:
            rows = comments(config, since)
            # Validate the whole batch before recording anything.
            for c in rows:
                int(c['id']); epoch(c['updated_at']); epoch(c['created_at'])
                int(c['issue_url'].rsplit('/', 1)[1]); c['user']['login']; c['body']; c['html_url']
        except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as exc:
            failures = observer.get('failures', 0)+1
            delay = max(min(3600, 60*2**min(failures-1, 6)), getattr(exc, 'delay', 0))
            observer.update(failures=failures, retry_at=now+delay, error=str(exc)[:500])
            return {'status': 'error', 'error': observer['error'], 'retry_at': observer['retry_at']}
        seen = observer.setdefault('seen', {})
        added = []
        for c in rows:
            number = str(int(c['issue_url'].rsplit('/', 1)[1]))
            if number not in pending or epoch(c['updated_at']) < pending[number]['since']: continue
            identity = str(c['id'])+':'+c['updated_at']+':'+hashlib.sha256(c['body'].encode()).hexdigest()
            if identity in seen: continue
            seen[identity] = now
            event(state, 'external', external_id='github-reply:'+identity,
                  reason='New GitHub reply on #'+number+'; Project Manager must verify author, request and authority.',
                  issue=int(number), owner='project-manager', source='github-comment',
                  url=c['html_url'], author=c['user']['login'], body=c['body'],
                  comment_id=c['id'], updated_at=c['updated_at'], approval=False)
            state.setdefault('pm_reply_pending', {})[number] = {'url':c['html_url'],'event_id':'github-reply:'+identity,'author':c['user']['login'],'updated_at':c['updated_at']}
            added.append(c['html_url'])
        cursor=max([since+1]+[epoch(c['updated_at']) for c in rows])
        observer.update(cursor=cursor, watches=pending, next_poll=now+interval,
                        failures=0, retry_at=0, error=None)
        return {'status': 'checked', 'replies': added}
