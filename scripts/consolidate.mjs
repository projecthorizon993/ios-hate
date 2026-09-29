// Mechanically merges Swift files into one, then deletes the originals.
//
// Consolidation done by hand is the one refactor where a reviewer cannot see intent:
// a 20 KB file pasted into a 27 KB file produces a diff that is either "pure
// relocation" or "quietly edited", and the second looks almost identical to the first.
// So it is not done by hand here.
//
// This concatenates whole declarations, dedupes the import block, and deletes the
// sources. The resulting diff is provably pure relocation, because no declaration text
// is touched — which is exactly what the quality gate demands of A3, A4 and A5.
//
// It also reports the one thing that can genuinely break: a `private` or `fileprivate`
// declaration is file-scoped in Swift, so if a merged file's private member is used
// from a file that is *not* in the merge set, the build breaks. That is reported
// before anything is written.
//
// Run:
//   node scripts/consolidate.mjs --out App/Sources/Camera/ProPanel.swift \
//        --title "The Pro and Looks control surface." \
//        --from A=App/Sources/Camera/ProDial.swift \
//        --from B=App/Sources/Camera/ProChipBar.swift
//
//   --order A,B   declaration order, top to bottom
//   --dry-run     report and do not write

import { existsSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return fallback;
  const value = process.argv[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`--${name} needs a value`);
  }
  return value;
}

function arguments_(name) {
  return process.argv
    .map((value, index) => ({ value, index }))
    .filter((entry) => entry.value === `--${name}`)
    .map((entry) => process.argv[entry.index + 1])
    .filter(Boolean);
}

const out = argument("out");
if (!out) throw new Error("--out is required");

const inputs = arguments_("from").map((entry) => {
  const [key, path] = entry.split("=");
  if (!key || !path) throw new Error(`--from must be KEY=path, got "${entry}"`);
  return { key, path };
});
if (inputs.length < 2) throw new Error("--from needs at least two entries");

const order = (argument("order", inputs.map((i) => i.key).join(","))).split(",");
const title = argument("title", "Consolidated module.");
const note = argument("note", "");
const dryRun = process.argv.includes("--dry-run");

const ordered = order.map((key) => {
  const found = inputs.find((input) => input.key === key);
  if (!found) throw new Error(`--order names an unknown key: ${key}`);
  return found;
});

for (const input of ordered) {
  if (!existsSync(join(ROOT, input.path))) {
    throw new Error(`input does not exist: ${input.path}`);
  }
}

// --- Read, split imports from body ----------------------------------------

const IMPORT = /^import\s+.*$/gm;

const parts = ordered.map((input) => {
  const text = readFileSync(join(ROOT, input.path), "utf8");
  const imports = text.match(IMPORT) ?? [];
  const body = text.replace(IMPORT, "").replace(/^\n+/, "").replace(/\n+$/, "");
  return { ...input, text, imports, body };
});

const allImports = [];
for (const part of parts) {
  for (const line of part.imports) {
    if (!allImports.includes(line)) allImports.push(line);
  }
}

// --- Safety: file-private reach --------------------------------------------
//
// Only **column-0** `private` is a hazard. A `private` member inside a type is scoped to
// that type, so two types merged into one file may both have a `private chip` and both
// still compile — flagging that would refuse every legitimate merge. A `private`
// declaration at file scope is invisible outside its own file, so it is the one whose
// reach a merge can change. Any such declaration used from a file outside the merge set
// is a build break waiting to happen, and the merge is refused.

const PRIVATE_DECL = /^(?:@\w+\s+)*(private|fileprivate)\s+(?:static\s+)?(?:final\s+)?(?:func|var|let|struct|class|enum|typealias)\s+([a-z][A-Za-z0-9_]*)/gm;

const findings = [];
const setPaths = new Set(parts.map((part) => part.path));
for (const part of parts) {
  const names = [];
  PRIVATE_DECL.lastIndex = 0;
  let match;
  while ((match = PRIVATE_DECL.exec(part.text)) !== null) names.push(match[2]);
  if (names.length === 0) continue;

  // Scan every Swift file in the repo for uses of those names.
  for (const candidate of listSwiftFiles()) {
    if (setPaths.has(candidate)) continue;
    const text = readFileSync(join(ROOT, candidate), "utf8");
    for (const name of names) {
      const used = new RegExp(`\\b${name}\\b`).test(text);
      if (used) findings.push(`${candidate} uses \`${name}\`, which is private in ${part.path}`);
    }
  }
}

function listSwiftFiles(dir = join(ROOT, "App")) {
  const found = [];
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return found;
  }
  for (const name of entries) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) found.push(...listSwiftFiles(full));
    else if (name.endsWith(".swift")) found.push(relativeToRoot(full));
  }
  return found;
}

function relativeToRoot(path) {
  return relative(ROOT, path).split("\\").join("/");
}

// --- Compose --------------------------------------------------------------

const banner = (part) => `// MARK: - ${part.key} (was ${part.path})`;

const header = [
  "// " + title,
  note ? "//" : null,
  note ? "// " + note : null,
  "//",
  "// Merged mechanically by scripts/consolidate.mjs. Declarations were moved whole and",
  "// nothing was edited; see the commit message for the reasoning."
]
  .filter((line) => line !== null)
  .join("\n");

const body = parts.map((part) => `${banner(part)}\n${part.body}`).join("\n\n");

// Sections are joined with exactly one blank line, and nothing is collapsed
// afterwards. A blanket `replace(/\n{3,}/g, ...)` would also rewrite blank lines
// inside a multi-line string literal, which is a silent content change in exactly the
// files that are supposed to be untouched.
const output = `${header}\n\n${allImports.join("\n")}\n\n${body}\n`;

if (findings.length > 0) {
  console.error("error: private members are used from outside the merge set:");
  for (const finding of findings) console.error(`  ${finding}`);
  process.exit(1);
}

console.log(`merging ${parts.length} files into ${out}`);
console.log(`  imports: ${allImports.length}`);
for (const part of parts) {
  console.log(`  ${part.path}  ${part.body.split("\n").length} lines`);
}

if (dryRun) {
  console.log("\ndry run, nothing written");
  process.exit(0);
}

writeFileSync(join(ROOT, out), output, "utf8");
for (const part of parts) {
  if (part.path === out) continue;
  rmSync(join(ROOT, part.path));
}
console.log(`\nwrote ${out} and removed ${parts.length - 1} source(s)`);
