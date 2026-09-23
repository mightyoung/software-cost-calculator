"""Build/package a Flutter release with one verified offline asset generation.

No dependencies. Use --package-only for an already emitted Flutter release;
normal invocation first runs flutter build web --release (FLUTTER may override).
Deploy the whole output directory, including supplier_offline_sw.js.
"""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess

APP = Path(__file__).resolve().parents[1]
MARKER = '// SUPPLIER_OFFLINE_BOOTSTRAP'


def package(directory):
    directory = Path(directory)
    font_source=APP/'web/fonts'
    for name, expected in {
        'NotoSansSC.ttf':'a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da',
        'OFL.txt':'1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9',
    }.items():
        if hashlib.sha256((font_source/name).read_bytes()).hexdigest()!=expected:
            raise ValueError('Bundled font or license differs from reviewed upstream: '+name)
    shutil.copytree(font_source,directory/'fonts',dirs_exist_ok=True)
    font_manifest=directory/'assets/FontManifest.json'
    fonts=json.loads(font_manifest.read_text())
    # Web's default Roboto family is an alias for this unmodified CJK+Latin
    # font. The actual Noto font name and license remain intact.
    fonts=[font for font in fonts if font['family']!='Roboto']
    fonts.append({'family':'Roboto','fonts':[{'asset':'../fonts/NotoSansSC.ttf'}]})
    font_manifest.write_text(json.dumps(fonts,ensure_ascii=False))
    bootstrap = directory / 'flutter_bootstrap.js'
    previous = bootstrap.read_text()
    if MARKER in previous:
        engine = previous.split(MARKER)[0]
    else:
        # Compatibility with Flutter's default bootstrap for --package-only.
        head, separator, _ = previous.rpartition('_flutter.loader.load(')
        if not separator:
            raise ValueError('Unrecognized Flutter bootstrap; rebuild first')
        engine = head
    template = (APP/'web/flutter_bootstrap.js').read_text().split(MARKER)[1]
    bootstrap.write_text(engine + MARKER + template)
    index = directory/'index.html'
    index.write_text(index.read_text().replace('  <script src="supplier_platform.js"></script>\n', ''))
    assets = sorted(p for p in directory.rglob('*') if p.is_file() and p.name not in {
        'supplier_offline_sw.js', 'supplier_offline_manifest.json', 'flutter_service_worker.js',
    } and p.suffix not in {'.map', '.deps'})
    # Include the worker template in the release identity: policy updates need
    # their own generation even when application assets do not change.
    worker_template = (APP/'web/supplier_offline_sw.js').read_text()
    digest = hashlib.sha256(worker_template.encode())
    for path in assets:
        digest.update(path.relative_to(directory).as_posix().encode()+b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    release = digest.hexdigest()
    bootstrap.write_text(bootstrap.read_text().replace('__SUPPLIER_RELEASE__', release))
    hashes = {p.relative_to(directory).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in assets}
    worker = worker_template.replace('__SUPPLIER_RELEASE__',release).replace('__SUPPLIER_ASSETS__',json.dumps(hashes,sort_keys=True))
    (directory/'supplier_offline_sw.js').write_text(worker)
    (directory/'supplier_offline_manifest.json').write_text(json.dumps({'release':release,'assets':hashes},indent=2)+'\n')
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-only',action='store_true')
    parser.add_argument('--web-dir',type=Path,default=APP/'build/web')
    args = parser.parse_args()
    if not args.package_only:
        subprocess.run([os.environ.get('FLUTTER','flutter'),'build','web','--release'],cwd=APP,check=True)
    print(package(args.web_dir))


if __name__ == '__main__':
    main()
