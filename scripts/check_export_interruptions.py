#!/usr/bin/env python3
"""Isolated export fault checks. Retains logs/images for inspection; never deletes source files."""
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build-logs' / ('export-interrupt-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
OUT = OUT.resolve()
OUT.mkdir(parents=True, exist_ok=False)
WORK = OUT / 'work'
WORK.mkdir()
# Keep compiler/AVFoundation IPC socket paths short even when the repository path is long.
TMP = Path(tempfile.mkdtemp(prefix='jf-x-', dir='/tmp')).resolve()
ENV = dict(os.environ, JF_SUPPORT_DIR=str(WORK / 'support'), TMPDIR=str(TMP) + '/')
JOURNAL = WORK / 'support' / 'export-journal'
mounts = {}
child = None
results = []

def command(args, log=None, check=True, timeout=600):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, env=ENV, capture_output=True, timeout=timeout)
    if log:
        (OUT / log).write_bytes(result.stdout + result.stderr)
    if check and result.returncode:
        raise RuntimeError('Command failed: ' + str(args[0]) + (('; see ' + log) if log else ''))
    return result

def record(ok, message):
    results.append({'pass': bool(ok), 'check': message})
    print(('PASS ' if ok else 'FAIL ') + message, flush=True)
    (OUT / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    if not ok:
        raise RuntimeError(message)

def entries():
    return list(JOURNAL.glob('*.json'))

def staging():
    records = entries()
    if len(records) != 1:
        raise RuntimeError('Expected one journal entry, got ' + str(len(records)))
    data = json.loads(records[0].read_text())
    return Path(unquote(urlparse(data['staging']).path))

def kill_at(project, target, percent, log):
    global child
    logfile = OUT / log
    with logfile.open('wb') as stream:
        child = subprocess.Popen([BINARY, 'export', str(project), str(target)], cwd=ROOT, env=ENV, stdout=stream, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 600
        while True:
            found = [int(n) for n in re.findall(r'PROGRESS (\d+)%', logfile.read_text(errors='replace'))]
            if found and max(found) >= percent:
                if child.poll() is not None:
                    raise RuntimeError('Export finished before fault injection')
                child.kill()
                code = child.wait(timeout=30)
                child = None
                if code != -9:
                    raise RuntimeError('Fault injection did not terminate the test process')
                return
            if child.poll() is not None:
                raise RuntimeError('Export ended before requested progress; see ' + log)
            if time.monotonic() > deadline:
                raise RuntimeError('Export did not reach requested progress; see ' + log)
            time.sleep(.2)

def attach(image):
    result = command(['hdiutil', 'attach', image, '-nobrowse', '-plist'])
    entities = plistlib.loads(result.stdout)['system-entities']
    device = entities[0]['dev-entry']
    mounts[device] = None
    volumes = [e for e in entities if 'mount-point' in e]
    if len(volumes) != 1:
        raise RuntimeError('Unexpected mounted image layout')
    volume = Path(volumes[0]['mount-point'])
    if not volume.is_dir() or not str(volume).startswith('/Volumes/'):
        raise RuntimeError('Test image mount is not available')
    mounts[device] = volume
    return device, volume

def detach(device):
    command(['hdiutil', 'detach', device])
    mounts.pop(device, None)

def sweep(log):
    command([BINARY, 'sweep-exports'], log=log)

try:
    if os.environ.get('JF_TEST_BINARY'):
        BINARY = str(Path(os.environ['JF_TEST_BINARY']).resolve(strict=True))
    else:
        command(['swift', 'build', '--product', 'IndependentEditor'], log='build.log')
        BINARY = str(Path(command(['swift', 'build', '--show-bin-path']).stdout.decode().strip()) / 'IndependentEditor')
    (OUT / 'environment.json').write_text(json.dumps({'binary': BINARY, 'support': ENV['JF_SUPPORT_DIR'], 'tmpdir': ENV['TMPDIR']}, indent=2))
    target = WORK / 'F2.mp4'
    kill_at(ROOT / 'fixtures/F2.json', target, 50, '1-kill-F2.log')
    record(not target.exists(), '10 分钟工程 50% 强杀后不产生正式成片')
    partial = staging()
    record(partial.exists(), '导出记录指向真实残留')
    sweep('1-sweep.log')
    record(not partial.exists() and not entries(), '清理本次中断的暂存与记录')

    fat = WORK / 'fat.dmg'
    command(['hdiutil', 'create', '-size', '200m', '-fs', 'MS-DOS', '-volname', 'JFINT' + str(os.getpid()), '-o', fat])
    device, volume = attach(fat)
    (volume / 'exports').mkdir()
    target = volume / 'exports/F1.mp4'
    kill_at(ROOT / 'fixtures/F1.json', target, 30, '2-kill-F1-fat.log')
    record(not target.exists(), 'FAT32 测试映像强杀后不产生正式成片')
    partial = staging()
    if not partial.exists():
        raise RuntimeError('FAT32 staging was not created')
    detach(device)
    sweep('2-sweep-unplugged.log')
    record(len(entries()) == 1, '测试卷卸载时保留清理记录')
    device, volume = attach(fat)
    record(partial.exists(), '同一测试卷重挂后仍可找到残留')
    sweep('2-sweep-plugged.log')
    record(not partial.exists() and not entries(), '测试卷重挂后清理对应残留')
    detach(device)

    small = WORK / 'full.dmg'
    command(['hdiutil', 'create', '-size', '4m', '-fs', 'MS-DOS', '-volname', 'JFFULL' + str(os.getpid()), '-o', small])
    device, volume = attach(small)
    target = volume / 'F1.mp4'
    result = command([BINARY, 'export', ROOT / 'fixtures/F1.json', target], log='3-disk-full.log', check=False)
    details = (result.stdout + result.stderr).decode(errors='replace')
    disk_full = re.search(r'No space left|not enough (?:free |disk )?space|disk (?:is )?full|out of (?:disk )?space|空间不足|磁盘已满|NSCocoaErrorDomain\s+640|NSPOSIXErrorDomain\s+28|AVFoundationErrorDomain\s+-11807', details, re.IGNORECASE)
    record(result.returncode != 0 and 'COMPILED ' in details and 'PROGRESS ' in details and disk_full is not None, '进入实际导出后因测试卷写满而失败')
    left = [p for p in volume.rglob('*') if p.is_file() and not p.name.startswith('._')]
    record(not left and not entries() and not target.exists(), '写满后本次测试卷无成片或暂存残留')
    detach(device)
    print('EXPORT INTERRUPTION CHECKS: ' + str(len(results)) + ' PASS, 0 FAIL', flush=True)
finally:
    if child is not None and child.poll() is None:
        child.kill()
        child.wait(timeout=30)
    for device in list(mounts):
        subprocess.run(['hdiutil', 'detach', device], capture_output=True)
    # Retain only this run's logs, journal and images for diagnosis. No recursive deletion.
