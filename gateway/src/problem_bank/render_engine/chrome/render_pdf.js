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

      function rectCenterY(rect) {
        return rect.top + rect.height / 2;
      }

      // Keep anchor-label geometry consistent with first-page baseline.
      var baseAnchorGapPx = 16 * (96 / 72);
      var baseAnchorCenterOffsetPx = 0;
      (function calibrateAnchorBaselineFromFirstPage() {
        var firstAnchor = document.querySelector('.mock-page-first .question-slot[data-has-anchor="1"]:not([data-slot-hidden="1"])');
        if (!firstAnchor) return;
        var firstLabel = firstAnchor.querySelector('.slot-label-overlay .mock-section-label');
        var firstNum = firstAnchor.querySelector('.q-num');
        if (firstLabel && firstNum) {
          var firstGap = firstNum.getBoundingClientRect().top - firstLabel.getBoundingClientRect().bottom;
          if (Number.isFinite(firstGap) && firstGap > 0.5) baseAnchorGapPx = firstGap;
        }
        var rowNo = Number(firstAnchor.getAttribute('data-slot-row') || firstAnchor.dataset.slotRow || 0);
        if (!Number.isFinite(rowNo) || rowNo <= 0) return;
        var grid = firstAnchor.closest('.question-stream-slotgrid, .question-stream-grid4');
        if (!grid) return;
        var pairSlot = Array.from(grid.querySelectorAll('.question-slot')).find(function (slot) {
          if (slot === firstAnchor) return false;
          if (String(slot.getAttribute('data-slot-hidden') || '0') === '1') return false;
          var sr = Number(slot.getAttribute('data-slot-row') || slot.dataset.slotRow || 0);
          if (sr !== rowNo) return false;
          return Boolean(slot.querySelector('.q-num'));
        });
        if (!pairSlot || !firstLabel) return;
        var pairNum = pairSlot.querySelector('.q-num');
        if (!pairNum) return;
        baseAnchorCenterOffsetPx =
          rectCenterY(firstLabel.getBoundingClientRect()) - rectCenterY(pairNum.getBoundingClientRect());
      })();

      // Align slot-pair rows by metadata (anchor rows handled by anchor baseline)
      document.querySelectorAll('.question-stream-slotgrid, .question-stream-grid4').forEach(function (grid) {
        var pairAlign = String(grid.getAttribute('data-pair-align') || 'row').toLowerCase();
        if (pairAlign === 'none') return;
        var skipAnchorRows = String(grid.getAttribute('data-skip-anchor-rows') || '1') !== '0';
        var slotNodes = Array.from(grid.querySelectorAll('.question-slot'));
        if (!slotNodes.length) return;

        var rows = new Map();
        slotNodes.forEach(function (slot) {
          var row = Number(slot.getAttribute('data-slot-row') || slot.dataset.slotRow || 0);
          if (!Number.isFinite(row) || row <= 0) return;
          var hidden = String(slot.getAttribute('data-slot-hidden') || '0') === '1';
          if (hidden) return;
          var num = slot.querySelector('.q-num');
          if (!num) return;
          var hasOwnAnchor = String(slot.getAttribute('data-has-anchor') || '0') === '1';
          var hasAnchor =
            hasOwnAnchor
            || String(slot.getAttribute('data-row-has-anchor') || '0') === '1';
          if (!rows.has(row)) rows.set(row, { items: [], hasAnchor: false });
          var bucket = rows.get(row);
          bucket.items.push({ slot: slot, num: num, hasOwnAnchor: hasOwnAnchor });
          bucket.hasAnchor = bucket.hasAnchor || hasAnchor;
        });

        Array.from(rows.keys()).sort(function (a, b) { return a - b; }).forEach(function (rowKey) {
          var row = rows.get(rowKey);
          if (!row || !row.items || row.items.length < 2) return;

          if (row.hasAnchor) {
            var refItems = row.items.filter(function (item) { return !item.hasOwnAnchor; });
            if (!refItems.length) refItems = row.items;
            var refTops = refItems.map(function (item) {
              return item.num.getBoundingClientRect().top;
            });
            var refTop = Math.max.apply(null, refTops);
            var ref = refItems.find(function (item) {
              return Math.abs(item.num.getBoundingClientRect().top - refTop) < 0.8;
            }) || refItems[0];
            var refCenterY = rectCenterY(ref.num.getBoundingClientRect());

            row.items.forEach(function (item) {
              if (!item.hasOwnAnchor) return;
              var overlay = item.slot.querySelector('.slot-label-overlay');
              var label = item.slot.querySelector('.slot-label-overlay .mock-section-label');
              var spacer = item.slot.querySelector('.question-slot-firstline');
              if (!overlay || !label || !spacer) return;

              var labelCenterY = rectCenterY(label.getBoundingClientRect());
              var desiredLabelCenterY = refCenterY + baseAnchorCenterOffsetPx;
              var deltaY = desiredLabelCenterY - labelCenterY;
              if (Math.abs(deltaY) > 0.3) {
                overlay.style.transform = 'translateY(' + deltaY.toFixed(2) + 'px)';
              }

              var adjustedLabelBottom = label.getBoundingClientRect().bottom;
              var ownNumTop = item.num.getBoundingClientRect().top;
              var currentGap = ownNumTop - adjustedLabelBottom;
              var gapDiff = baseAnchorGapPx - currentGap;
              if (Math.abs(gapDiff) > 0.8) {
                var cur = spacer.getBoundingClientRect().height;
                var next = Math.max(0, cur + gapDiff);
                spacer.style.height = next + 'px';
                spacer.style.lineHeight = next + 'px';
              }
            });
            return;
          }

          if (skipAnchorRows && row.hasAnchor) return;

          var tops = row.items.map(function (item) {
            return item.num.getBoundingClientRect().top;
          });
          var targetTop = Math.max.apply(null, tops);
          row.items.forEach(function (item) {
            var top = item.num.getBoundingClientRect().top;
            var diff = targetTop - top;
            if (diff < 1) return;
            var spacer = item.slot.querySelector('.question-slot-firstline');
            if (!spacer) return;
            var cur = spacer.getBoundingClientRect().height;
            spacer.style.height = (cur + diff) + 'px';
          });
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
