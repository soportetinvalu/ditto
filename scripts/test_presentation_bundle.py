#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real LaunchServices app hosts, production presenter, empty external fields.
No TCC mutation, general clipboard, browser, capture, network, AX or OS key injection.
Baseline outcome is evidence, never manufactured into a required red.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '5c70c6c053c16c092b9c9925ebd5750d6cb7fb68'


def run(argv, **kwargs):
    print('+ ' + ' '.join(map(str, argv)), flush=True)
    return subprocess.run(list(map(str, argv)), check=True, cwd=ROOT, timeout=240, **kwargs)


def bundle(path, name, identifier, accessory=False):
    contents = path / (name + '.app') / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    plist = dict(CFBundleExecutable=name, CFBundleIdentifier=identifier,
                 CFBundlePackageType='APPL', CFBundleName=name, LSUIElement=accessory)
    (contents / 'Info.plist').write_bytes(plistlib.dumps(plist))
    return contents / 'MacOS' / name


def main():
    p = argparse.ArgumentParser()
    p.add_argument('output', type=Path)
    args = p.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    module = output / 'module'
    module.mkdir()
    header = ROOT / 'Sources/ClipCore/include/ClipCore.h'
    (module / 'module.modulemap').write_text('module ClipCore { header "' + str(header) + '" export * }\n')
    obj = output / 'core.o'
    run(['xcrun', 'clang', '-c', ROOT / 'Sources/ClipCore/core.c', '-I', header.parent, '-o', obj])
    external = bundle(output, 'FocusFixture', 'test.nexclip.presentation.external')
    run(['xcrun', 'swiftc', ROOT / 'Tests/Support/ExternalFocus.swift', '-o', external])
    history_path = 'Sources/NexClip/HistoryController.swift'
    current = (ROOT / history_path).read_text()
    baseline = run(['git', 'show', BASELINE + ':' + history_path], stdout=subprocess.PIPE).stdout.decode()
    # This counterfactual removes actual presentation, not assertions or AppKit state.
    start = current.index('        // Ordering a window is not activation')
    end = current.index('        recordOpening(.activationReturned)', start)
    negative = current[:start] + current[end:]
    assert negative != current
    sources = [p for p in sorted((ROOT / 'Sources/NexClip').glob('*.swift')) if p.name not in {'App.swift', 'HistoryController.swift'}]
    reports = []
    for variant, history in [('baseline', baseline), ('candidate', current), ('noPresentation', negative)]:
        folder = output / variant
        folder.mkdir()
        h = folder / 'HistoryController.swift'
        h.write_text(history)
        exe = bundle(folder, 'PresentationHost', 'test.nexclip.presentation.' + variant.lower(), True)
        run(['xcrun', 'swiftc', '-parse-as-library', '-I', module, *sources, h,
             ROOT / 'Tests/Support/PresentationBundle.swift', obj, '-lsqlite3', '-o', exe])
        for mode in ['text', 'secure']:
            target = folder / (mode + '.json')
            with (folder / (mode + '.log')).open('w') as log:
                # -W waits for this exact new LS instance; JSON is the actual verdict.
                run(['/usr/bin/open', '-W', '-n', exe.parents[2], '--args', target, external.parents[2], mode], stdout=log, stderr=subprocess.STDOUT)
            report = json.loads(target.read_text())
            report.update(variant=variant, history_sha256=hashlib.sha256(history.encode()).hexdigest())
            reports.append(report)
            print(json.dumps(report), flush=True)
    candidate = [r for r in reports if r['variant'] == 'candidate']
    negative = [r for r in reports if r['variant'] == 'noPresentation']
    # Exclude a precondition failure from the discriminating negative verdict.
    sensitivity = all(any(c['name'] == 'externalOwnsFocus' and c['passed'] for c in r['checks']) and
                      any(c['name'] == 'presentedActiveKeyVisible' and not c['passed'] for c in r['checks']) and
                      any(c['name'] == 'fixtureCleaned' and c['passed'] for c in r['checks']) for r in negative)
    passed = len(candidate) == 2 and all(r['passed'] and 'phase=activationCompleted' in r['diagnostic'] for r in candidate) and len(negative) == 2 and sensitivity
    summary = dict(passed=passed, baseline_sha=BASELINE, reports=reports,
                   sensitivity=sensitivity, candidate_cases=len(candidate), skipped=0,
                   source_commit=run(['git', 'rev-parse', 'HEAD'], stdout=subprocess.PIPE).stdout.decode().strip())
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('BUNDLE_SUMMARY ' + json.dumps({k: v for k, v in summary.items() if k != 'reports'}), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
