import { PDFDocument } from 'pdf-lib';

import { closeBrowserPool, getBrowser } from './browser_pool.js';

function isConnectionClosedError(error) {
  const msg = String(error?.message || error || '');
  return /connection closed|target closed|session closed|browser has disconnected|protocol error/i.test(msg);
}

async function renderOnce(html) {
  const browser = await getBrowser();
  let page = null;
  try {
    page = await browser.newPage();
    await page.setContent(String(html || ''), {
      waitUntil: 'domcontentloaded',
      timeout: 120000,
    });
    await page.evaluate(async () => {
      const timeout = (ms) =>
        new Promise((resolve) => setTimeout(resolve, ms));
      if (document.fonts?.ready) {
        await Promise.race([document.fonts.ready, timeout(20000)]);
      }
    });
    const pdfBuffer = await page.pdf({
      printBackground: true,
      preferCSSPageSize: true,
    });
    const bytes = Buffer.isBuffer(pdfBuffer)
      ? pdfBuffer
      : Buffer.from(pdfBuffer);
    const pdfDoc = await PDFDocument.load(bytes);
    return {
      bytes,
      pageCount: pdfDoc.getPageCount(),
    };
  } finally {
    if (page) {
      try {
        if (!page.isClosed()) await page.close();
      } catch (_) {
        // ignore close errors caused by disconnected browser
      }
    }
  }
}

export async function renderHtmlToPdfBuffer(html) {
  try {
    return await renderOnce(html);
  } catch (error) {
    if (!isConnectionClosedError(error)) throw error;
    await closeBrowserPool();
    return renderOnce(html);
  }
}
