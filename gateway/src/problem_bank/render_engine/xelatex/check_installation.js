import { execFile } from 'node:child_process';
import fs from 'node:fs';

const KNOWN_PATHS_WIN = [
  'C:\\texlive\\2026\\bin\\windows\\xelatex.exe',
  'C:\\texlive\\2025\\bin\\windows\\xelatex.exe',
  'C:\\texlive\\2024\\bin\\windows\\xelatex.exe',
];

let _cached = null;

function findXeLatexBinary() {
  for (const p of KNOWN_PATHS_WIN) {
    if (fs.existsSync(p)) return p;
  }
  return 'xelatex';
}

export function getXeLatexBinary() {
  return findXeLatexBinary();
}

export function checkXeLatexInstallation() {
  if (_cached !== null) return Promise.resolve(_cached);

  const bin = findXeLatexBinary();
  return new Promise((resolve) => {
    execFile(bin, ['--version'], { timeout: 5000 }, (err, stdout) => {
      if (err) {
        _cached = { installed: false, version: null, binary: bin, error: err.message };
      } else {
        const vMatch = String(stdout).match(/XeTeX[^\n]*?(\d+\.\d+)/i);
        _cached = {
          installed: true,
          version: vMatch ? vMatch[1] : 'unknown',
          binary: bin,
          error: null,
        };
      }
      resolve(_cached);
    });
  });
}

export function resetCache() {
  _cached = null;
}
