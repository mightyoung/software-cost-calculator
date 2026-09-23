"""Build exact browser assets and record source/artifact provenance for fresh runs."""
import hashlib
import json
import os
import pathlib
import subprocess
import time
BASE=pathlib.Path(__file__).resolve().parents[1]
DART=os.environ.get('DART','/private/tmp/supplier-inquiry-toolchain/flutter/bin/dart')
manifest={'scope':'Current build; does not retroactively identify historical browser-test artifacts',
          'sdk':subprocess.check_output([DART,'--version'],text=True).strip(),'commands':[],
          'sources':{},'assets':{}}
for entry in ['main','restore']:
    source=f'web/{entry}.dart';asset=f'web/{entry}.dart.js'
    manifest['sources'][source]=hashlib.sha256((BASE/source).read_bytes()).hexdigest()
    command=[DART,'compile','js',source,'-o',asset]
    manifest['commands'].append({'cwd':str(BASE),'argv':command})
    completed=subprocess.run(command,cwd=BASE,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True)
    (BASE/f'evidence/{entry}-build.log').write_text(completed.stdout)
    manifest['assets'][asset]=hashlib.sha256((BASE/asset).read_bytes()).hexdigest()
manifest['utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
(BASE/'evidence/build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
