import fs from 'node:fs';
import path from 'node:path';

// A checkpoint counts as recorded only when evidence/ at the repo root has a file named after it,
// for example evidence/P0-02-real-deny.md. Read at build time.
export function recordedCheckpoints() {
  try {
    const dir = path.join(process.cwd(), '..', 'evidence');
    const ids = fs
      .readdirSync(dir)
      .map((f) => f.match(/^(P0-\d{2})\b/))
      .filter(Boolean)
      .map((m) => m[1]);
    return new Set(ids);
  } catch {
    return new Set();
  }
}
