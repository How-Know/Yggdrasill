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

    const sizeMatch = String(html).match(/@page\s*\{[^}]*size:\s*([\d.]+)mm\s+([\d.]+)mm/);
    const marginMatch = String(html).match(/@page\s*\{[^}]*margin:\s*([\d.]+)mm/);
    const paperW = sizeMatch ? parseFloat(sizeMatch[1]) : 257;
    const paperH = sizeMatch ? parseFloat(sizeMatch[2]) : 364;
    const mgn = marginMatch ? parseFloat(marginMatch[1]) : 16.2;
    const contentWPx = Math.round((paperW - 2 * mgn) * 96 / 25.4);
    const contentHPx = Math.round((paperH - 2 * mgn) * 96 / 25.4);
    await page.setViewport({ width: contentWPx, height: contentHPx });

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

    await page.evaluate(() => {
      function isH(c) {
        var k = c.charCodeAt(0);
        return (k >= 0xAC00 && k <= 0xD7AF) || (k >= 0x1100 && k <= 0x11FF) || (k >= 0x3130 && k <= 0x318F);
      }
      function shouldSkip(node) {
        var el = node.nodeType === 3 ? node.parentElement : node;
        while (el) {
          if (el.classList) {
            if (el.classList.contains('math-inline')) return true;
            if (el.classList.contains('q-num')) return true;
            if (el.classList.contains('choice-label')) return true;
            if (el.classList.contains('bogi-item-label')) return true;
          }
          if (el.tagName === 'svg' || el.tagName === 'SVG') return true;
          el = el.parentElement;
        }
        return false;
      }

      document.querySelectorAll('.q-stem, .choice-text, .bogi-item-text').forEach(function (block) {
        block.querySelectorAll('.debug-first').forEach(function (node) {
          var parent = node.parentNode;
          if (!parent) return;
          while (node.firstChild) parent.insertBefore(node.firstChild, node);
          parent.removeChild(node);
        });

        var tns = [];
        var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null, false);
        while (walker.nextNode()) {
          if (!shouldSkip(walker.currentNode)) tns.push(walker.currentNode);
        }

        var chars = [];
        var order = 0;
        tns.forEach(function (tn) {
          for (var i = 0; i < tn.textContent.length; i++) {
            if (!isH(tn.textContent[i])) continue;
            var range = document.createRange();
            range.setStart(tn, i);
            range.setEnd(tn, i + 1);
            var rect = range.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) continue;
            chars.push({ tn: tn, i: i, order: order++, left: rect.left, top: rect.top });
          }
        });
        if (!chars.length) return;

        var groups = [];
        chars.forEach(function (ch) {
          for (var g = 0; g < groups.length; g++) {
            if (Math.abs(ch.top - groups[g].refTop) < 8) {
              groups[g].items.push(ch);
              return;
            }
          }
          groups.push({ refTop: ch.top, items: [ch] });
        });
        groups.sort(function (a, b) { return a.refTop - b.refTop; });

        var toWrap = [];
        groups.forEach(function (g) {
          var leftmost = g.items[0];
          for (var k = 1; k < g.items.length; k++) {
            if (g.items[k].left < leftmost.left) leftmost = g.items[k];
          }
          toWrap.push(leftmost);
        });

        toWrap.sort(function (a, b) { return b.order - a.order; });
        toWrap.forEach(function (h) {
          var r2 = document.createRange();
          r2.setStart(h.tn, h.i);
          r2.setEnd(h.tn, h.i + 1);
          var mark = document.createElement('span');
          mark.className = 'debug-first';
          try { r2.surroundContents(mark); } catch (_) {}
        });
      });

      // Align math-inline vertical center to hangul center (blue line → red line match)
      // Scoped per block: only match math with debug-first in the same parent container
      document.querySelectorAll('.q-stem, .bogi-item-text').forEach(function (block) {
        var localRefs = Array.from(block.querySelectorAll('.debug-first')).map(function (df) {
          var r = df.getBoundingClientRect();
          return { centerY: r.top + r.height / 2, top: r.top, bottom: r.top + r.height };
        });
        if (!localRefs.length) return;

        block.querySelectorAll('.math-inline').forEach(function (math) {
          var mr = math.getBoundingClientRect();
          var mathCenterY = mr.top + mr.height / 2;
          var mathTop = mr.top;
          var mathBottom = mr.top + mr.height;

          // Find debug-first on the same visual line (Y ranges overlap)
          var best = null;
          var bestDist = Infinity;
          for (var i = 0; i < localRefs.length; i++) {
            var ref = localRefs[i];
            var overlapTop = Math.max(mathTop, ref.top);
            var overlapBot = Math.min(mathBottom, ref.bottom);
            if (overlapBot >= overlapTop - 4) {
              var dist = Math.abs(ref.centerY - mathCenterY);
              if (dist < bestDist) {
                bestDist = dist;
                best = ref;
              }
            }
          }

          // Fallback: closest by distance within tight range
          if (!best) {
            for (var i = 0; i < localRefs.length; i++) {
              var dist = Math.abs(localRefs[i].centerY - mathCenterY);
              if (dist < bestDist && dist < 25) {
                bestDist = dist;
                best = localRefs[i];
              }
            }
          }

          if (best) {
            var offset = best.centerY - mathCenterY;
            if (Math.abs(offset) > 0.3) {
              math.style.transform = 'translateY(' + offset.toFixed(2) + 'px)';
            }
          }
        });
      });

      // Sync paired question-slot top spacers in grid4 so q-nums align horizontally
      document.querySelectorAll('.question-stream-grid4').forEach(function (grid) {
        var slots = grid.querySelectorAll('.question-slot');
        var pairs = [[0, 2], [1, 3]];
        pairs.forEach(function (pair) {
          var slotA = slots[pair[0]];
          var slotB = slots[pair[1]];
          if (!slotA || !slotB) return;
          var numA = slotA.querySelector('.q-num');
          var numB = slotB.querySelector('.q-num');
          if (!numA || !numB) return;

          var topA = numA.getBoundingClientRect().top;
          var topB = numB.getBoundingClientRect().top;
          var diff = Math.abs(topA - topB);
          if (diff < 1) return;

          var target = topA < topB ? slotA : slotB;
          var spacer = target.querySelector('.question-slot-firstline');
          if (spacer) {
            var cur = spacer.getBoundingClientRect().height;
            spacer.style.height = (cur + diff) + 'px';
          }
        });
      });
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

