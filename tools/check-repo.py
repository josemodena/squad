#!/usr/bin/env python3
"""Validate distributable structure, local doc links and privacy regressions."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
errors = []

def check(ok, message):
    if not ok:
        errors.append(message)

version = (ROOT/'VERSION').read_text().strip()
marketplaces = [('.agents/plugins/marketplace.json','codex','.codex-plugin/plugin.json'),
                ('.claude-plugin/marketplace.json','claude-code','.claude-plugin/plugin.json')]
for marketplace, harness, manifest in marketplaces:
    data = json.loads((ROOT/marketplace).read_text())
    entry = next(p for p in data['plugins'] if p['name'] == 'squad')
    source = entry['source']['path'] if isinstance(entry['source'], dict) else entry['source']
    expected = 'plugins/'+harness+'/squad'
    check(source.removeprefix('./') == expected, marketplace+': wrong source')
    plugin = ROOT/expected
    metadata = json.loads((plugin/manifest).read_text())
    check(metadata['name'] == plugin.name == 'squad', str(plugin)+': name mismatch')
    check(metadata['version'].split('+')[0] == version, str(plugin)+': version mismatch')
    check(metadata['license'] == ('Apache-2.0' if (ROOT/'LICENSE').exists() else 'UNLICENSED'), str(plugin)+': license mismatch')
    if harness == 'codex':
        check(json.loads((plugin/'plugin.json').read_text())['version'] == metadata['version'], 'Codex manifest versions differ')
    else:
        check(data['version'] == entry['version'] == metadata['version'], 'Claude marketplace versions differ')
    hooks = json.loads((plugin/'hooks/hooks.json').read_text())['hooks']
    for groups in hooks.values():
        for group in groups:
            for hook in group['hooks']:
                path = re.search(r'\$\{(?:CLAUDE_)?PLUGIN_ROOT\}/([^\s]+)', hook['command'])
                check(bool(path and (plugin/path[1]).is_file()), str(plugin)+': missing hook target')

names = subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=ROOT).decode().split('\0')
files = [ROOT/n for n in sorted(set(names)) if n and (ROOT/n).is_file()]
# Deliberately generic: never bake a private project/person name into a public test.
patterns = {
    'machine-specific home path': re.compile(r'/(?:home|Users)/[A-Za-z0-9_.-]+/'),
    'credential-shaped token': re.compile(r'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{40,}'),
    'private key': re.compile('-----BEGIN ' + r'(?:RSA |OPENSSH |EC )?PRIVATE KEY-----'),
}
for path in files:
    check(not path.is_symlink(), str(path.relative_to(ROOT))+': packaged symlink requires review')
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        errors.append(str(path.relative_to(ROOT))+': unexpected binary file')
        continue
    for label, pattern in patterns.items():
        if pattern.search(text):
            errors.append(str(path.relative_to(ROOT))+': '+label)
    if path.suffix != '.md':
        continue
    # Strip fenced code and inline code before examining literal Markdown links.
    prose = re.sub(r'```.*?```', '', text, flags=re.S)
    prose = re.sub(r'`[^`\n]+`', '', prose)
    for link in re.findall(r'(?<!!)\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)',prose):
        if re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:',link) or link.startswith('#'):
            continue
        target = link.split('#',1)[0]
        if target:
            check((path.parent/target).exists(), str(path.relative_to(ROOT))+': broken link '+link)

for required in ['README.md','CONTRIBUTING.md','CODE_OF_CONDUCT.md','SECURITY.md','SUPPORT.md','CHANGELOG.md','docs/README.md']:
    check((ROOT/required).exists(), 'missing '+required)
if errors:
    print('\n'.join(errors),file=sys.stderr)
    sys.exit(1)
print('Repository checks passed: packages, versions, local links and privacy/credential patterns.')
print('Pattern checks are not a guarantee of secret absence; publication also requires human review.')
