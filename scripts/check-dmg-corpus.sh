#!/bin/zsh
# Opt-in real-image compatibility run. Requires the local inventory produced during corpus
# discovery; third-party images and extracted metadata never become test resources or commits.
# Usage: scripts/check-dmg-corpus.sh [--source DIR] [--inventory JSON]
#          [--expectations JSON] [--derived-data DIR] [--report-dir DIR] [--payloads] [--dry-run]
# Expectations are a JSON object keyed by original relative filename. Supported override keys
# match ImageExpectation in Tests/DMGCorpusTests.swift, e.g. expectedCanvas, expectedBackground,
# expectedBackgroundSize, expectedWindowSize, expectedIconSize and expectedPositions.
set -euo pipefail
cd "${0:a:h}/.."
source_dir=/Volumes/DataHouse/PortalDown
inventory=$PWD/build/dmg-corpus/inventory/inventory.json
expectations=$PWD/build/dmg-corpus/corpus-runner/expected-layouts.json
derived_data=$PWD/build
report_dir=$PWD/build/dmg-corpus/corpus-runner/run-$(date +%Y%m%d-%H%M%S)-$$
dry_run=0
payloads=0
while (( $# )); do
  case $1 in
    --source|--inventory|--expectations|--derived-data|--report-dir)
      (( $# >= 2 )) || { print -u2 "error: $1 requires a value"; exit 2; }
      case $1 in
        --source) source_dir=$2 ;;
        --inventory) inventory=$2 ;;
        --expectations) expectations=$2 ;;
        --derived-data) derived_data=$2 ;;
        --report-dir) report_dir=$2 ;;
      esac
      shift 2 ;;
    --payloads) payloads=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) sed -n '2,11p' "$0"; exit 0 ;;
    *) print -u2 "error: unknown argument $1"; exit 2 ;;
  esac
done
source_dir=${source_dir:A}
inventory=${inventory:A}
expectations=${expectations:A}
derived_data=${derived_data:A}
report_dir=${report_dir:A}
[[ -f $inventory ]] || { print -u2 "error: inventory does not exist: $inventory"; exit 2; }
[[ -x Vendor/7zip/7zz ]] || { print -u2 "error: run scripts/fetch-7zip.sh first"; exit 2; }
if (( ! dry_run )); then
  [[ -f Stow.xcodeproj/project.pbxproj ]] || { print -u2 'error: run xcodegen generate first'; exit 2; }
  rg -q DMGCorpusTests.swift Stow.xcodeproj/project.pbxproj || {
    print -u2 'error: regenerate Stow.xcodeproj with xcodegen generate to include DMGCorpusTests.swift'; exit 2
  }
fi

# The sandbox host must read inputs without a user-granted Downloads/volume bookmark. Stage
# inside its own container, not in /tmp or the repository. mktemp and private modes isolate runs.
sandbox_tmp="$HOME/Library/Containers/app.stow.Stow/Data/tmp"
[[ -d $sandbox_tmp ]] || { print -u2 "error: Stow test host container does not exist: $sandbox_tmp"; exit 2; }
if (( dry_run )); then
  stage=""
else
  mkdir -p "$report_dir"
  stage=$(mktemp -d "$sandbox_tmp/StowDMGCorpus.XXXXXXXX")
  chmod 700 "$stage"
