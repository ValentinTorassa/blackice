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

// Code counts as built when its path exists and, for a cell with builtWhen, when that file matches it.
function codeBuilt(cell) {
  if (!cell.code) return false;
  const file = path.join(ROOT, cell.code);
  if (!fs.existsSync(file)) return false;
  if (!cell.builtWhen) return true;
  try {
    return cell.builtWhen.test(fs.readFileSync(file, 'utf8'));
  } catch {
    return false;
  }
}

// A platform cell is verified by its evidence file, built when its code is in the repository,
// and otherwise keeps its design state.
export function cellState(cell) {
  if (cell.evidence && evidenceFiles().some((f) => cell.evidence.test(f))) return 'verified';
  if (codeBuilt(cell)) return cell.builtAs || 'built';
  return cell.base;
}
