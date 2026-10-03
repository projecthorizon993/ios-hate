// Regenerates LumaFrame.xcodeproj/project.pbxproj from what is actually on disk.
//
// Why this exists: the project file uses explicit PBXFileReference entries, so adding
// a Swift file by hand means editing four separate sections. Doing that by hand is
// where mistakes happen. This script enumerates the sources, assigns deterministic
// object IDs from a hash of each path, and rewrites the file. Running it twice
// produces identical output, so a diff only ever shows real source changes.
//
// Usage:  node scripts/generate-pbxproj.mjs [--check]
//
//   --check  verify the project file matches disk and every referenced file exists,
//            without writing. Exits non-zero on drift, which is what CI should call.

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const PROJECT_DIR = join(ROOT, "LumaFrame.xcodeproj");
const PBXPROJ = join(PROJECT_DIR, "project.pbxproj");

// Build settings that must not drift. Kept here, not in the template, so a change is
// an explicit edit in one place.
const BUNDLE_ID = "com.example.LumaFrame";
const TEST_BUNDLE_ID = "com.example.LumaFrameTests";
// iOS 18.0 is the floor. Raised from 17.0 because Vision's
// `supportedOutputPixelFormats()` is 18.0+, and the app deliberately probes the real
// capability surface rather than a guessed one. Every device in the test matrix
// (iPhone 11 Pro Max, iPhone SE 2022, Galaxy S21 Ultra) runs 18 or newer, so nothing
// on the matrix is lost.
const DEPLOYMENT_TARGET = "18.0";
const SWIFT_VERSION = "5.9";
const BRIDGING_HEADER = "App/Sources/Support/LumaFrame-Bridging-Header.h";
const INFO_PLIST = "App/Resources/Info.plist";
const ASSET_CATALOG = "App/Resources/Assets.xcassets";

const SOURCE_DIRS = ["App/Sources"];
const TEST_DIRS = ["App/Tests"];

// Fixed object IDs, matching the previous project so the diff stays small.
const ID = {
  project: "A10000000000000000000001",
  projectConfigList: "A10000000000000000000002",
  mainGroup: "A10000000000000000000003",
  productsGroup: "A10000000000000000000004",
  appTarget: "A10000000000000000000005",
  testTarget: "A10000000000000000000006",
  projectDebug: "A10000000000000000000007",
  projectRelease: "A10000000000000000000008",
  appDebug: "A10000000000000000000009",
  appRelease: "A10000000000000000000035",
  appConfigList: "A10000000000000000000026",
  testConfigList: "A10000000000000000000030",
  testDebug: "A10000000000000000000054",
  testRelease: "A10000000000000000000055",
  appSources: "A10000000000000000000027",
  appFrameworks: "A10000000000000000000028",
  appResources: "A10000000000000000000029",
  testSources: "A10000000000000000000031",
  testFrameworks: "A10000000000000000000032",
  testResources: "A10000000000000000000033",
  testDependency: "A10000000000000000000034",
  containerProxy: "A10000000000000000000057",
  appProduct: "A10000000000000000000024",
  testProduct: "A10000000000000000000025",
  assetCatalogRef: "A10000000000000000000058",
  assetCatalogBuild: "A10000000000000000000053"
};

const FILE_TYPES = {
  ".swift": "sourcecode.swift",
  ".m": "sourcecode.c.objc",
  ".c": "sourcecode.c.c",
  ".h": "sourcecode.c.h"
};

/**
 * Deterministic 24-character uppercase-hex object ID, so regeneration is stable.
 * The first character is role-scoped (file reference vs build file) and the rest comes
 * from a hash of the path. Xcode conventionally uses hex-only IDs.
 */
function objectId(role, path) {
  const prefix = { R: "A", B: "C", T: "D" }[role];
  if (!prefix) throw new Error(`unknown object role: ${role}`);
  const digest = createHash("sha1").update(`${role}:${path}`).digest("hex").toUpperCase();
  return (prefix + digest).slice(0, 24);
}

function walk(dir, extensions, found = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return found;
  }
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, extensions, found);
    } else if (extensions.includes(extensionOf(entry.name))) {
      found.push(relative(ROOT, full).split(sep).join("/"));
    }
  }
  return found;
}

function extensionOf(name) {
  const index = name.lastIndexOf(".");
  return index === -1 ? "" : name.slice(index);
}

