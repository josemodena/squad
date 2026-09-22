#!/usr/bin/env python3
"""Copy canonical runtime/reference files into self-contained plugin packages."""
import argparse
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent

def pairs():
    for harness in ('codex', 'claude-code'):
        plugin = ROOT / 'plugins' / harness / 'squad'
        for name in ('runtime.md',):
            yield ROOT / 'docs/reference' / name, plugin / 'docs' / name
        for name in ('LICENSE', 'NOTICE'):
            if (ROOT / name).exists():
                yield ROOT / name, plugin / name
    for name in ('squad_runtime.py', 'test_runtime.py'):
        yield ROOT / 'shared/runtime' / name, ROOT / 'plugins/codex/squad/scripts' / name
        yield ROOT / 'shared/runtime' / name, ROOT / 'plugins/claude-code/squad/scripts' / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    stale = []
    for source, target in pairs():
        if args.check:
            if not target.exists() or source.read_bytes() != target.read_bytes():
                stale.append(str(target.relative_to(ROOT)))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    if stale:
        print('Run python3 tools/sync-package.py; stale files:\n' + '\n'.join(stale), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
