#!/usr/bin/env python3
"""Export a clean committed snapshot without Git history or local/ignored files."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('destination', type=Path, help='new directory outside this checkout')
    args = p.parse_args()
    target = args.destination.expanduser().resolve()
    if target == ROOT or ROOT in target.parents or target.exists():
        p.error('destination must not exist and must be outside this checkout')
    if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT):
        p.error('commit the reviewed snapshot first; the working tree must be clean')
    for script in ['check-repo.py', 'sync-package.py']:
        subprocess.run([sys.executable,str(ROOT/'tools'/script),*(['--check'] if script.startswith('sync') else [])],cwd=ROOT,check=True)
    data = subprocess.check_output(['git','archive','--format=tar','HEAD'],cwd=ROOT)
    target.mkdir(parents=True)
    subprocess.run(['tar','-xf','-','-C',str(target)],input=data,check=True)
    if (target/'.git').exists():
        raise RuntimeError('unexpected Git metadata in archive')
    print('Exported clean source snapshot to '+str(target))
    print('No commits, remotes, issues, pull requests or local runtime data were copied.')
    print('Review it before creating a new repository; this command does not publish.')

if __name__ == '__main__':
    main()
