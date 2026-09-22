"""Run both real init entry points against a stateful GitHub transport fixture."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'shared/runtime'))
from test_board_backup import fixture,conn


class Migration(unittest.TestCase):
    def test_both_init_commands_preserve_existing_status_values_and_views(self):
        for harness,folder in [('codex','.codex'),('claude-code','.claude')]:
            with self.subTest(harness=harness),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);project=root/'project';(project/folder).mkdir(parents=True)
                config=project/folder/'squad.local.md'
                config.write_text('---\nrepository: example/demo\nproject_owner: example\nproject_number: 1\nscratch_root: '+str(root/'state')+'\n---\n')
                state=fixture()
                for name in ['Track','Owner','Estimate (credits %)','Sprint','Needed by','Responsible role','Stage','Agreement','Design','Priority','Forecast finish','Estimate (hours)','Iteration']:
                    state['fields'].append({'__typename':'ProjectV2Field','id':'F'+str(len(state['fields'])),'name':name,'dataType':'TEXT'})
                path=root/'github.json';path.write_text(json.dumps(state))
                fake=root/'bin';fake.mkdir()
                gh=fake/'gh';gh.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
sys.path.insert(0,os.environ['FIXTURE_RUNTIME'])
from test_board_backup import FakeAPI,conn
p=Path(os.environ['FIXTURE_STATE'])
if sys.argv[1:3]!=['api','graphql']:
    sys.exit(0)
x=json.load(sys.stdin);q=x['query'];api=FakeAPI(json.loads(p.read_text()))
data=api.query(q,x.get('variables'))
if 'projectV2(number' in q and 'fields(first:' in q:
    data['user']['projectV2']['fields']=conn(api.state['fields'])
p.write_text(json.dumps(api.state))
print('HTTP/2.0 200 OK\\nx-ratelimit-remaining: 1000\\n\\n'+json.dumps({'data':data}))
''');gh.chmod(0o755)
                env={k:v for k,v in os.environ.items() if not k.startswith(('SQUAD_','GIT_'))}
                env.update(PATH=str(fake)+os.pathsep+env['PATH'],SQUAD_SETTINGS=str(config),FIXTURE_STATE=str(path),FIXTURE_RUNTIME=str(ROOT/'shared/runtime'),PYTHONDONTWRITEBYTECODE='1')
                cmd=['bash',str(ROOT/'plugins'/harness/'squad/scripts/init.sh'),'apply','--no-templates','--no-entry-point']
                for _ in range(2):
                    result=subprocess.run(cmd,cwd=project,env=env,text=True,capture_output=True)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    after=json.loads(path.read_text())
                    self.assertEqual(after['items'],state['items'])
                    self.assertEqual(after['views'],state['views'])
                    self.assertEqual(after['fields'][0]['options'][:2],state['fields'][0]['options'])
                history=list((root/'state/board-backups').rglob('*-before-*.json'))
                self.assertTrue(history)


if __name__=='__main__':unittest.main()