fi
finish() {
  local exit_status=$?
  if [[ -n $stage && -d $stage ]]; then
    # Retain only small JSON/Markdown evidence. Never copy the staged DMGs or reference bytes out.
    if [[ -d $stage/Reports ]]; then
      cp -R "$stage/Reports/." "$report_dir/" || true
    fi
    [[ ! -f $stage/manifest.json ]] || cp "$stage/manifest.json" "$report_dir/manifest.json" || true
    rm -rf "$stage"
  fi
  if (( ! dry_run )); then print "DMG corpus reports: $report_dir"; fi
  return $exit_status
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$source_dir" "$inventory" "$expectations" "$stage" "$report_dir" "$dry_run" "$PWD/Vendor/7zip/7zz" <<'PY'
import hashlib, json, os, plistlib, shutil, subprocess, sys, tempfile
from pathlib import Path

source, inventory_path, expectations_path, stage_text, reports, dry_text, seven = sys.argv[1:]
source = Path(source).resolve()
inventory_path = Path(inventory_path)
dry = dry_text == '1'
inventory = json.loads(inventory_path.read_text())
records = inventory['files']
if not source.is_dir() or not records:
    raise SystemExit('error: source directory or image inventory is empty')
discovered = {str(p.relative_to(source)) for p in source.rglob('*') if p.is_file() and p.suffix.lower() == '.dmg'}
recorded = {r['relativePath'] for r in records}
if recorded != discovered or len(recorded) != len(records):
    raise SystemExit(f'error: inventory does not match all source DMGs; missing={sorted(discovered-recorded)}, stale={sorted(recorded-discovered)}')
overrides = {}
if Path(expectations_path).is_file():
    overrides = json.loads(Path(expectations_path).read_text())
    if 'images' in overrides:
        overrides = {r['filename']: r for r in overrides['images']}
    if not isinstance(overrides, dict):
        raise SystemExit('error: layout expectations must be keyed by filename or contain an images array')
total = sum(r['size'] for r in records)
sandbox_tmp = Path.home() / 'Library/Containers/app.stow.Stow/Data/tmp'
free = shutil.disk_usage(sandbox_tmp).free
required = total + (2 << 30)
if free < required:
    raise SystemExit(f'error: staging needs {required:,} free bytes including 2 GiB reserve; available={free:,}')
print(f'Corpus: {len(records)} images, {total:,} bytes; free space {free:,}; layout overrides for {len(overrides)} images', flush=True)
if dry:
    print('Dry run: no images copied and no xcodebuild invoked. Compilation conditions append DEBUG STOW_DMG_CORPUS to $(inherited).')
    raise SystemExit(0)

stage = Path(stage_text)
(stage / 'Images').mkdir(mode=0o700)
(stage / 'Reports').mkdir(mode=0o700)
(stage / 'Reference').mkdir(mode=0o700)
allowed_overrides = {'expectedCanvas', 'expectedBackground', 'expectedBackgroundSize', 'expectedWindowSize',
                     'expectedIconSize', 'expectedTextSize', 'expectedBackgroundKind', 'expectedPositions',
                     'expectedBackgroundPath', 'expectedIconApps', 'expectedIconPaths', 'expectedDropTargets', 'expectedSignatureValidity'}

def listing_entries(record):
    raw = (inventory_path.parent / record['listing']['stdoutArtifact']).read_bytes().decode('utf-8')
    _, separator, body = raw.partition('----------\n')
    if not separator:
        raise ValueError('ordinary listing has no entry section')
    entries = {}
    for block in body.split('\n\n'):
        fields = dict(line.split(' = ', 1) for line in block.split('\n') if ' = ' in line)
        if 'Path' in fields:
            if fields.get('Alternate Stream') == '+':
                continue
            entries[fields['Path']] = fields
    return entries

def read_reference(image, path, size):
    if size < 0 or size > 24 << 20:
        raise ValueError(f'reference exceeds 24 MiB: {path}')
    completed = subprocess.run([seven, 'x', '-so', '-sns-', '-y', '-spd', '-p-', str(image), path],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if completed.returncode != 0 or len(completed.stdout) != size:
        raise ValueError(f'reference extraction failed for {path}: exit={completed.returncode}, expected={size}, actual={len(completed.stdout)}')
    return completed.stdout

images = []
for record in records:
    original = source / record['relativePath']
    resolved = original.resolve()
    if original.is_symlink() or not resolved.is_relative_to(source) or original.stat().st_size != record['size']:
        raise SystemExit(f'error: changed, symbolic or out-of-source input: {original}')
    image_dir = stage / 'Images' / record['id']
    image_dir.mkdir(mode=0o700)
    image = image_dir / original.name
    checksum = hashlib.sha256()
    with original.open('rb') as reader, image.open('xb') as writer:
        os.chmod(image, 0o600)
        for chunk in iter(lambda: reader.read(4 << 20), b''):
            writer.write(chunk)
            checksum.update(chunk)
    if checksum.hexdigest() != record['sha256']:
        raise SystemExit(f'error: source hash differs from inventory: {original}')
    entries = listing_entries(record)
    root = record['listing']['roots'][0] if record['rootShape'] == 'volume-prefixed' else ''
    prefix = root + '/' if root else ''
    depth = 1 if root else 0
    apps = sorted(p for p, e in entries.items() if p.count('/') == depth and p.lower().endswith('.app') and e.get('Mode', '').startswith('d'))
    packages = sorted(p for p in entries if p.count('/') == depth and p.lower().endswith(('.pkg', '.mpkg')))
    installables = apps + packages
    store_path = prefix + '.DS_Store'
    store_size = int(entries[store_path]['Size']) if store_path in entries else None
    presentation = {}
    for path, entry in entries.items():
        relative = path[len(prefix):] if path.startswith(prefix) else ''
        if entry.get('Mode', '').startswith('-') and (relative == '.DS_Store' or relative == '.VolumeIcon.icns'
            or (relative.startswith('.background.') and '/' not in relative)
            or (relative.startswith('.background/') and relative.count('/') == 1)):
            presentation[path] = int(entry['Size'])
    expected = {'id': record['id'], 'filename': record['relativePath'], 'stagedPath': str(image),
                'originalPath': str(original), 'sha256': record['sha256'],
                'expectedRoot': root, 'expectedAppPaths': apps,
                'expectedInstallablePath': installables[0] if len(installables) == 1 else None,
                'expectedDropTargets': {},
                'expectedPresentationFiles': presentation, 'expectedStoreSize': store_size,
                'expectedCanvas': False if store_size is None else None,
                'expectedIconApps': [], 'referenceFiles': []}
    references = {}
    if store_size is not None and store_size <= 4 << 20:
        references[store_path] = read_reference(image, store_path, store_size)
    for path, entry in entries.items():
        if path.count('/') == depth and path.rsplit('/', 1)[-1] in ('Applications', '应用程序') and entry.get('Mode', '').startswith('l'):
            target = entry.get('Symbolic Link')
            if not target:
                target = read_reference(image, path, int(entry['Size'])).decode('utf-8').rstrip('\0')
            if target.startswith('/'):
                expected['expectedDropTargets'][path] = target
    for app in apps:
        path = app + '/Contents/Info.plist'
        entry = entries.get(path)
        if not entry or not entry.get('Mode', '').startswith('-') or int(entry['Size']) > 1 << 20:
            continue
        plist_bytes = read_reference(image, path, int(entry['Size']))
        references[path] = plist_bytes
        info = plistlib.loads(plist_bytes)
        icon_name = info.get('CFBundleIconFile')
        if not isinstance(icon_name, str) or not icon_name or '/' in icon_name or icon_name in ('.', '..'):
            # Asset-catalog-only and missing declarations remain explicitly unverified.
            continue
        if not Path(icon_name).suffix:
            icon_name += '.icns'
        icon_path = app + '/Contents/Resources/' + icon_name
        icon_entry = entries.get(icon_path)
        if not icon_entry or not icon_entry.get('Mode', '').startswith('-') or int(icon_entry['Size']) > 24 << 20:
            continue
        icon_bytes = read_reference(image, icon_path, int(icon_entry['Size']))
        references[icon_path] = icon_bytes
        # Independently establish that macOS can decode the declared file. Stow's bounded
        # ImageIO decoder still has to do so through its own XPC metadata path in the test.
        icon_file = stage / 'Reference' / (record['id'] + Path(icon_name).suffix)
        icon_file.write_bytes(icon_bytes)
        probe = subprocess.run(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(icon_file)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, text=True)
        if probe.returncode == 0 and 'pixelWidth: ' in probe.stdout and 'pixelHeight: ' in probe.stdout and '<nil>' not in probe.stdout:
            expected['expectedIconApps'].append(app)
        icon_file.unlink()
    if sum(map(len, references.values())) > 32 << 20:
        raise SystemExit(f'error: aggregate reference data exceeds 32 MiB: {original.name}')
    expected['referenceFiles'] = [{'path': path, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                                 for path, data in sorted(references.items())]
    override = overrides.get(record['relativePath'], {})
    if 'expectedVolumeRoot' in override and override['expectedVolumeRoot'] != root:
        raise SystemExit(f'error: independent audit disagrees with inventory volume root: {original.name}')
    expected.update({key: value for key, value in override.items() if key in allowed_overrides})
    if override.get('backgroundType') in (0, 1, 2):
        expected['expectedBackgroundKind'] = {0: 'plain', 1: 'color', 2: 'picture'}[override['backgroundType']]
    expected['expectationSource'] = str(expectations_path) if override else 'inventory + direct metadata reference reads'
    images.append(expected)
    print(f'Staged {len(images)}/{len(records)}: {record["relativePath"]}; {len(references)} bounded reference files', flush=True)
manifest = {'schemaVersion': 1, 'stageDirectory': str(stage), 'reportDirectory': str(stage / 'Reports'), 'images': images}
(stage / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
os.chmod(stage / 'manifest.json', 0o600)
PY

if (( dry_run )); then exit 0; fi
# TEST_RUNNER_ is stripped by macOS XCTest before values reach the sandboxed test host (the
# same forwarding mechanism used by the fuzz workflow). Preserve inherited conditions and
# Debug explicitly when adding the opt-in flag; ordinary CI contains no skipped corpus tests.
TEST_RUNNER_STOW_DMG_CORPUS="$stage/manifest.json" TEST_RUNNER_STOW_DMG_CORPUS_PAYLOADS="$payloads" \
  xcodebuild -project Stow.xcodeproj -scheme Stow -configuration Debug \
  -derivedDataPath "$derived_data" -parallel-testing-enabled NO \
  -only-testing:StowTests/DMGCorpusTests \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG STOW_DMG_CORPUS' \
  test > "$report_dir/xcodebuild.log" 2>&1 || {
    tail -80 "$report_dir/xcodebuild.log"
    exit 1
  }
tail -25 "$report_dir/xcodebuild.log"
