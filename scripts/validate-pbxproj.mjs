// Sanity checks on the generated project file that do not need Xcode:
//  1. every 24-hex object ID that is referenced is also defined
//  2. every object ID is exactly 24 uppercase hex characters
//  3. every referenced source path exists on disk
//  4. braces and parentheses balance
//
// Run: node scripts/validate-pbxproj.mjs

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const text = readFileSync(join(ROOT, "LumaFrame.xcodeproj/project.pbxproj"), "utf8");

const problems = [];

const defined = new Set([...text.matchAll(/^\t\t([0-9A-F]{24}) = \{/gm)].map((m) => m[1]));
// Only tokens that are valid object IDs. A 24-character keyword such as
// `defaultConfigurationName` must not be treated as a reference.
const referenced = new Set([...text.matchAll(/\b([0-9A-F]{24})\b/g)].map((m) => m[1]));

const definedLineIds = new Set([...text.matchAll(/^\t\t(\S+) = \{/gm)].map((m) => m[1]));
for (const id of definedLineIds) {
  if (!/^[0-9A-F]{24}$/.test(id)) {
    problems.push(`object id is not 24 uppercase hex characters: ${id}`);
  }
}
for (const id of referenced) {
  if (!defined.has(id)) {
    problems.push(`referenced but not defined: ${id}`);
  }
}

const paths = [...text.matchAll(/path = ("[^"]+"|[^;]+);/g)].map((m) => m[1].replace(/"/g, "").trim());
for (const path of paths) {
  if (path.includes("/") && !existsSync(join(ROOT, path))) {
    problems.push(`file reference does not exist: ${path}`);
  }
}

const braces = (text.match(/\{/g) || []).length - (text.match(/\}/g) || []).length;
if (braces !== 0) problems.push(`brace imbalance: ${braces}`);
const parens = (text.match(/\(/g) || []).length - (text.match(/\)/g) || []).length;
if (parens !== 0) problems.push(`parenthesis imbalance: ${parens}`);

if (problems.length > 0) {
  for (const problem of problems) console.error(`error: ${problem}`);
  process.exit(1);
}

console.log(
  `ok: ${defined.size} objects, ${referenced.size} references, ${paths.length} file references all resolve`
);
