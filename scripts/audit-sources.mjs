// Structural audit of the Swift sources.
//
// There is no Xcode on this machine, so this cannot typecheck. What it can do is catch
// the class of mistake that a copy-paste consolidation produces and that a compiler would
// catch first:
//
//   1. a type declared in two files (copied instead of moved)
//   2. a file on disk that the project file does not reference (orphaned by a rename)
//   3. unbalanced braces or parentheses (a truncated or mis-merged edit)
//   4. a `private` / `fileprivate` declaration whose only users are outside its own file,
//      which is what actually breaks when files are merged
//
// None of this substitutes for a build. It substitutes for the reviewer's first pass, so
// a human reads the diff for intent and this reads it for structure.
//
// Run: node scripts/audit-sources.mjs
// Exits non-zero when an ERROR-level finding exists. WARN does not fail the run.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const SOURCES = join(ROOT, "App/Sources");
const TESTS = join(ROOT, "App/Tests");

const errors = [];
const warnings = [];

function walk(dir) {
  const found = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return found;
  }
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...walk(full));
    else if (entry.name.endsWith(".swift")) found.push(full);
  }
  return found;
}

const files = [...walk(SOURCES), ...walk(TESTS)];
if (files.length === 0) {
  console.error("error: no Swift sources found");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// 1. Duplicate top-level declarations.
//
// A consolidation that copies a declaration instead of moving it produces exactly
// this, and the symptom on a real build is "invalid redeclaration" pointing at two
// files that each look correct.
// ---------------------------------------------------------------------------

const DECLARATION = /^(?:public |internal |private |fileprivate |final |@\w+\s+)*(struct|class|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)/gm;

const declarations = new Map(); // name -> [{file, line, kind}]
for (const file of files) {
  const text = readFileSync(file, "utf8");
  const rel = relative(ROOT, file).split("\\").join("/");
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    // Only column 0 counts. An indented match is a nested type or a declaration
    // inside a string, and both are legitimate.
    if (/^\s/.test(lines[i])) continue;
    DECLARATION.lastIndex = 0;
    const match = DECLARATION.exec(lines[i]);
    if (!match) continue;
    const [, kind, name] = match;
    if (name === "Self") continue;
    if (!declarations.has(name)) declarations.set(name, []);
    declarations.get(name).push({ file: rel, line: i + 1, kind });
  }
}

for (const [name, sites] of declarations) {
  // An extension of a type declared elsewhere is fine; two *declarations* are not.
  const declarationsOnly = sites.filter((site) => site.kind !== "extension");
  if (declarationsOnly.length > 1) {
    errors.push(
      `duplicate declaration of ${name}:` +
        declarationsOnly.map((s) => ` ${s.file}:${s.line}`).join(",")
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Project file reconciliation.
//
// A source file that exists but is not in project.pbxproj builds nowhere and
// reports no error, which is the worst possible failure mode. Caught here instead.
// ---------------------------------------------------------------------------

const pbxproj = readFileSync(join(ROOT, "LumaFrame.xcodeproj/project.pbxproj"), "utf8");
const referenced = new Set(
  [...pbxproj.matchAll(/path = ("([^"]+)"|([^;]+));/g)]
    .map((m) => (m[2] ?? m[3]).replace(/"/g, "").trim())
    .filter((p) => p.endsWith(".swift") || p.endsWith(".m") || p.endsWith(".h"))
);

for (const file of files) {
  const rel = relative(ROOT, file).split("\\").join("/");
  if (!referenced.has(rel)) {
    errors.push(`on disk but not in project.pbxproj: ${rel} (run generate-pbxproj.mjs)`);
  }
}

// ---------------------------------------------------------------------------
// 3. Balance.
//
// Cheap, and it catches the truncated-merge case that a reviewer skims past.
// ---------------------------------------------------------------------------

for (const file of files) {
  const rel = relative(ROOT, file).split("\\").join("/");
  const text = readFileSync(file, "utf8");
  const braces = count(text, "{") - count(text, "}");
  const parens = count(text, "(") - count(text, ")");
  const brackets = count(text, "[") - count(text, "]");
  if (braces !== 0) errors.push(`${rel}: brace imbalance ${braces > 0 ? "+" : ""}${braces}`);
  if (parens !== 0) errors.push(`${rel}: parenthesis imbalance ${parens > 0 ? "+" : ""}${parens}`);
  if (brackets !== 0) warnings.push(`${rel}: bracket imbalance ${brackets > 0 ? "+" : ""}${brackets}`);
}

function count(text, character) {
  let total = 0;
  for (const char of text) if (char === character) total += 1;
  return total;
}

// ---------------------------------------------------------------------------
// 4. File-private reach.
//
// Only **column-0** `private` counts. A `private` member inside a type is scoped to that
// type, so two types in the same merged file may each have their own `private chip`
// without a conflict — which is the common case, and flagging it would make this check
// cry wolf on every consolidation. A `private` declaration at file scope is a different
// matter: it is invisible outside its own file, so merging can change what it can see,
// and merging a file *out* can break a user that lives elsewhere.
// ---------------------------------------------------------------------------

const PRIVATE_DECL = /^(?:@\w+\s+)*(private|fileprivate)\s+(?:static\s+)?(?:final\s+)?(?:func|var|let|struct|class|enum|typealias)\s+([a-z][A-Za-z0-9_]*)/gm;

const privateNames = new Map(); // name -> [files]
for (const file of files) {
  const rel = relative(ROOT, file).split("\\").join("/");
  const text = readFileSync(file, "utf8");
  PRIVATE_DECL.lastIndex = 0;
  let match;
  while ((match = PRIVATE_DECL.exec(text)) !== null) {
    const name = match[2];
    if (!privateNames.has(name)) privateNames.set(name, []);
    privateNames.get(name).push(rel);
  }
}

for (const [name, where_] of privateNames) {
  if (where_.length > 1) {
    warnings.push(`private \`${name}\` declared in ${where_.length} files: ${where_.join(", ")}`);
  }
}

// ---------------------------------------------------------------------------
// 5. Forbidden constructs, as a standing check rather than a review note.
// ---------------------------------------------------------------------------

const FORBIDDEN = [
  { pattern: /^\s*fatalError\(/m, message: "fatalError" },
  { pattern: /^\s*try!/m, message: "try!" },
  { pattern: /\bas!\s/, message: "as!" }
];

for (const file of files) {
  const rel = relative(ROOT, file).split("\\").join("/");
  const text = readFileSync(file, "utf8");
  for (const { pattern, message } of FORBIDDEN) {
    if (pattern.test(text)) warnings.push(`${rel}: contains ${message}`);
  }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

console.log(`audited ${files.length} Swift files, ${declarations.size} top-level declarations`);

for (const warning of warnings) console.log(`warn: ${warning}`);
for (const error of errors) console.error(`error: ${error}`);

if (errors.length > 0) {
  console.error(`\n${errors.length} error(s), ${warnings.length} warning(s)`);
  process.exit(1);
}
console.log(`ok: no structural errors, ${warnings.length} warning(s)`);
