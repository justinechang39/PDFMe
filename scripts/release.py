#!/usr/bin/env python3
"""Build/sign locally, then publish verified artifacts to GitHub. Never runs Actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPO = 'justinechang39/PDFMe'
ACCOUNT = 'io.github.justinechang39.PDFMe'
TOOLS = ROOT / '.build/artifacts/sparkle/Sparkle/bin'


def run(*args, capture=False, **kwargs):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None, **kwargs)
    return result.stdout.strip() if capture else None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_head():
    if run('git', 'status', '--porcelain', capture=True):
        raise SystemExit('Commit the release source before preparing or publishing.')
    if run('git', 'branch', '--show-current', capture=True) != 'main':
        raise SystemExit('Publish releases from main.')
    return run('git', 'rev-parse', 'HEAD', capture=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'publish'])
    parser.add_argument('--notes', type=Path, help='Release notes Markdown (prepare only)')
    args = parser.parse_args()
    head = clean_head()
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    tag = 'v' + version
    output = ROOT / 'dist/releases' / tag
    archive_name = 'PDFMe-macOS-universal.zip'
    if args.mode == 'prepare':
        if not args.notes or not args.notes.is_file():
            raise SystemExit('Pass --notes with a release notes file.')
        if output.exists():
            raise SystemExit(f'{output} already exists. Review it before preparing another release.')
        run('./scripts/build.sh', env=dict(os.environ, PDFME_ARCHS='arm64 x86_64'))
        public_key = run(TOOLS / 'generate_keys', '--account', ACCOUNT, '-p', capture=True)
        if public_key != info['SUPublicEDKey']:
            raise SystemExit('Keychain signing key does not match the app public key. No release prepared.')
        output.mkdir(parents=True)
        archive = output / archive_name
        archive.write_bytes((ROOT / 'dist' / archive_name).read_bytes())
        notes = args.notes.read_text()
        (output / 'release-notes.md').write_text(notes)
        (output / 'PDFMe-macOS-universal.md').write_text(notes)
        run(TOOLS / 'generate_appcast', '--account', ACCOUNT, '--maximum-deltas', '0',
            '--embed-release-notes', '--link', f'https://github.com/{REPO}',
            '--download-url-prefix', f'https://github.com/{REPO}/releases/download/{tag}/', output)
        run(TOOLS / 'sign_update', '--account', ACCOUNT, '--verify', output / 'appcast.xml')
        ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
        item = ET.parse(output / 'appcast.xml').find('./channel/item')
        assert item is not None and item.findtext(ns + 'version') == build
        enclosure = item.find('enclosure')
        assert enclosure.get('url') == f'https://github.com/{REPO}/releases/download/{tag}/{archive_name}'
        run(TOOLS / 'sign_update', '--account', ACCOUNT, '--verify', archive, enclosure.get(ns + 'edSignature'))
        hashes = {name: digest(output / name) for name in [archive_name, 'appcast.xml', 'release-notes.md']}
        (output / 'SHA256SUMS').write_text(''.join(f'{value}  {name}\n' for name, value in hashes.items()))
        (output / 'release.json').write_text(json.dumps(dict(commit=head, version=version, build=build, sha256=hashes), indent=2) + '\n')
        print(f'Prepared {output}. Run local tests, push main, then use: ./scripts/release.py publish')
    else:
        manifest = json.loads((output / 'release.json').read_text())
        assert manifest['commit'] == head and manifest['version'] == version and manifest['build'] == build
        for name, expected in manifest['sha256'].items():
            assert digest(output / name) == expected, f'Artifact changed: {name}'
        permissions = json.loads(run('gh', 'api', f'repos/{REPO}/actions/permissions', capture=True))
        if permissions.get('enabled') is not False:
            raise SystemExit('GitHub Actions must remain disabled before publishing.')
        remote = run('git', 'ls-remote', 'origin', 'refs/heads/main', capture=True).split()[0]
        if remote != head:
            raise SystemExit('Push this exact release commit to origin/main first.')
        run('gh', 'release', 'create', tag, output / archive_name, output / 'appcast.xml', output / 'SHA256SUMS',
            '--repo', REPO, '--target', head, '--title', f'PDFMe {version}', '--notes-file', output / 'release-notes.md', '--draft')
        run('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--latest')
        print(f'Published https://github.com/{REPO}/releases/tag/{tag}')


if __name__ == '__main__':
    main()
