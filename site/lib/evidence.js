import fs from 'node:fs';
import path from 'node:path';

// Status is read from the repository when the site builds. Nothing here is typed by hand.
const ROOT = path.join(process.cwd(), '..');

function evidenceFiles() {
  try {
    return fs.readdirSync(path.join(ROOT, 'evidence')).filter((f) => /^P\d-\d{2}-.+\.md$/.test(f));
  } catch {
    return [];
  }
}

// A checkpoint counts as recorded only when evidence/ has a file named after it,
// for example evidence/P0-02-real-deny-linux.md.
export function recordedCheckpoints() {
  return new Set(evidenceFiles().map((f) => f.slice(0, 5)));
}

// A platform cell is verified by its evidence file, built when its code is in the repository,
// and otherwise keeps its design state.
export function cellState(cell) {
  if (cell.evidence && evidenceFiles().some((f) => cell.evidence.test(f))) return 'verified';
  if (cell.code && fs.existsSync(path.join(ROOT, cell.code))) return cell.builtAs || 'built';
  return cell.base;
}
