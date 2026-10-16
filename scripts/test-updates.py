#!/usr/bin/env python3
"""Test real Sparkle installation and signature rejection using isolated dummy apps."""
import functools
import http.server
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = 'io.github.justinechang39.PDFMe'
ARTIFACT = ROOT / '.build/artifacts/sparkle/Sparkle'
TOOLS = ARTIFACT / 'bin'
FRAMEWORK_DIR = ARTIFACT / 'Sparkle.xcframework/macos-arm64_x86_64'


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kwargs)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    run('swift', 'package', 'resolve')
    key = subprocess.check_output([str(TOOLS / 'generate_keys'), '--account', ACCOUNT, '-p'], text=True).strip()
    production = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    assert key == production['SUPublicEDKey'], 'Test with the release signing key in Keychain'
    root = Path(tempfile.mkdtemp(prefix='update-qa-', dir=ROOT / 'work'))
    print(f'Test artifacts: {root}', flush=True)
    runner = root / 'Runner.app'
    (runner / 'Contents/MacOS').mkdir(parents=True)
    (runner / 'Contents/Frameworks').mkdir()
    run('ditto', ROOT / 'dist/PDFMe.app/Contents/Frameworks/Sparkle.framework', runner / 'Contents/Frameworks/Sparkle.framework')
    source = ROOT / '.build/checkouts/Sparkle/sparkle-cli'
    run('clang', '-fobjc-arc', '-mmacosx-version-min=13.0', '-DSPU_OBJC_DIRECT_MEMBERS=', '-DSPU_OBJC_DIRECT=',
        '-F', FRAMEWORK_DIR, '-framework', 'Sparkle', '-framework', 'Cocoa', '-Wl,-rpath,@executable_path/../Frameworks',
        *sorted(source.glob('*.m')), '-o', runner / 'Contents/MacOS/sparkle-cli')
    (runner / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='io.github.justinechang39.PDFMe.UpdateTestRunner.' + uuid.uuid4().hex,
        CFBundleExecutable='sparkle-cli', CFBundleName='Update test runner', CFBundlePackageType='APPL',
        CFBundleVersion='1', LSMinimumSystemVersion='13.0', LSUIElement=True,
        NSAppTransportSecurity={'NSAllowsLocalNetworking': True})))
    run('codesign', '--force', '--sign', '-', runner)
    checks = root / 'UpdaterChecks.app'
    (checks / 'Contents/MacOS').mkdir(parents=True)
    (checks / 'Contents/Frameworks').mkdir()
    run('ditto', ROOT / 'dist/PDFMe.app/Contents/Frameworks/Sparkle.framework', checks / 'Contents/Frameworks/Sparkle.framework')
    checks_info = dict(production)
    for key_to_remove in ["NSServices", "CFBundleDocumentTypes", "NSBonjourServices"]:
        checks_info.pop(key_to_remove, None)
    checks_info.update(CFBundleIdentifier='io.github.justinechang39.PDFMe.UpdaterChecks.' + uuid.uuid4().hex,
                       CFBundleExecutable='UpdaterChecks', CFBundleName='Updater Checks')
    (checks / 'Contents/Info.plist').write_bytes(plistlib.dumps(checks_info))
    run('swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx13.0',
        '-F', FRAMEWORK_DIR, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        ROOT / 'Sources/PDFMe/AppUpdater.swift', ROOT / 'scripts/UpdaterChecks.swift', '-o', checks / 'Contents/MacOS/UpdaterChecks')
    run('codesign', '--force', '--sign', '-', checks)
    try:
        run(checks / 'Contents/MacOS/UpdaterChecks', timeout=30)
    finally:
        subprocess.run(['defaults', 'delete', checks_info['CFBundleIdentifier']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # No production app binary runs in these fixtures.
    (root / 'fixture.c').write_text('int main(void) { return 0; }\n')
    run('clang', '-mmacosx-version-min=13.0', root / 'fixture.c', '-o', root / 'Fixture')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for mode in ['valid', 'tampered-archive', 'tampered-feed']:
            case = root / mode
            case.mkdir()
            feed_url = f'http://127.0.0.1:{server.server_port}/{mode}/appcast.xml'
            identifier = 'io.github.justinechang39.PDFMe.UpdateFixture.' + uuid.uuid4().hex
            old = case / 'installed/Fixture.app'
            new = case / 'next/Fixture.app'
            for bundle, version in [(old, '1'), (new, '2')]:
                (bundle / 'Contents/MacOS').mkdir(parents=True)
                shutil.copy2(root / 'Fixture', bundle / 'Contents/MacOS/Fixture')
                info = dict(CFBundleIdentifier=identifier, CFBundleExecutable='Fixture', CFBundleName='Update Fixture',
                    CFBundlePackageType='APPL', CFBundleVersion=version, CFBundleShortVersionString=version + '.0',
                    LSMinimumSystemVersion='13.0', SUFeedURL=feed_url, SUPublicEDKey=key,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True, SUEnableInstallerLauncherService=False,
                    NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                (bundle / 'Contents/Resources').mkdir()
                (bundle / 'Contents/Resources/version.txt').write_text(version)
                run('codesign', '--force', '--sign', '-', bundle)
            archive = case / 'Fixture.zip'
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', new, archive)
            run(TOOLS / 'generate_appcast', '--account', ACCOUNT, '--maximum-deltas', '0',
                '--download-url-prefix', f'http://127.0.0.1:{server.server_port}/{mode}/', case)
            run(TOOLS / 'sign_update', '--account', ACCOUNT, '--verify', case / 'appcast.xml')
            if mode == 'tampered-archive':
                data = bytearray(archive.read_bytes())
                data[len(data) // 2] ^= 1
                archive.write_bytes(data)
            elif mode == 'tampered-feed':
                feed = case / 'appcast.xml'
                feed.write_bytes(feed.read_bytes().replace(b'2.0', b'9.9'))
            with (case / 'result.log').open('w') as log:
                result = subprocess.run([str(runner / 'Contents/MacOS/sparkle-cli'), str(old), '--check-immediately',
                    '--grant-automatic-checks', '--user-agent-name', 'PDFMe-Local-Update-Test', '--verbose'],
                    stdout=log, stderr=subprocess.STDOUT, timeout=90)
            installed = plistlib.loads((old / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
            if mode == 'valid':
                assert result.returncode == 0 and installed == '2', (mode, (case / 'result.log').read_text())
                assert (old / 'Contents/Resources/version.txt').read_text() == '2'
                run('codesign', '--verify', '--deep', '--strict', old)
            else:
                assert result.returncode != 0 and installed == '1', (mode, (case / 'result.log').read_text())
            # The fixture never launches, so remove its isolated updater preferences.
            subprocess.run(['defaults', 'delete', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f'PASS: {mode}; installed version {installed}', flush=True)
    finally:
        server.shutdown()
    print('Real Sparkle update installed; tampered archive and feed rejected. PDFMe and printers untouched.')


if __name__ == '__main__':
    main()