/** A `.h` is referenced by the project but only compiled when it is the bridging header. */
function collect() {
  const compiled = [];
  const headers = [];
  for (const dir of SOURCE_DIRS) {
    for (const path of walk(join(ROOT, dir), [".swift", ".m", ".c", ".h"])) {
      (extensionOf(path) === ".h" ? headers : compiled).push(path);
    }
  }
  const tests = [];
  for (const dir of TEST_DIRS) {
    for (const path of walk(join(ROOT, dir), [".swift"])) {
      tests.push(path);
    }
  }

  const bridging = BRIDGING_HEADER;
  if (!headers.includes(bridging)) {
    throw new Error(`bridging header is missing on disk: ${bridging}`);
  }
  for (const required of [INFO_PLIST, ASSET_CATALOG]) {
    if (!exists(join(ROOT, required))) {
      throw new Error(`required resource is missing on disk: ${required}`);
    }
  }

  return { compiled, headers, tests };
}

function exists(path) {
  try {
    statSync(path);
    return true;
  } catch {
    return false;
  }
}

function quote(value) {
  return /[^A-Za-z0-9_./]/.test(value) ? `"${value}"` : value;
}

function generate() {
  const { compiled, headers, tests } = collect();

  const fileRefs = []; // { id, path, type }
  const appBuildFiles = []; // { id, refId }
  const testBuildFiles = [];

  for (const path of [...compiled, ...headers]) {
    const type = FILE_TYPES[extensionOf(path)];
    if (!type) throw new Error(`no file type for ${path}`);
    fileRefs.push({ id: objectId("R", path), path, type });
    if (extensionOf(path) !== ".h") {
      appBuildFiles.push({ id: objectId("B", path), refId: objectId("R", path) });
    }
  }
  for (const path of tests) {
    fileRefs.push({ id: objectId("R", path), path, type: "sourcecode.swift" });
    testBuildFiles.push({ id: objectId("T", path), refId: objectId("R", path) });
  }

  const out = [];
  const p = (line = "") => out.push(line);

  p("{");
  p("\tarchiveVersion = 1;");
  p("\tclasses = {");
  p("\t};");
  p("\tobjectVersion = 56;");
  p("\tobjects = {");

  // PBXProject
  p(`\t\t${ID.project} = {`);
  p("\t\t\tisa = PBXProject;");
  p("\t\t\tattributes = {");
  p("\t\t\t\tLastUpgradeCheck = 1600;");
  p("\t\t\t};");
  p(`\t\t\tbuildConfigurationList = ${ID.projectConfigList};`);
  p('\t\t\tcompatibilityVersion = "Xcode 14.0";');
  p("\t\t\tdevelopmentRegion = en;");
  p("\t\t\thasScannedForEncodings = 0;");
  p("\t\t\tknownRegions = (");
  p("\t\t\t\ten,");
  p("\t\t\t\tBase");
  p("\t\t\t);");
  p(`\t\t\tmainGroup = ${ID.mainGroup};`);
  p("\t\t\tpackageReferences = (");
  p("\t\t\t);");
  p(`\t\t\tproductRefGroup = ${ID.productsGroup};`);
  p('\t\t\tprojectDirPath = "";');
  p('\t\t\tprojectRoot = "";');
  p("\t\t\ttargets = (");
  p(`\t\t\t\t${ID.appTarget},`);
  p(`\t\t\t\t${ID.testTarget}`);
  p("\t\t\t);");
  p("\t\t};");

  // Project configuration list
  p(`\t\t${ID.projectConfigList} = {`);
  p("\t\t\tisa = XCConfigurationList;");
  p("\t\t\tbuildConfigurations = (");
  p(`\t\t\t\t${ID.projectDebug},`);
  p(`\t\t\t\t${ID.projectRelease}`);
  p("\t\t\t);");
  p("\t\t\tdefaultConfigurationIsVisible = 0;");
  p("\t\t\tdefaultConfigurationName = Release;");
  p("\t\t};");

  // Main group: every source file reference is flat, as in the previous project. The
  // built products are NOT listed here: they already live in the products group, and a
  // file reference in two groups makes Xcode warn about a malformed project and silently
  // keep only one of the memberships.
  p(`\t\t${ID.mainGroup} = {`);
  p("\t\t\tisa = PBXGroup;");
  p("\t\t\tchildren = (");
  for (const ref of fileRefs) p(`\t\t\t\t${ref.id},`);
  p(`\t\t\t\t${ID.assetCatalogRef}`);
  p("\t\t\t);");
  p("\t\t\tname = LumaFrame;");
  p('\t\t\tsourceTree = "<group>";');
  p("\t\t};");

  // Products group
  p(`\t\t${ID.productsGroup} = {`);
  p("\t\t\tisa = PBXGroup;");
  p("\t\t\tchildren = (");
  p(`\t\t\t\t${ID.appProduct},`);
  p(`\t\t\t\t${ID.testProduct}`);
  p("\t\t\t);");
  p("\t\t\tname = Products;");
  p('\t\t\tsourceTree = "<group>";');
  p("\t\t};");

  // App target
  p(`\t\t${ID.appTarget} = {`);
  p("\t\t\tisa = PBXNativeTarget;");
  p(`\t\t\tbuildConfigurationList = ${ID.appConfigList};`);
  p("\t\t\tbuildPhases = (");
  p(`\t\t\t\t${ID.appSources},`);
  p(`\t\t\t\t${ID.appFrameworks},`);
  p(`\t\t\t\t${ID.appResources}`);
  p("\t\t\t);");
  p("\t\t\tbuildRules = (");
  p("\t\t\t);");
  p("\t\t\tdependencies = (");
  p("\t\t\t);");
  p("\t\t\tname = LumaFrame;");
  p("\t\t\tpackageProductDependencies = (");
  p("\t\t\t);");
  p("\t\t\tproductName = LumaFrame;");
  p(`\t\t\tproductReference = ${ID.appProduct};`);
  p('\t\t\tproductType = "com.apple.product-type.application";');
  p("\t\t};");

  // Test target
  p(`\t\t${ID.testTarget} = {`);
  p("\t\t\tisa = PBXNativeTarget;");
  p(`\t\t\tbuildConfigurationList = ${ID.testConfigList};`);
  p("\t\t\tbuildPhases = (");
  p(`\t\t\t\t${ID.testSources},`);
  p(`\t\t\t\t${ID.testFrameworks},`);
  p(`\t\t\t\t${ID.testResources}`);
  p("\t\t\t);");
  p("\t\t\tbuildRules = (");
  p("\t\t\t);");
  p("\t\t\tdependencies = (");
  p(`\t\t\t\t${ID.testDependency}`);
  p("\t\t\t);");
  p("\t\t\tname = LumaFrameTests;");
  p("\t\t\tproductName = LumaFrameTests;");
  p(`\t\t\tproductReference = ${ID.testProduct};`);
  p('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";');
  p("\t\t};");

  // Project build settings
  for (const [id, name] of [[ID.projectDebug, "Debug"], [ID.projectRelease, "Release"]]) {
    p(`\t\t${id} = {`);
    p("\t\t\tisa = XCBuildConfiguration;");
    p("\t\t\tbuildSettings = {");
    p("\t\t\t\tCLANG_ENABLE_MODULES = YES;");
    p(`\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = ${DEPLOYMENT_TARGET};`);
    p("\t\t\t\tSDKROOT = iphoneos;");
    p(`\t\t\t\tSWIFT_VERSION = ${SWIFT_VERSION};`);
    p("\t\t\t};");
    p(`\t\t\tname = ${name};`);
    p("\t\t};");
  }

  // App build settings
  for (const [id, name, testability] of [
    [ID.appDebug, "Debug", "YES"],
    [ID.appRelease, "Release", null]
  ]) {
    p(`\t\t${id} = {`);
    p("\t\t\tisa = XCBuildConfiguration;");
    p("\t\t\tbuildSettings = {");
    p("\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;");
    p("\t\t\t\tCODE_SIGN_STYLE = Automatic;");
    p("\t\t\t\tCURRENT_PROJECT_VERSION = 1;");
    if (testability) p(`\t\t\t\tENABLE_TESTABILITY = ${testability};`);
    p("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;");
    p(`\t\t\t\tINFOPLIST_FILE = ${quote(INFO_PLIST)};`);
    p("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (");
    p('\t\t\t\t\t"$(inherited)",');
    p('\t\t\t\t\t"@executable_path/Frameworks"');
    p("\t\t\t\t);");
    // Stamped into Info.plist so a log file says which commit produced it. `local` is the
    // default so a build that is not going through CI still gets a defined value rather than
    // an empty key, and CI overrides it on the xcodebuild command line.
    p('\t\t\t\tLUMAFRAME_BUILD = local;');
    p("\t\t\t\tMARKETING_VERSION = 1.0;");
    p(`\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID};`);
    p('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";');
    p("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;");
    p(`\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = ${quote(BRIDGING_HEADER)};`);
    p("\t\t\t\tTARGETED_DEVICE_FAMILY = 1;");
    p("\t\t\t};");
    p(`\t\t\tname = ${name};`);
    p("\t\t};");
  }

  // Test build settings
  for (const [id, name] of [[ID.testDebug, "Debug"], [ID.testRelease, "Release"]]) {
    p(`\t\t${id} = {`);
    p("\t\t\tisa = XCBuildConfiguration;");
    p("\t\t\tbuildSettings = {");
    p('\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";');
    p("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;");
    p('\t\t\t\tINFOPLIST_FILE = "";');
    p(`\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = ${TEST_BUNDLE_ID};`);
    p('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";');
    p(`\t\t\t\tSWIFT_VERSION = ${SWIFT_VERSION};`);
    p("\t\t\t\tTARGETED_DEVICE_FAMILY = 1;");
    p('\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/LumaFrame.app/LumaFrame";');
    p("\t\t\t};");
    p(`\t\t\tname = ${name};`);
    p("\t\t};");
  }

  // Products
  p(`\t\t${ID.appProduct} = {`);
  p("\t\t\tisa = PBXFileReference;");
  p("\t\t\texplicitFileType = wrapper.application;");
  p("\t\t\tincludeInIndex = 0;");
  p("\t\t\tpath = LumaFrame.app;");
  p("\t\t\tsourceTree = BUILT_PRODUCTS_DIR;");
  p("\t\t};");
  p(`\t\t${ID.testProduct} = {`);
  p("\t\t\tisa = PBXFileReference;");
  p("\t\t\texplicitFileType = wrapper.cfbundle;");
  p("\t\t\tincludeInIndex = 0;");
  p("\t\t\tpath = LumaFrameTests.xctest;");
  p("\t\t\tsourceTree = BUILT_PRODUCTS_DIR;");
  p("\t\t};");

  // Configuration lists
  p(`\t\t${ID.appConfigList} = {`);
  p("\t\t\tisa = XCConfigurationList;");
  p("\t\t\tbuildConfigurations = (");
  p(`\t\t\t\t${ID.appDebug},`);
  p(`\t\t\t\t${ID.appRelease}`);
  p("\t\t\t);");
  p("\t\t\tdefaultConfigurationIsVisible = 0;");
  p("\t\t\tdefaultConfigurationName = Release;");
  p("\t\t};");
  p(`\t\t${ID.testConfigList} = {`);
  p("\t\t\tisa = XCConfigurationList;");
  p("\t\t\tbuildConfigurations = (");
  p(`\t\t\t\t${ID.testDebug},`);
  p(`\t\t\t\t${ID.testRelease}`);
  p("\t\t\t);");
  p("\t\t\tdefaultConfigurationIsVisible = 0;");
  p("\t\t\tdefaultConfigurationName = Release;");
  p("\t\t};");

  // Build phases
  p(`\t\t${ID.appSources} = {`);
  p("\t\t\tisa = PBXSourcesBuildPhase;");
  p("\t\t\tbuildActionMask = 2147483647;");
  p("\t\t\tfiles = (");
  for (const file of appBuildFiles) p(`\t\t\t\t${file.id},`);
  p("\t\t\t);");
  p("\t\t\trunOnlyForDeploymentPostprocessing = 0;");
  p("\t\t};");

  p(`\t\t${ID.testSources} = {`);
  p("\t\t\tisa = PBXSourcesBuildPhase;");
  p("\t\t\tbuildActionMask = 2147483647;");
  p("\t\t\tfiles = (");
  for (const file of testBuildFiles) p(`\t\t\t\t${file.id},`);
  p("\t\t\t);");
  p("\t\t\trunOnlyForDeploymentPostprocessing = 0;");
  p("\t\t};");

  for (const id of [ID.appFrameworks, ID.testFrameworks]) {
    p(`\t\t${id} = {`);
    p("\t\t\tisa = PBXFrameworksBuildPhase;");
    p("\t\t\tbuildActionMask = 2147483647;");
    p("\t\t\tfiles = (");
    p("\t\t\t);");
    p("\t\t\trunOnlyForDeploymentPostprocessing = 0;");
    p("\t\t};");
  }

  p(`\t\t${ID.appResources} = {`);
  p("\t\t\tisa = PBXResourcesBuildPhase;");
  p("\t\t\tbuildActionMask = 2147483647;");
  p("\t\t\tfiles = (");
  p(`\t\t\t\t${ID.assetCatalogBuild},`);
  p("\t\t\t);");
  p("\t\t\trunOnlyForDeploymentPostprocessing = 0;");
  p("\t\t};");

  p(`\t\t${ID.testResources} = {`);
  p("\t\t\tisa = PBXResourcesBuildPhase;");
  p("\t\t\tbuildActionMask = 2147483647;");
  p("\t\t\tfiles = (");
  p("\t\t\t);");
  p("\t\t\trunOnlyForDeploymentPostprocessing = 0;");
  p("\t\t};");

  p(`\t\t${ID.testDependency} = {`);
  p("\t\t\tisa = PBXTargetDependency;");
  p(`\t\t\ttarget = ${ID.appTarget};`);
  p(`\t\t\ttargetProxy = ${ID.containerProxy};`);
  p("\t\t};");

  p(`\t\t${ID.containerProxy} = {`);
  p("\t\t\tisa = PBXContainerItemProxy;");
  p(`\t\t\tcontainerPortal = ${ID.project};`);
  p("\t\t\tproxyType = 1;");
  p(`\t\t\tremoteGlobalIDString = ${ID.appTarget};`);
  p("\t\t\tremoteInfo = LumaFrame;");
  p("\t\t};");

  // File references and build files
  for (const ref of fileRefs) {
    p(`\t\t${ref.id} = {`);
    p("\t\t\tisa = PBXFileReference;");
    p(`\t\t\tlastKnownFileType = ${ref.type};`);
    p(`\t\t\tpath = ${quote(ref.path)};`);
    p('\t\t\tsourceTree = "<group>";');
    p("\t\t};");
  }
  for (const file of appBuildFiles) {
    p(`\t\t${file.id} = {`);
    p("\t\t\tisa = PBXBuildFile;");
    p(`\t\t\tfileRef = ${file.refId};`);
    p("\t\t};");
  }
  for (const file of testBuildFiles) {
    p(`\t\t${file.id} = {`);
    p("\t\t\tisa = PBXBuildFile;");
    p(`\t\t\tfileRef = ${file.refId};`);
    p("\t\t};");
  }
  p(`\t\t${ID.assetCatalogBuild} = {`);
  p("\t\t\tisa = PBXBuildFile;");
  p(`\t\t\tfileRef = ${ID.assetCatalogRef};`);
  p("\t\t};");
  p(`\t\t${ID.assetCatalogRef} = {`);
  p("\t\t\tisa = PBXFileReference;");
  p("\t\t\tlastKnownFileType = folder.assetcatalog;");
  p(`\t\t\tpath = ${quote(ASSET_CATALOG)};`);
  p('\t\t\tsourceTree = "<group>";');
  p("\t\t};");

  p("\t};");
  p(`\trootObject = ${ID.project};`);
  p("}");
  p("");

  return out.join("\n");
}

