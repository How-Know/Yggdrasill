import fs from 'node:fs';
import path from 'node:path';

let browserPromise = null;

function detectChromeExecutable() {
  const fromEnv = String(process.env.PB_CHROME_EXECUTABLE_PATH || '').trim();
  const home = process.env.USERPROFILE || process.env.HOME || '';
  const candidates = [
    fromEnv,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    home ? path.join(home, 'AppData', 'Local', 'Google', 'Chrome', 'Application', 'chrome.exe') : '',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  ].filter(Boolean);

  for (const one of candidates) {
    if (fs.existsSync(one)) return one;
  }
  return '';
}

export async function getBrowser() {
  if (!browserPromise) {
    browserPromise = (async () => {
      const { default: puppeteer } = await import('puppeteer-core');
      const executablePath = detectChromeExecutable();
      if (!executablePath) {
        throw new Error(
          'chrome_executable_not_found: set PB_CHROME_EXECUTABLE_PATH or install Chrome/Edge',
        );
      }
      const browser = await puppeteer.launch({
        executablePath,
        headless: true,
        args: [
          '--no-sandbox',
          '--disable-setuid-sandbox',
          '--disable-dev-shm-usage',
          '--font-render-hinting=none',
        ],
      });
      browser.on('disconnected', () => {
        browserPromise = null;
      });
      return browser;
    })();
  }
  return browserPromise;
}

export async function closeBrowserPool() {
  if (!browserPromise) return;
  try {
    const browser = await browserPromise;
    await browser.close();
  } catch (_) {
    // noop
  } finally {
    browserPromise = null;
  }
}