async function screenshotOnce(html, viewportWidth = 400, deviceScaleFactor = 2) {
  const browser = await getBrowser();
  let page = null;
  try {
    page = await browser.newPage();
    await page.setViewport({ width: viewportWidth, height: 800, deviceScaleFactor });
    await page.setContent(String(html || ''), {
      waitUntil: 'domcontentloaded',
      timeout: 60000,
    });
    await page.evaluate(async () => {
      const timeout = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
      if (document.fonts?.ready) {
        await Promise.race([document.fonts.ready, timeout(15000)]);
      }
    });

    const pngBuffer = await page.screenshot({
      type: 'png',
      fullPage: true,
      omitBackground: false,
    });
    return Buffer.isBuffer(pngBuffer) ? pngBuffer : Buffer.from(pngBuffer);
  } finally {
    if (page) {
      try { if (!page.isClosed()) await page.close(); } catch (_) {}
    }
  }
}

export async function renderHtmlToImageBuffer(html, viewportWidth = 400, deviceScaleFactor = 2) {
  try {
    return await screenshotOnce(html, viewportWidth, deviceScaleFactor);
  } catch (error) {
    if (!isConnectionClosedError(error)) throw error;
    await closeBrowserPool();
    return screenshotOnce(html, viewportWidth, deviceScaleFactor);
  }
}
