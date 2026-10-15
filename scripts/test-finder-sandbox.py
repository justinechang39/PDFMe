#!/usr/bin/env python3
"""Exercise the real Services IPC from a signed macOS sandbox. No printer access.

Temporarily registers an isolated receiver in ~/Applications, uses production
service parsing and handoff code, then removes the receiver. Never targets PDFMe.
"""
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parent.parent
LS = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
PBS = '/System/Library/CoreServices/pbs'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, cwd=REPO, **kwargs)


def main():
    run('swift', 'build', '--target', 'PDFMeCore')
    bin_dir = pathlib.Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=REPO, text=True).strip())
    (REPO / 'work').mkdir(exist_ok=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix='finder-sandbox-', dir=REPO / 'work'))
    applications = pathlib.Path.home() / 'Applications'
    applications.mkdir(exist_ok=True)
    receiver_app = applications / ('PDFMe Service Test-' + uuid.uuid4().hex + '.app')
    receiver_binary = receiver_app / 'Contents/MacOS/PDFMeTestReceiver'
    service = 'PDFMe Sandbox Handoff Test ' + uuid.uuid4().hex
    try:
        apps = []
        for name, source, sandbox in [('PDFMeTestReceiver', 'FinderServiceReceiver.swift', False),
                                      ('PDFMeTestSandbox', 'FinderServiceSandboxProbe.swift', True)]:
            app = root / (name + '.app') if sandbox else receiver_app
            executable = app / 'Contents/MacOS' / name
            executable.parent.mkdir(parents=True)
            info = {'CFBundleName': name, 'CFBundleExecutable': name,
                    'CFBundleIdentifier': 'io.github.justinechang39.PDFMe.Test.' + uuid.uuid4().hex,
                    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
                    'CFBundleSupportedPlatforms': ['MacOSX'], 'LSMinimumSystemVersion': '13.0',
                    'NSPrincipalClass': 'NSApplication', 'LSUIElement': True}
            if not sandbox:
                info['NSServices'] = [{'NSMenuItem': {'default': service}, 'NSMessage': 'addToPrintQueue',
                                       'NSPortName': name, 'NSSendFileTypes': ['com.adobe.pdf'], 'NSRequiredContext': {}}]
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            # Explicit deployment target matters: a future default target can run
            # in Terminal while Launch Services rejects the app and its services.
            command = ['swiftc', '-parse-as-library', '-target', platform.machine() + '-apple-macosx13.0',
                       str(REPO / 'scripts' / source)]
            if sandbox:
                command += ['Extensions/PDFMeFinder/FinderSelection.swift', 'Extensions/PDFMeFinder/FinderServiceHandoff.swift']
            else:
                command += ['Sources/PDFMe/FinderPrintService.swift', '-I', str(bin_dir / 'Modules')]
                command += [str(p) for p in (bin_dir / 'PDFMeCore.build').glob('*.swift.o')]
            run(*command, '-o', str(executable))
            command = ['codesign', '--force', '--sign', '-']
            if sandbox:
                command += ['--entitlements', str(REPO / 'Extensions/PDFMeFinder/Entitlements.plist')]
            run(*command, str(app))
            apps.append((app, executable))
        run(LS, '-f', str(receiver_app))
        run('open', '-a', str(receiver_app), '--args', str(root))
        for _ in range(100):
            if (root / 'ready').exists():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Test receiver did not start')
        run(PBS, '-update')
        for _ in range(50):
            if service in subprocess.check_output([PBS, '-dump'], text=True):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Test service was not registered')
        files = [root / 'Sample A & B.pdf', root / '学习.PDF']
        hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in files]
        result = run(str(apps[1][1]), str(root), service, capture_output=True, text=True, timeout=45)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
        received = json.loads((root / 'received.json').read_text())
        assert received['valid'] and received['paths'] == [str(p) for p in files]
        assert hashes == [hashlib.sha256(p.read_bytes()).hexdigest() for p in files]
        print('PASS: production service received both PDFs in order and could read them; sources unchanged')
        print('Real sandbox handoff passed. PDFMe’s queue and printers were not used.')
    finally:
        for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1] == str(receiver_binary):
                try:
                    os.kill(int(parts[0]), 15)
                except ProcessLookupError:
                    pass
        if receiver_app.exists():
            subprocess.run([LS, '-u', str(receiver_app)], check=False)
            shutil.rmtree(receiver_app)
        subprocess.run([PBS, '-update'], check=False)


if __name__ == '__main__':
    main()
