#!/usr/bin/env python3
"""Generate the relocatable, watchOS-only Xcode project using Python's standard library."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1] / 'src'
OBJECTS = {}

def identifier(key):
    return hashlib.sha256(('WatchDot:' + key).encode()).hexdigest()[:24].upper()

def add(key, value):
    ref = identifier(key)
    OBJECTS[ref] = value
    return ref

def reference(relative, kind):
    assert (ROOT / relative).exists(), relative
    return add('file:' + relative, {'isa': 'PBXFileReference', 'path': relative,
        'lastKnownFileType': kind, 'sourceTree': 'SOURCE_ROOT'})

def phase(key, kind, files):
    return add(key, {'isa': kind, 'buildActionMask': 2147483647,
        'files': files, 'runOnlyForDeploymentPostprocessing': 0})

def build_files(key, refs):
    return [add(key + ':' + ref, {'isa': 'PBXBuildFile', 'fileRef': ref}) for ref in refs]

base_config = reference('Config/Project.xcconfig', 'text.xcconfig')
app_sources = sorted(p.relative_to(ROOT).as_posix() for folder in ['Sources/WatchDotCore', 'Sources/WatchDotApp'] for p in (ROOT / folder).rglob('*.swift'))
launcher_sources = ['Sources/WatchDotLauncher/WatchDotLauncher.swift']
app_refs = [reference(p, 'sourcecode.swift') for p in app_sources]
launcher_refs = [reference(p, 'sourcecode.swift') for p in launcher_sources]
framework_refs = [reference('Vendor/' + name + '.xcframework', 'wrapper.xcframework') for name in ['OpenClawWatchRTC', 'WatchDotOpus']]
app_resources = [reference('Resources/App/Assets.xcassets', 'folder.assetcatalog'), reference('Resources/App/DotRingback.wav', 'audio.wav')]
launcher_resources = [reference('Resources/Launcher/Assets.xcassets', 'folder.assetcatalog')]
info_refs = [reference('Config/AppInfo.plist', 'text.plist.xml'), reference('Config/LauncherInfo.plist', 'text.plist.xml')]
app_product = add('app-product', {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.application', 'includeInIndex': 0, 'path': 'WatchDot.app', 'sourceTree': 'BUILT_PRODUCTS_DIR'})
launcher_product = add('launcher-product', {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.app-extension', 'includeInIndex': 0, 'path': 'WatchDotLauncher.appex', 'sourceTree': 'BUILT_PRODUCTS_DIR'})
products = add('products', {'isa': 'PBXGroup', 'name': 'Products', 'sourceTree': '<group>', 'children': [app_product, launcher_product]})
main = add('main', {'isa': 'PBXGroup', 'sourceTree': '<group>', 'children': app_refs + launcher_refs + framework_refs + app_resources + launcher_resources + info_refs + [base_config, products]})

def configurations(name, is_extension=False, project=False):
    refs = []
    for config in ['Debug', 'Release']:
        if project:
            settings = {'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES'}
        else:
            settings = {
                'SDKROOT': 'watchos', 'SUPPORTED_PLATFORMS': 'watchos watchsimulator',
                'WATCHOS_DEPLOYMENT_TARGET': '11.0', 'TARGETED_DEVICE_FAMILY': '4',
                'SWIFT_VERSION': '6.0', 'CODE_SIGN_STYLE': 'Automatic',
                'CURRENT_PROJECT_VERSION': '4', 'MARKETING_VERSION': '1.0',
                'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_CFBundleDisplayName': 'WatchDot',
                'PRODUCT_BUNDLE_IDENTIFIER': '$(WATCHDOT_BUNDLE_ID)' + ('.launcher' if is_extension else ''),
                'PRODUCT_NAME': 'WatchDotLauncher' if is_extension else 'WatchDot',
                'INFOPLIST_FILE': 'Config/LauncherInfo.plist' if is_extension else 'Config/AppInfo.plist',
                'SKIP_INSTALL': 'YES' if is_extension else 'NO',
                'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
            }
            if is_extension:
                settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
            else:
                settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
                settings['SWIFT_INCLUDE_PATHS'] = '$(inherited) $(BUILT_PRODUCTS_DIR)/include/OpenClawWatchRTC $(BUILT_PRODUCTS_DIR)/include/WatchDotOpus'
            if config == 'Debug':
                # Preserve the physically accepted build's optimized audio path.
                settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-O', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) DEBUG'})
            else:
                settings['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
        obj = {'isa': 'XCBuildConfiguration', 'name': config, 'buildSettings': settings}
        if not project:
            obj['baseConfigurationReference'] = base_config
        refs.append(add(name + ':' + config, obj))
    return add(name + '-list', {'isa': 'XCConfigurationList', 'buildConfigurations': refs, 'defaultConfigurationIsVisible': 0, 'defaultConfigurationName': 'Release'})

launcher = add('launcher', {'isa': 'PBXNativeTarget', 'name': 'WatchDotLauncher', 'productName': 'WatchDotLauncher', 'productReference': launcher_product, 'productType': 'com.apple.product-type.app-extension',
    'buildConfigurationList': configurations('launcher-config', is_extension=True), 'buildRules': [], 'dependencies': [],
    'buildPhases': [phase('launcher-sources', 'PBXSourcesBuildPhase', build_files('launcher-source-build', launcher_refs)), phase('launcher-frameworks', 'PBXFrameworksBuildPhase', []), phase('launcher-resources', 'PBXResourcesBuildPhase', build_files('launcher-resource-build', launcher_resources))]})
proxy = add('launcher-proxy', {'isa': 'PBXContainerItemProxy', 'containerPortal': identifier('project'), 'proxyType': 1, 'remoteGlobalIDString': launcher, 'remoteInfo': 'WatchDotLauncher'})
dependency = add('launcher-dependency', {'isa': 'PBXTargetDependency', 'target': launcher, 'targetProxy': proxy})
embed_build = add('launcher-embed-build', {'isa': 'PBXBuildFile', 'fileRef': launcher_product, 'settings': {'ATTRIBUTES': ['RemoveHeadersOnCopy']}})
embed = add('launcher-embed', {'isa': 'PBXCopyFilesBuildPhase', 'name': 'Embed App Extensions', 'buildActionMask': 2147483647, 'dstPath': '', 'dstSubfolderSpec': 13, 'files': [embed_build], 'runOnlyForDeploymentPostprocessing': 0})
app = add('app', {'isa': 'PBXNativeTarget', 'name': 'WatchDot', 'productName': 'WatchDot', 'productReference': app_product, 'productType': 'com.apple.product-type.application',
    'buildConfigurationList': configurations('app-config'), 'buildRules': [], 'dependencies': [dependency],
    'buildPhases': [phase('app-sources', 'PBXSourcesBuildPhase', build_files('app-source-build', app_refs)), phase('app-frameworks', 'PBXFrameworksBuildPhase', build_files('framework-build', framework_refs)), phase('app-resources', 'PBXResourcesBuildPhase', build_files('app-resource-build', app_resources)), embed]})
project = add('project', {'isa': 'PBXProject', 'attributes': {'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2660'}, 'buildConfigurationList': configurations('project-config', project=True),
    'compatibilityVersion': 'Xcode 15.0', 'developmentRegion': 'en', 'hasScannedForEncodings': 0, 'knownRegions': ['en', 'Base'], 'mainGroup': main, 'productRefGroup': products, 'projectDirPath': '', 'projectRoot': '', 'targets': [app, launcher]})
bundle = ROOT / 'WatchDot.xcodeproj'; bundle.mkdir(exist_ok=True)
(bundle / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '60', 'objects': OBJECTS, 'rootObject': project}, sort_keys=False))
scheme = bundle / 'xcshareddata/xcschemes'; scheme.mkdir(parents=True, exist_ok=True)
buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="WatchDot.app" BlueprintName="WatchDot" ReferencedContainer="container:WatchDot.xcodeproj"/>'
(scheme / 'WatchDot.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
print(json.dumps({'targets': 2, 'application_sources': len(app_sources), 'widget_sources': len(launcher_sources), 'iPhone_target': False}))
