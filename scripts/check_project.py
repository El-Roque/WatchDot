#!/usr/bin/env python3
"""Check portable project references, packaged dependencies and publication hygiene."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--json', action='store_true', help='Print a machine-readable summary.')
args = parser.parse_args()
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

project = plistlib.loads((SRC / 'WatchDot.xcodeproj/project.pbxproj').read_bytes())
objects = project['objects']
refs = [x for x in objects.values() if x.get('isa') == 'PBXFileReference' and x.get('sourceTree') == 'SOURCE_ROOT']
for ref in refs:
    relative = ref['path']; path = SRC / relative
    require(not Path(relative).is_absolute(), 'Absolute project reference: ' + relative)
    require(path.exists(), 'Missing project reference: ' + relative)
    require(path.resolve().is_relative_to(SRC.resolve()), 'Reference leaves src: ' + relative)
targets = [x for x in objects.values() if x.get('isa') == 'PBXNativeTarget']
require({x['name'] for x in targets} == {'WatchDot', 'WatchDotLauncher'}, 'Unexpected application targets.')
for x in objects.values():
    if x.get('isa') != 'XCBuildConfiguration':
        continue
    settings = x['buildSettings']
    if 'PRODUCT_BUNDLE_IDENTIFIER' in settings:
        require(settings.get('SDKROOT') == 'watchos', 'Non-watchOS application target.')
        require(settings.get('SWIFT_OPTIMIZATION_LEVEL') == '-O', 'Watch audio targets must use optimized Swift code generation.')
        require(not settings.get('DEVELOPMENT_TEAM'), 'Personal team is embedded in the project.')
        require('WATCHDOT_BUNDLE_ID' in settings['PRODUCT_BUNDLE_IDENTIFIER'], 'Signing ID must use the shared configuration.')
app_info = plistlib.loads((SRC / 'Config/AppInfo.plist').read_bytes())
require(app_info.get('WKWatchOnly') is True and app_info.get('WKApplication') is True, 'App is not Watch-only.')
require(not app_info.get('WKCompanionAppBundleIdentifier'), 'Unexpected iPhone companion requirement.')
require('WKRunsIndependentlyOfCompanionApp' not in app_info, 'Ambiguous Watch-only plist flags.')
launcher_info = plistlib.loads((SRC / 'Config/LauncherInfo.plist').read_bytes())
require(launcher_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.widgetkit-extension', 'Widget extension point is missing.')
for name in ['WatchDotOpus', 'OpenClawWatchRTC']:
    framework = SRC / 'Vendor' / (name + '.xcframework')
    info = plistlib.loads((framework / 'Info.plist').read_bytes())
    libraries = info['AvailableLibraries']
    require(any(x.get('SupportedPlatform') == 'watchos' and set(x.get('SupportedArchitectures', [])) >= {'arm64', 'arm64_32'} and x.get('SupportedPlatformVariant') is None for x in libraries), name + ': missing device architectures.')
    require(any(x.get('SupportedPlatformVariant') == 'simulator' and 'arm64' in x.get('SupportedArchitectures', []) for x in libraries), name + ': missing arm64 simulator.')
    for item in libraries:
        require((framework / item['LibraryIdentifier'] / item['LibraryPath']).is_file(), name + ': missing library file.')
notices = json.loads((SRC / 'Vendor/Notices/INDEX.json').read_text())
require(not notices.get('missingNotices'), 'Third-party notices are incomplete.')
for package in notices['packages']:
    require(bool(package['notices']), 'No license notice for ' + package['package'])
    for relative in package['notices']:
        require((SRC / 'Vendor/Notices' / relative).is_file(), 'Missing notice: ' + relative)

patterns = {
    'obsolete app name': re.compile(rb'apple' + rb'dot', re.IGNORECASE),
    'private user path': re.compile(rb'/Users/[A-Za-z0-9_.-]+/'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'provider secret key': re.compile(rb'\bsk-(?:proj-|svcacct-)[A-Za-z0-9_-]{20,}'),
    'GitHub token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'),
}
forbidden_directories = {'.tools', '.derivedData', '.derivedData-sim', '.cache-v2', '.build-v2', 'PhoneDotApp', 'investigacion-voz', 'investigacion-audio', 'SRC2'}
ignored = {'.git', '.build', 'DerivedData', '__pycache__', 'xcuserdata'}
files = 0; total = 0; largest = 0; cloud_placeholders = 0
for path in ROOT.rglob('*'):
    relative = path.relative_to(ROOT)
    if any(p in ignored for p in relative.parts) or relative.as_posix() == 'src/Config/Signing.local.xcconfig':
        continue
    require(not re.search('apple' + 'dot', relative.as_posix(), re.IGNORECASE), 'Obsolete name in path: ' + relative.as_posix())
    if path.is_dir():
        require(path.name not in forbidden_directories, 'Obsolete/local directory: ' + relative.as_posix())
        continue
    if path.is_symlink():
        require(path.resolve().is_relative_to(ROOT.resolve()) and path.exists(), 'Broken or external symlink: ' + relative.as_posix())
    if not path.is_file():
        continue
    file_stat = path.stat()
    files += 1; size = file_stat.st_size; total += size; largest = max(largest, size)
    require(size <= 100 * 1024 * 1024, 'File exceeds GitHub regular-Git limit: ' + relative.as_posix())
    require(path.suffix.lower() not in {'.p12', '.p8', '.key', '.mobileprovision', '.provisionprofile'}, 'Signing/secret material: ' + relative.as_posix())
    require(path.name != '.DS_Store', 'Finder metadata: ' + relative.as_posix())
    if path.resolve() == Path(__file__).resolve():
        continue
    # Darwin SF_DATALESS marks an iCloud placeholder, whose read may block.
    if sys.platform == 'darwin' and getattr(file_stat, 'st_flags', 0) & 0x40000000:
        cloud_placeholders += 1
        require(False, 'Cloud file is not downloaded: ' + relative.as_posix())
        continue
    data = path.read_bytes()
    for label, pattern in patterns.items():
        require(not pattern.search(data), label + ': ' + relative.as_posix())
for path in [ROOT / 'README.md', ROOT / 'CONTINUIDAD.md', *sorted((ROOT / 'docs').glob('*.md')), SRC / 'Native/README.md']:
    require(path.is_file(), 'Missing documentation: ' + path.name)
    if not path.is_file():
        continue
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', path.read_text()):
        if '://' in target or target.startswith('#') or target.startswith('mailto:'):
            continue
        require((path.parent / target.split('#', 1)[0]).exists(), 'Broken documentation link in ' + path.name + ': ' + target)
summary = {'status': 'pass' if not errors else 'fail', 'project_references': len(refs), 'watch_targets': len(targets), 'iPhone_targets': 0, 'files': files, 'bytes': total, 'largest_file_bytes': largest, 'dependency_notice_entries': len(notices['packages']), 'cloud_placeholders': cloud_placeholders, 'errors': errors}
print(json.dumps(summary, indent=2) if args.json else ('PASS: ' + str(len(refs)) + ' portable references, ' + str(files) + ' files, ' + str(len(notices['packages'])) + ' dependency notices.' if not errors else '\n'.join(errors)))
sys.exit(1 if errors else 0)
