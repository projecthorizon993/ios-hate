import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Ad-hoc brace/paren balance check for Swift sources. Not a compiler, but it catches a
// truncated or mis-spliced file long before CI does.
function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith(".swift")) out.push(full);
  }
  return out;
}

const QUOTE = String.fromCharCode(34);
const BACKSLASH = String.fromCharCode(92);
const NEWLINE = String.fromCharCode(10);
const SLASH = String.fromCharCode(47);

function balance(path) {
  const text = readFileSync(path, "utf8");
  let depth = 0;
  let lowest = 0;
  let inLineComment = false;
  let quote = null;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    const n = text[i + 1];
    if (inLineComment) {
      if (c === NEWLINE) inLineComment = false;
      continue;
    }
    if (quote) {
      if (c === BACKSLASH) { i += 1; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === SLASH && n === SLASH) { inLineComment = true; i += 1; continue; }
    if (c === QUOTE || c === String.fromCharCode(39)) { quote = c; continue; }
    if (c === "{") depth += 1;
    if (c === "}") { depth -= 1; if (depth < lowest) lowest = depth; }
  }
  return { depth, lowest, unterminated: quote !== null };
}

let bad = 0;
for (const file of walk("App")) {
  const { depth, lowest, unterminated } = balance(file);
  const ok = depth === 0 && lowest === 0 && !unterminated;
  if (!ok) bad += 1;
  console.log(`${ok ? "ok  " : "BAD "} ${file} depth=${depth} lowest=${lowest} unterminatedString=${unterminated}`);
}
process.exit(bad === 0 ? 0 : 1);
