#!/usr/bin/env python3
"""Generate the dependency-free Xcode project with stable object identifiers."""
import hashlib
from pathlib import Path

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

objects = []
def obj(name, content):
    objects.append(f'{uid(name)} = {{ {content} }};')
    return uid(name)

sources = sorted(Path('Mailern').rglob('*.swift'))
refs, builds = [], []
for path in sources:
    ref = obj(str(path), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    builds.append(obj('build'+str(path), f'isa = PBXBuildFile; fileRef = {ref};'))
icon = obj('icon', 'isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = Mailern/AppIcon.icon; sourceTree = SOURCE_ROOT;')
refs.append(icon)
iconbuild = obj('buildicon', f'isa = PBXBuildFile; fileRef = {icon};')
resources = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({iconbuild},); runOnlyForDeploymentPostprocessing = 0;')
app = obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Mailern.app; sourceTree = BUILT_PRODUCTS_DIR;')
testref = obj('uitestsource', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/MailernUITests.swift; sourceTree = SOURCE_ROOT;')
refs.append(testref)
testbuild = obj('uitestbuild', f'isa = PBXBuildFile; fileRef = {testref};')
testproduct = obj('uitestproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = MailernUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
unitref = obj('unitsource', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/ComposerEditorTests.swift; sourceTree = SOURCE_ROOT;')
refs.append(unitref)
unitbuild = obj('unitbuild', f'isa = PBXBuildFile; fileRef = {unitref};')
unitproduct = obj('unitproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = MailernTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = ({app},{testproduct},{unitproduct},); name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({",".join(refs+[products])},); sourceTree = "<group>";')
phase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for scope in ['project', 'target', 'uitest', 'unittest']:
    configs = []
    for config in ['Debug','Release']:
        settings = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 18.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES;'
        settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; ENABLE_TESTABILITY = YES;' if config == 'Debug' else ' SWIFT_OPTIMIZATION_LEVEL = "-O";'
        if scope == 'target':
            settings += ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; PRODUCT_BUNDLE_IDENTIFIER = com.example.mailern; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = Mailern; INFOPLIST_FILE = Mailern/Info.plist; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; MARKETING_VERSION = 0.4.4; CURRENT_PROJECT_VERSION = 23;'
        if scope == 'uitest':
            settings += ' PRODUCT_BUNDLE_IDENTIFIER = com.example.mailern.uitests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = Mailern; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; ENABLE_TESTING_SEARCH_PATHS = YES;'
        if scope == 'unittest':
            settings += ' PRODUCT_BUNDLE_IDENTIFIER = com.example.mailern.tests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Mailern.app/Mailern"; BUNDLE_LOADER = "$(TEST_HOST)"; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic;'
        configs.append(obj(scope+config, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {config};'))
    obj(scope+'configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({phase},{frameworks},{resources},); buildRules = (); dependencies = (); name = Mailern; productName = Mailern; productReference = {app}; productType = "com.apple.product-type.application";')
testphase = obj('uitestsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuild},); runOnlyForDeploymentPostprocessing = 0;')
testframeworks = obj('uitestframeworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
proxy = obj('uitestproxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = Mailern;')
dependency = obj('uitestdependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {proxy};')
obj('uitesttarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("uitestconfigs")}; buildPhases = ({testphase},{testframeworks},); buildRules = (); dependencies = ({dependency},); name = MailernUITests; productName = MailernUITests; productReference = {testproduct}; productType = "com.apple.product-type.bundle.ui-testing";')
unitphase = obj('unitsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({unitbuild},); runOnlyForDeploymentPostprocessing = 0;')
unitframeworks = obj('unitframeworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('unittarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("unittestconfigs")}; buildPhases = ({unitphase},{unitframeworks},); buildRules = (); dependencies = ({dependency},); name = MailernTests; productName = MailernTests; productReference = {unitproduct}; productType = "com.apple.product-type.bundle.unit-test";')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},{uid("uitesttarget")},{uid("unittarget")},);')
Path('Mailern.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
Path('Mailern.xcodeproj/xcshareddata/xcschemes/Mailern.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Mailern.app" BlueprintName="Mailern" ReferencedContainer="container:Mailern.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('uitesttarget')}" BuildableName="MailernUITests.xctest" BlueprintName="MailernUITests" ReferencedContainer="container:Mailern.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('unittarget')}" BuildableName="MailernTests.xctest" BlueprintName="MailernTests" ReferencedContainer="container:Mailern.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="Mailern.app" BlueprintName="Mailern" ReferencedContainer="container:Mailern.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
