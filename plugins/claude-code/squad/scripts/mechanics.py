#!/usr/bin/env python3
"""Merge, report and in-flight mechanics, so the coordinator spends one turn
where it spent four to six: read a verdict line, not a report; merge after a
passed review with one call; keep the in-flight line the hand-over reads."""
import re

from squad_runtime import board, gh, pages

IN_FLIGHT = '<!-- in-flight -->'
VERDICT = re.compile(r'^\W*verdict:\W*(do not merge|merge after named fixes|merge)\b', re.I | re.M)
SHA = re.compile(r'\b[0-9a-f]{40}\b')
# A report's verdict line: its first bold line naming the pull request, a
# barrier or a verdict, for example "**PR #398** (Closes #391). Not merged."
REPORT = re.compile(r'^[#\s]*\*\*(?:PRs?\b|Barrier|Verdict)[^\n]*', re.I | re.M)
COST = re.compile(r'^\W*cost:[^\n]*', re.I | re.M)
CLOSES = re.compile(r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)', re.I)
PR_NAMED = re.compile(r'\bPR\s*#(\d+)', re.I)


def repo(config):
    return 'repos/' + config['repository']


def comments(config, number):
    return [c.get('body') or '' for c in pages(repo(config)+'/issues/'+str(number)+'/comments?per_page=100')]


def last_review(bodies):
    for index in range(len(bodies)-1, -1, -1):
        match = VERDICT.search(bodies[index])
        if match:
            sha = SHA.search(bodies[index])
            return {'verdict': match.group(1).lower(), 'reviewed': sha.group(0) if sha else None, 'index': index}
    return None


def head_of(config, pr):
    return gh('api', repo(config)+'/pulls/'+str(pr))['head']['sha']


def verdict(config, number):
    """The last report's verdict line and its sha: on a pull request the
    Reviewer's verdict and reviewed head, on an issue the Implementer's
    report line and the head of the pull request it names."""
    bodies = comments(config, number)
    if 'pull_request' in gh('api', repo(config)+'/issues/'+str(number)):
        review = last_review(bodies)
        if not review:
            return {'number': number, 'text': 'no verdict yet (head '+head_of(config, number)+')'}
        head = head_of(config, number)
        where = ('head '+head if head == review['reviewed']
                 else 'reviewed '+str(review['reviewed'])+', head now '+head)
        return {'number': number, 'verdict': review['verdict'], 'sha': review['reviewed'], 'head': head,
                'text': review['verdict']+' ('+where+')'}
    for body in reversed(bodies):
        match = REPORT.search(body)
        if match:
            line = match.group(0).replace('*', '').lstrip('# ').strip()
            named = PR_NAMED.search(line)
            sha = head_of(config, named.group(1)) if named else (SHA.search(body) or [None])[0]
            return {'number': number, 'line': line, 'sha': sha, 'text': line+' (head '+str(sha)+')'}
    return {'number': number, 'text': 'no report yet'}


def merge_check(config, pr, apply=False):
    """Refuse unless the Reviewer passed this head, or passed an earlier head
    and a later comment names the current head with its commits following the
    reviewed one. With apply, add the review:passed label and the marker
    gitw.sh finish reads, when either is missing."""
    p = gh('api', repo(config)+'/pulls/'+str(pr))
    if p.get('state') != 'open': raise ValueError('PR #%s is not open; nothing was merged' % pr)
    head = p['head']['sha']
    bodies = comments(config, pr)
    review = last_review(bodies)
    if not review: raise ValueError('PR #%s has no Reviewer verdict comment; nothing was merged' % pr)
    if review['verdict'] == 'do not merge': raise ValueError('PR #%s: the Reviewer said do not merge' % pr)
    if not review['reviewed']: raise ValueError('PR #%s: the verdict names no reviewed head' % pr)
    fix_commits = 0
    if head != review['reviewed']:
        if not any(head in body for body in bodies[review['index']+1:]):
            raise ValueError('PR #%s moved since the review at %s and no later comment names the head %s'
                             % (pr, review['reviewed'][:7], head[:7]))
        compare = gh('api', repo(config)+'/compare/'+review['reviewed']+'...'+head)
        if compare.get('status') != 'ahead':
            raise ValueError('PR #%s: the fix commits do not follow the reviewed head %s' % (pr, review['reviewed'][:7]))
        fix_commits = compare.get('ahead_by', 0)
    elif review['verdict'] == 'merge after named fixes':
        raise ValueError('PR #%s: the named fixes are not made yet; the head is still the reviewed one' % pr)
    marker = '<!-- squad-review-passed:'+head+' -->'
    needs_marker = not any(marker in body for body in bodies)
    needs_label = 'review:passed' not in [label['name'] for label in p.get('labels', [])]
    if apply and needs_label:
        gh('api', repo(config)+'/issues/'+str(pr)+'/labels', '-X', 'POST', '-f', 'labels[]=review:passed')
    if apply and needs_marker:
        note = ('%d fix commit(s) after the review at %s, named by a later comment, checked by squad.sh merge.'
                % (fix_commits, review['reviewed'][:7]) if fix_commits else 'Recorded by squad.sh merge from the verdict.')
        gh('api', repo(config)+'/issues/'+str(pr)+'/comments', '-X', 'POST', '-f', 'body='+marker+'\n'+note)
    return {'pr': pr, 'head': head, 'reviewed': review['reviewed'], 'verdict': review['verdict'],
            'fix_commits': fix_commits, 'needs_marker': needs_marker, 'needs_label': needs_label,
            'closes': sorted({int(n) for n in CLOSES.findall(p.get('body') or '')})}


def cost_line(config, issues):
    """The cost line of the newest report on these issues."""
    for number in issues:
        for body in reversed(comments(config, number)):
            if REPORT.search(body) and COST.search(body):
                return COST.search(body).group(0).strip()
    return None


def in_flight(config, issue, text):
    """Set or clear (text None) the one in-flight line of an issue's body."""
    data = gh('api', repo(config)+'/issues/'+str(issue))
    old = data.get('body') or ''
    lines = [line for line in old.replace('\r\n', '\n').split('\n') if not line.startswith(IN_FLIGHT)]
    while lines and not lines[-1].strip(): lines.pop()
    if text: lines += ['', IN_FLIGHT+' '+text]
    body = '\n'.join(lines)
    if body != old:
        gh('api', repo(config)+'/issues/'+str(issue), '-X', 'PATCH', '-f', 'body='+body)
    return {'issue': issue, 'in_flight': text}


def in_flight_list(config):
    """The in-flight lines on open cards, as hand-over lines."""
    status = config.get('status_field', 'Status')
    found = []
    for item in board(config):
        if item.get('archived') or (item.get('fields') or {}).get(status) == 'Done': continue
        for line in (item.get('body') or '').split('\n'):
            if line.startswith(IN_FLIGHT):
                found.append('- #%s %s: %s' % (item['number'], item['title'], line[len(IN_FLIGHT):].strip()))
    return found
