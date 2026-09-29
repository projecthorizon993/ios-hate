// Fails the build if a Swift source file is not valid UTF-8, or contains a byte that is
// part of no valid sequence.
//
// Why this exists: two em-dashes in one file were corrupted into a lone 0x97 during a
// PowerShell rewrite, and the only symptom was
// "error: invalid UTF-8 found in source file" pointing at a *comment*. Two CI runs went
// into reading that as a compiler or toolchain problem before the byte was found. The
// compiler is right and the file really is malformed; what is wrong is that a text file
// can silently end up half-encoded and nothing notices until a build on another machine.
//
// So this checks the actual property, and names the file and the byte offset, so the
// failure is unambiguous and local rather than a remote mystery.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, extname, relative } from "node:path";

const root = process.cwd();
const sourceDirs = ["App/Sources", "App/Tests"];

function* swiftFiles(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      yield* swiftFiles(full);
    } else if (extname(full) === ".swift") {
      yield full;
    }
  }
}

const problems = [];
let checked = 0;

/**
 * The offset of the first byte that cannot begin a valid UTF-8 sequence.
 *
 * Walking the encoding by hand rather than binary-searching with a decoder, because a
 * window-based probe reports the start of the *window* rather than the start of the bad
 * sequence, which pointed at a space several bytes earlier than the actual corruption.
 * That is worse than no offset at all, because it sends a reader to the wrong line.
 */
function offsetOfFirstBadByte(bytes) {
  let i = 0;
  while (i < bytes.length) {
    const lead = bytes[i];
    let length;
    if (lead < 0x80) {
      i += 1;
      continue;
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      length = 2;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      length = 3;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      length = 4;
    } else {
      // 0x80-0xBF is a continuation byte with no lead, 0xC0/0xC1 are overlong leads and
      // 0xF5-0xFF are out of range. All are invalid exactly here.
      return i;
    }

    if (i + length > bytes.length) {
      return i; // Truncated at end of file.
    }
    for (let k = 1; k < length; k += 1) {
      if ((bytes[i + k] & 0xc0) !== 0x80) {
        return i + k;
      }
    }
    i += length;
  }
  return -1;
}

for (const dir of sourceDirs) {
  for (const file of swiftFiles(join(root, dir))) {
    checked += 1;
    const bytes = readFileSync(file);

    // A strict UTF-8 decode is the primary check: it rejects truncated sequences, lone
    // continuation bytes, overlong encodings and surrogate halves, which is everything
    // that can go wrong here.
    try {
      new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch {
      const name = relative(root, file);
      problems.push(`${name}: not valid UTF-8 (first bad byte at offset ${offsetOfFirstBadByte(bytes)}, 0x${bytes[offsetOfFirstBadByte(bytes)].toString(16)})`);
      continue;
    }

    // Valid UTF-8 can still contain a byte order mark or a stray replacement character,
    // both of which are legal but are always a mistake in source.
    const text = new TextDecoder("utf-8").decode(bytes);
    if (text.includes("�")) {
      problems.push(`${relative(root, file)}: contains a Unicode replacement character`);
    }
    if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      problems.push(`${relative(root, file)}: starts with a UTF-8 byte order mark`);
    }
  }
}

if (problems.length > 0) {
  console.error("Swift source encoding problems:");
  for (const problem of problems) {
    console.error(`  ${problem}`);
  }
  console.error("");
  console.error("A Swift file that is not valid UTF-8 fails to compile with an error that");
  console.error("points at a comment and mentions nothing about encoding. Fix the file, or");
  console.error("rewrite it with a UTF-8-aware editor rather than a shell string replace.");
  process.exit(1);
}

console.log(`ok: ${checked} Swift files are valid UTF-8 with no BOM`);
