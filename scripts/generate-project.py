#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
import hashlib
import pathlib
import json
import argparse
import plistlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--isolated-qa', action='store_true', help='Generate a separate Release-QA host and project under .build')
args = parser.parse_args()
project_filename = 'ResimQA.xcodeproj' if args.isolated_qa else 'Resim.xcodeproj'
project = ROOT / '.build' / project_filename if args.isolated_qa else ROOT / project_filename
scheme_container = '.build/' + project_filename if args.isolated_qa else project_filename
qa_plist = ROOT / '.build' / 'Resim-QA-Info.plist'
if args.isolated_qa:
    qa_plist.parent.mkdir(parents=True, exist_ok=True)
    info = plistlib.loads((ROOT / 'Resim/Info.plist').read_bytes())
    info.update(CFBundleName='Resim QA Host', CFBundleDisplayName='Resim QA Host')
    qa_plist.write_bytes(plistlib.dumps(info))
objects = {}
def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(identifier, isa, **values):
    key = ident(identifier)
    objects[key] = dict(isa=isa, **values)
    return key
def q(value, level=0):
    indent = '\t' * level
    if isinstance(value, dict):
        return '{\n' + ''.join(f'{indent}\t{q(k)} = {q(v, level + 1)};\n' for k, v in value.items()) + indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(f'{indent}\t{q(v, level + 1)},\n' for v in value) + indent + ')'
    return json.dumps(str(value), ensure_ascii=False)
