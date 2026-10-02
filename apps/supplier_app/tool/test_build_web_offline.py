"""Packaging invariants; run with python3 -m unittest discover -s tool -p test_build_web_offline.py."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_web_offline import APP, REQUIRED_ASSETS, package


class OfflinePackagingTest(unittest.TestCase):
    def fixture(self, root):
        for name in REQUIRED_ASSETS:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture bytes')
        (root/'assets/FontManifest.json').write_text('[]')
        (root/'index.html').write_text('<body>\n  <script src="supplier_platform.js"></script>\n</body>')
        (root/'flutter_bootstrap.js').write_text('var _flutter={};\n_flutter.loader.load({});')

    def snapshot(self, root):
        return {p.relative_to(root).as_posix(): p.read_bytes()
                for p in root.rglob('*') if p.is_file()}

    def test_each_required_asset_must_exist_and_be_nonempty_before_writing(self):
        for name in REQUIRED_ASSETS:
            for missing in (True, False):
                with self.subTest(asset=name, missing=missing), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self.fixture(root)
                    if missing:
                        (root/name).unlink()
                    else:
                        (root/name).write_bytes(b'')
                    before = self.snapshot(root)
                    with self.assertRaisesRegex(ValueError, 'Required runtime asset'):
                        package(root)
                    self.assertEqual(before, self.snapshot(root))

    def test_missing_manifest_font_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            (root/'assets/FontManifest.json').write_text(json.dumps([
                {'family': 'MaterialIcons', 'fonts': [{'asset': 'fonts/missing.otf'}]},
            ]))
            before = self.snapshot(root)
            with self.assertRaisesRegex(ValueError, 'Required font asset'):
                package(root)
            self.assertEqual(before, self.snapshot(root))

    def test_manifest_matches_emitted_assets_and_repeat_is_stable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            self.fixture(root)
            (root/'drift_worker.js').write_text('/* fixture worker */')
            first=package(root)
            manifest=json.loads((root/'supplier_offline_manifest.json').read_text())
            self.assertEqual(first,manifest['release'])
            for name,expected in manifest['assets'].items():
                self.assertEqual(expected,hashlib.sha256((root/name).read_bytes()).hexdigest(),name)
            self.assertNotIn('supplier_platform.js',(root/'index.html').read_text())
            self.assertNotIn('__SUPPLIER_RELEASE__', (root/'flutter_bootstrap.js').read_text())
            self.assertIn('fonts/OFL.txt',manifest['assets'])
            self.assertEqual(first,package(root))
            (root/'drift_worker.js').write_text('/* changed worker */')
            self.assertNotEqual(first,package(root))

    def test_unknown_bootstrap_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            self.fixture(root)
            (root/'flutter_bootstrap.js').write_text('unrecognized')
            with self.assertRaisesRegex(ValueError,'Unrecognized Flutter bootstrap'):
                package(root)

    def test_worker_rejects_unlisted_critical_assets_without_network(self):
        # Execute the real worker fetch listener with a deliberately incomplete
        # manifest. This verifies the response behavior, not source spelling.
        script = r'''
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const handlers = {};
vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8')
  .replace('__SUPPLIER_ASSETS__', '{}'), {
  self: {registration: {scope: 'https://example.test/app/'},
    location: {href: 'https://example.test/app/supplier_offline_sw.js'},
    addEventListener: (type, handler) => handlers[type] = handler},
  URL, Response,
  fetch: () => {throw Error('Unexpected network access');},
  caches: {open: () => {throw Error('Unexpected cache access');}},
});
(async () => {
  const paths = JSON.parse(process.argv[2]).concat([
    'flutter.js', 'canvaskit/skwasm.wasm', 'assets/fonts/icon.otf',
    'fonts/NotoSansSC.ttf', '', 'main.dart.js?version=new',
  ]);
  for (const path of paths) {
    let response;
    handlers.fetch({request: {method: 'GET', url: 'https://example.test/app/' + path},
      respondWith: value => response = value});
    assert.ok(response, path);
    assert.equal((await response).status, 503, path);
  }
  for (const url of ['https://example.test/app/help.txt',
    'https://example.test/other/main.dart.js', 'https://other.test/app/main.dart.js']) {
    handlers.fetch({request: {method: 'GET', url},
      respondWith: () => {throw Error('Unrelated request intercepted: ' + url);}});
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
'''
        subprocess.run(['node', '-e', script, str(APP/'web/supplier_offline_sw.js'),
                        json.dumps(REQUIRED_ASSETS)], check=True, capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
