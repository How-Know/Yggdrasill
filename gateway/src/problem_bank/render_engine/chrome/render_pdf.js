import { PDFDocument } from 'pdf-lib';

import { getBrowser } from './browser_pool.js';

export async function renderHtmlToPdfBuffer(html) {
  const browser = await getBrowser();
  const page = await browser.newPage();
  try {
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
    await page.close();
  }
}