/** Every path mentioned as a PBXFileReference must exist, or Xcode shows a red file. */
function verify(paths) {
  const problems = [];
  for (const path of paths) {
    if (!exists(join(ROOT, path))) problems.push(`missing on disk: ${path}`);
  }
  return problems;
}

const check = process.argv.includes("--check");
const generated = generate();
const { compiled, headers, tests } = collect();

const problems = verify([...compiled, ...headers, ...tests, INFO_PLIST, ASSET_CATALOG]);
if (problems.length > 0) {
  for (const problem of problems) console.error(`error: ${problem}`);
  process.exit(1);
}

if (check) {
  // Compared with line endings normalised. This repository is checked out on Windows,
  // where git rewrites LF to CRLF in the working copy, so a freshly created worktree has
  // a CRLF `project.pbxproj` while the generator emits LF. Byte comparison would report
  // the file as stale in every worktree and in CI, which is exactly the false failure
  // that would stop an agent from finishing. The content is what matters here, not the
  // platform's line-ending convention.
  const current = readFileSync(PBXPROJ, "utf8").replace(/\r\n/g, "\n");
  if (current !== generated) {
    console.error("error: project.pbxproj is out of date. Run: node scripts/generate-pbxproj.mjs");
    process.exit(1);
  }
  console.log(`ok: project.pbxproj matches disk (${compiled.length} app sources, ${tests.length} test sources)`);
} else {
  writeFileSync(PBXPROJ, generated, "utf8");
  console.log(
    `wrote ${relative(ROOT, PBXPROJ)}: ` +
      `${compiled.length} app sources (${headers.length} headers), ${tests.length} test sources`
  );
}