def config_list(name, base):
    configs = []
    for mode in ['Debug', 'Release']:
        values = dict(base)
        values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                      GCC_OPTIMIZATION_LEVEL='0' if mode == 'Debug' else 's',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
        if mode == 'Debug':
            values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        configs.append(add(name + mode, 'XCBuildConfiguration', name=mode, buildSettings=values))
    return add(name + 'configs', 'XCConfigurationList', buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
app_files = []
app_sources = []
resources = []
for path in sorted((ROOT / 'Resim').rglob('*')):
    relative = str(path.relative_to(ROOT))
    if path.suffix in ['.swift', '.c', '.h']:
        typ = {'.swift':'sourcecode.swift', '.c':'sourcecode.c.c', '.h':'sourcecode.c.h'}[path.suffix]
        ref = add(relative, 'PBXFileReference', lastKnownFileType=typ, path=relative, sourceTree='<group>')
        app_files.append(ref)
        if path.suffix != '.h':
            app_sources.append(add(relative+'build', 'PBXBuildFile', fileRef=ref))
for path, typ in [('Resim/Resources/Assets.xcassets', 'folder.assetcatalog'),
                  ('Resim/Resources/Localizable.xcstrings', 'text.json.xcstrings'),
                  ('Resim/Resources/InfoPlist.xcstrings', 'text.json.xcstrings'),
                  ('Resim/Resources/Codecs', 'folder'), ('Resim/Resources/Licenses', 'folder')]:
    if (ROOT / path).exists():
        ref = add(path, 'PBXFileReference', lastKnownFileType=typ, path=path, sourceTree='<group>')
        app_files.append(ref)
        resources.append(add(path+'build', 'PBXBuildFile', fileRef=ref))
test_files = []
test_sources = []
for path in sorted((ROOT / 'ResimTests').glob('*.swift')):
    relative = str(path.relative_to(ROOT))
    ref = add(relative, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=relative, sourceTree='<group>')
    test_files.append(ref)
    test_sources.append(add(relative+'build', 'PBXBuildFile', fileRef=ref))
fixture = add('fixtures', 'PBXFileReference', lastKnownFileType='folder', path='ResimTests/Fixtures', sourceTree='<group>')
test_files.append(fixture)
fixture_build = add('fixturesbuild', 'PBXBuildFile', fileRef=fixture)
libs = []
lib_refs = []
for library in ['jpeg', 'webpmux', 'webpdemux', 'webp', 'sharpyuv', 'avif', 'aom']:
    path = f'vendor/build/lib/lib{library}.a'
    ref = add(path, 'PBXFileReference', lastKnownFileType='archive.ar', path=path, sourceTree='<group>')
    lib_refs.append(ref)
    libs.append(add(path+'build', 'PBXBuildFile', fileRef=ref))
app_product = add('appproduct', 'PBXFileReference', explicitFileType='wrapper.application', path='Resim.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('testproduct', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='ResimTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
app_group = add('appgroup', 'PBXGroup', name='Resim', children=app_files, sourceTree='<group>')
test_group = add('testgroup', 'PBXGroup', name='ResimTests', children=test_files, sourceTree='<group>')
lib_group = add('libgroup', 'PBXGroup', name='Static codecs', children=lib_refs, sourceTree='<group>')
products = add('products', 'PBXGroup', name='Products', children=[app_product, test_product], sourceTree='<group>')
main_group = add('main', 'PBXGroup', children=[app_group, test_group, lib_group, products], sourceTree='<group>')
app_phase = add('appsources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=app_sources, runOnlyForDeploymentPostprocessing=0)
app_res = add('appresources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)
frameworks = add('frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=libs, runOnlyForDeploymentPostprocessing=0)
test_phase = add('testsources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=test_sources, runOnlyForDeploymentPostprocessing=0)
test_res = add('testresources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[fixture_build], runOnlyForDeploymentPostprocessing=0)
app_settings = dict(PRODUCT_BUNDLE_IDENTIFIER='com.resim.qa.releasehost' if args.isolated_qa else 'com.resim.app', PRODUCT_NAME='$(TARGET_NAME)',
                    GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='.build/Resim-QA-Info.plist' if args.isolated_qa else 'Resim/Info.plist',
                    ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ENABLE_HARDENED_RUNTIME='YES',
                    ENABLE_APP_SANDBOX='NO', CODE_SIGN_STYLE='Manual', CODE_SIGN_IDENTITY='-',
                    SWIFT_OBJC_BRIDGING_HEADER='Resim/Native/Resim-Bridging-Header.h',
                    HEADER_SEARCH_PATHS=['$(SRCROOT)/vendor/build/include', '$(SRCROOT)/Resim/Native'],
                    LIBRARY_SEARCH_PATHS=['$(SRCROOT)/vendor/build/lib'],
                    OTHER_LDFLAGS=['$(inherited)', '-lc++', '-lz'],
                    LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'],
                    ENABLE_TESTABILITY='YES', COMBINE_HIDPI_IMAGES='YES')
test_settings = dict(PRODUCT_BUNDLE_IDENTIFIER='com.resim.qa.releasehost.tests' if args.isolated_qa else 'com.resim.tests', PRODUCT_NAME='$(TARGET_NAME)',
                     GENERATE_INFOPLIST_FILE='YES', CODE_SIGN_IDENTITY='-',
                     TEST_HOST='$(BUILT_PRODUCTS_DIR)/Resim.app/Contents/MacOS/Resim',
                     BUNDLE_LOADER='$(TEST_HOST)',
                     HEADER_SEARCH_PATHS=['$(SRCROOT)/vendor/build/include', '$(SRCROOT)/Resim/Native'],
                     SWIFT_OBJC_BRIDGING_HEADER='Resim/Native/Resim-Bridging-Header.h')
base_settings = dict(MACOSX_DEPLOYMENT_TARGET='14.0', SDKROOT='macosx', SWIFT_VERSION='6.0',
                     SWIFT_STRICT_CONCURRENCY='complete', SWIFT_EMIT_LOC_STRINGS='YES', CLANG_ENABLE_MODULES='YES',
                     CLANG_ENABLE_OBJC_ARC='YES', GCC_C_LANGUAGE_STANDARD='c11',
                     ARCHS=['arm64', 'x86_64'], ONLY_ACTIVE_ARCH='NO',
                     CURRENT_PROJECT_VERSION='12', MARKETING_VERSION='0.2.2',
                     GCC_WARN_ABOUT_RETURN_TYPE='YES_ERROR', CLANG_WARN_DOCUMENTATION_COMMENTS='YES')
app_target = add('apptarget', 'PBXNativeTarget', name='Resim', buildConfigurationList=config_list('app', app_settings), buildPhases=[app_phase, frameworks, app_res], buildRules=[], dependencies=[], productName='Resim', productReference=app_product, productType='com.apple.product-type.application')
proxy = add('proxy', 'PBXContainerItemProxy', containerPortal=ident('project'), proxyType=1, remoteGlobalIDString=app_target, remoteInfo='Resim')
dependency = add('dependency', 'PBXTargetDependency', target=app_target, targetProxy=proxy)
test_target = add('testtarget', 'PBXNativeTarget', name='ResimTests', buildConfigurationList=config_list('test', test_settings), buildPhases=[test_phase, test_res], buildRules=[], dependencies=[dependency], productName='ResimTests', productReference=test_product, productType='com.apple.product-type.bundle.unit-test')
root_id = add('project', 'PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES', 'LastUpgradeCheck':'2710'}, buildConfigurationList=config_list('project', base_settings), compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings=0, knownRegions=['en','es','Base'], mainGroup=main_group, productRefGroup=products, projectDirPath='..' if args.isolated_qa else '', projectRoot='', targets=[app_target, test_target])
project.mkdir(parents=True, exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + q(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=root_id)) + '\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'Resim.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Resim.app" BlueprintName="Resim" ReferencedContainer="container:{scheme_container}"/></BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="ResimTests.xctest" BlueprintName="ResimTests" ReferencedContainer="container:{scheme_container}"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Resim.app" BlueprintName="Resim" ReferencedContainer="container:{scheme_container}"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Resim.app" BlueprintName="Resim" ReferencedContainer="container:{scheme_container}"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated {project.relative_to(ROOT)} (shared Resim scheme).')
