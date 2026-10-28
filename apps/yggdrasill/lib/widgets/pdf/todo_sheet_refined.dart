part of '../homework_assign_dialog.dart';

/// 접는 눈금. 한가운데보다 4mm 아래.
/// 5mm는 접었을 때 주름보다 1mm 아래로 보였다.
const double _todoSheetFoldDrop = 4 * 72 / 25.4;

class _RefinedInk {
  static final ink = sf.PdfColor(29, 29, 31);
  static final secondary = sf.PdfColor(99, 99, 105);
  static final tertiary = sf.PdfColor(142, 142, 148);
  static final card = sf.PdfColor(243, 243, 246);
  static final rule = sf.PdfColor(196, 196, 202);
  static final before = sf.PdfColor(194, 194, 201);
  static final accent = sf.PdfColor(28, 160, 88);
  static final accentSoft = sf.PdfColor(220, 241, 228);
  static final accentDeep = sf.PdfColor(16, 108, 56);
  static final alert = sf.PdfColor(214, 66, 72);
  static final checkbox = sf.PdfColor(168, 168, 176);
  static final white = sf.PdfColor(255, 255, 255);

  static const inkColor = Color(0xFF1D1D1F);
  static const secondaryColor = Color(0xFF636369);
}

/// 둥근 사각형. 반지름이 높이 절반이면 알약 모양.
void _refinedRoundRect(
  sf.PdfGraphics g,
  Rect r, {
  required double radius,
  sf.PdfBrush? brush,
  sf.PdfPen? pen,
}) {
  if (r.width <= 0 || r.height <= 0) return;
  final rr = math.min(radius, math.min(r.width, r.height) / 2);
  if (rr <= 0.05) {
    g.drawRectangle(bounds: r, brush: brush, pen: pen);
    return;
  }
  final d = rr * 2;
  final path = sf.PdfPath()
    ..addArc(Rect.fromLTWH(r.left, r.top, d, d), 180, 90)
    ..addArc(Rect.fromLTWH(r.right - d, r.top, d, d), 270, 90)
    ..addArc(Rect.fromLTWH(r.right - d, r.bottom - d, d, d), 0, 90)
    ..addArc(Rect.fromLTWH(r.left, r.bottom - d, d, d), 90, 90)
    ..closeFigure();
  g.drawPath(path, brush: brush, pen: pen);
}

/// 수식이 있으면 학습 화면과 같은 조판으로, 없으면 PDF 글꼴로 그린다.
Future<void> _refinedDrawRich(
  sf.PdfGraphics g,
  String text,
  sf.PdfFont font, {
  required double fontSize,
  required bool bold,
  required sf.PdfColor pdfColor,
  required Color color,
  required Rect bounds,
  sf.PdfStringFormat? format,
}) async {
  final brush = sf.PdfSolidBrush(pdfColor);
  final normalized = normalizeTodoSheetMath(text);
  if (!todoSheetMathNeedsPaint(normalized)) {
    g.drawString(text, font, brush: brush, bounds: bounds, format: format);
    return;
  }
  final shot = await rasterizeTodoSheetMath(
    text: normalized,
    fontSize: fontSize,
    bold: bold,
    color: color,
    maxWidth: bounds.width,
  );
  if (shot == null) {
    g.drawString(text, font, brush: brush, bounds: bounds, format: format);
    return;
  }
  final maxH = bounds.height + 3;
  final scale = math.min(
    1.0,
    math.min(maxH / shot.height, bounds.width / shot.width),
  );
  final w = shot.width * scale;
  final h = shot.height * scale;
  final top = bounds.top + (bounds.height - h) / 2;
  final alignRight = format?.alignment == sf.PdfTextAlignment.right;
  final x = alignRight ? bounds.right - w : bounds.left;
  g.drawImage(sf.PdfBitmap(shot.bytes), Rect.fromLTWH(x, top, w, h));
}

class _RefinedFonts {
  _RefinedFonts._(this._fonts);
  final Map<String, sf.PdfFont> _fonts;

  static Future<_RefinedFonts> load() async {
    final specs = <String, (double, bool)>{
      'eyebrow': (8.8, true),
      'academy': (9.6, true),
      'name': (24.0, true),
      'date': (12.0, true),
      'stripLabel': (7.8, false),
      'stripValue': (12.4, true),
      'cardTitle': (11.2, true),
      'pageTitle': (16.0, true),
      'body': (10.0, false),
      'bodyBold': (10.0, true),
      'sub': (9.0, false),
      'small': (8.4, false),
      'smallBold': (8.4, true),
      'tiny': (7.6, false),
      'legend': (9.4, false),
      'legendBold': (9.4, true),
      'legendSub': (8.2, false),
      'hero': (27.0, true),
      'tileValue': (14.5, true),
      'unit': (8.6, false),
      'center': (22.0, true),
      'rowTitle': (9.4, true),
      'mood': (9.4, true),
    };
    final out = <String, sf.PdfFont>{};
    for (final e in specs.entries) {
      out[e.key] = await _loadTodoPdfFont(e.value.$1, bold: e.value.$2);
    }
    return _RefinedFonts._(out);
  }

  sf.PdfFont operator [](String key) => _fonts[key]!;
  double sizeOf(String key) => _fonts[key]!.size;
}

String _refinedLongDate(DateTime dt) =>
    '${dt.month}월 ${dt.day}일 ${_formatWeekdayKorean(dt)}요일';

Future<List<int>> _renderTodoSheetRefined(_TodoSheetPayload payload) async {
  final doc = sf.PdfDocument();
  doc.pageSettings.orientation = sf.PdfPageOrientation.portrait;
  doc.pageSettings.margins.all = 18;
  doc.pageSettings.margins.top = 0;
  final fonts = await _RefinedFonts.load();

  final page = doc.pages.add();
  final size = page.getClientSize();
  final g = page.graphics;

  const left = 10.0;
  final right = size.width - 10;
  final width = right - left;
  final bottom = size.height - 6;
  final foldY = size.height / 2 + _todoSheetFoldDrop;
  const cardGap = 10.0;
  const cardRadius = 14.0;
  const pad = 14.0;
  // 맑은 고딕: 글자 상단에서 기준선까지 = 글자 크기 × 1.06.
  const ascent = 1.06;

  final rightAlign = sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right);
  final centerAlign =
      sf.PdfStringFormat(alignment: sf.PdfTextAlignment.center);
  final whiteBrush = sf.PdfSolidBrush(_RefinedInk.white);
  final cardBrush = sf.PdfSolidBrush(_RefinedInk.card);
  final dividerPen = sf.PdfPen(_RefinedInk.white, width: 1);

  void text(
    sf.PdfGraphics gr,
    String s,
    String font,
    sf.PdfColor color,
    double x,
    double y,
    double w, {
    double? h,
    sf.PdfStringFormat? format,
  }) {
    if (s.isEmpty || w <= 0) return;
    final f = fonts[font];
    gr.drawString(s, f,
        brush: sf.PdfSolidBrush(color),
        bounds: Rect.fromLTWH(x, y, w, h ?? f.size * 1.45),
        format: format);
  }

  double widthOf(String s, String font) =>
      s.isEmpty ? 0.0 : fonts[font].measureString(s).width;

  /// 큰 숫자와 작은 단위를 같은 기준선에 놓는다. 그린 너비를 돌려준다.
  double numberWithUnit(sf.PdfGraphics gr, String number, String unit,
      {required double x,
      required double y,
      required double maxW,
      required String numFont,
      String unitFont = 'unit',
      sf.PdfColor? color}) {
    final numW = math.min(widthOf(number, numFont) + 1, maxW);
    text(gr, number, numFont, color ?? _RefinedInk.ink, x, y, numW + 2);
    final unitX = x + numW + 2.5;
    final unitY =
        y + (fonts.sizeOf(numFont) - fonts.sizeOf(unitFont)) * ascent;
    final unitW = math.max(0.0, x + maxW - unitX);
    text(gr, unit, unitFont, _RefinedInk.secondary, unitX, unitY, unitW);
    return numW + 2.5 + widthOf(unit, unitFont);
  }

  void card(sf.PdfGraphics gr, Rect r) =>
      _refinedRoundRect(gr, r, radius: cardRadius, brush: cardBrush);

  void divider(sf.PdfGraphics gr, double x1, double x2, double y) =>
      gr.drawLine(dividerPen, Offset(x1, y), Offset(x2, y));

  /// 카드 제목 줄. 본문 시작 y를 돌려준다.
  double cardTitle(sf.PdfGraphics gr, Rect r, String title, {int? count}) {
    final x = r.left + pad;
    final y = r.top + 12;
    text(gr, title, 'cardTitle', _RefinedInk.ink, x, y, r.width - pad * 2);
    if (count != null && count > 0) {
      final tw = widthOf(title, 'cardTitle');
      text(gr, '$count', 'cardTitle', _RefinedInk.tertiary, x + tw + 5, y, 40);
    }
    return r.top + 38;
  }

  /// 접는 자리를 양쪽 가장자리에 짧게 표시한다.
  void foldTicks(sf.PdfGraphics gr, double w, double y) {
    final pen = sf.PdfPen(_RefinedInk.rule, width: 0.8);
    gr.drawLine(pen, Offset(0, y), Offset(5, y));
    gr.drawLine(pen, Offset(w - 5, y), Offset(w, y));
  }

  const overflowH = 14.0;
  void overflow(sf.PdfGraphics gr, double x, double y, double w, int count) {
    text(gr, '외 $count개', 'small', _RefinedInk.tertiary, x, y, w);
  }

  void checkbox(sf.PdfGraphics gr, double x, double y) {
    _refinedRoundRect(gr, Rect.fromLTWH(x, y, 10, 10),
        radius: 2.6,
        brush: whiteBrush,
        pen: sf.PdfPen(_RefinedInk.checkbox, width: 0.8));
  }

  /// 흰 바탕 막대. 회색 = 이전까지, 초록 = 오늘 늘어난 만큼.
  void progressBar(
    sf.PdfGraphics gr, {
    required double x,
    required double y,
    required double w,
    required double previousPct,
    required double todayPct,
    double h = 4.6,
  }) {
    final prev = previousPct.clamp(0.0, 100.0);
    final today = todayPct.clamp(0.0, math.max(0.0, 100.0 - prev));
    final radius = h / 2;
    _refinedRoundRect(gr, Rect.fromLTWH(x, y, w, h),
        radius: radius, brush: whiteBrush);
    final filledW = w * (prev + today) / 100;
    if (today > 0 && filledW > 0) {
      _refinedRoundRect(gr, Rect.fromLTWH(x, y, math.max(h, filledW), h),
          radius: radius, brush: sf.PdfSolidBrush(_RefinedInk.accent));
    }
    final prevW = w * prev / 100;
    if (prevW > 0) {
      _refinedRoundRect(gr, Rect.fromLTWH(x, y, math.max(h, prevW), h),
          radius: radius, brush: sf.PdfSolidBrush(_RefinedInk.before));
    }
  }

  // ── 머리말: 학생 이름을 크게, 시간은 한 줄 띠로 ──
  text(g, '학습 리포트', 'eyebrow', _RefinedInk.accent, left, 1, 120);
  {
    final academy = payload.academyName.trim();
    final academyW = math.min(widthOf(academy, 'academy') + 2, 220.0);
    text(g, academy, 'academy', _RefinedInk.secondary, right - academyW, 0.4,
        academyW);
    if (payload.academyLogo != null && payload.academyLogo!.isNotEmpty) {
      try {
        final logo = sf.PdfBitmap(payload.academyLogo!);
        const box = 15.0;
        final scale = math.min(box / logo.width, box / logo.height);
        final dw = logo.width * scale;
        final dh = logo.height * scale;
        g.drawImage(
            logo,
            Rect.fromLTWH(right - academyW - 5 - dw, (box - dh) / 2 - 0.5, dw,
                dh));
      } catch (_) {}
    }
  }
  final nameText =
      payload.studentName.trim().isEmpty ? '-' : payload.studentName.trim();
  final nameW = math.min(widthOf(nameText, 'name') + 2, width * 0.5);
  text(g, nameText, 'name', _RefinedInk.ink, left - 1, 14, nameW + 2);
  text(g, payload.className.trim(), 'body', _RefinedInk.secondary,
      left + nameW + 9, 14 + (24 - 10) * ascent, width * 0.5 - nameW - 9);
  text(g, _refinedLongDate(payload.classDateTime), 'date', _RefinedInk.ink,
      right - 220, 17, 220,
      format: rightAlign);
  final classTime = payload.classTimeText
      .replaceAll(RegExp(r'^\(|\)$'), '')
      .replaceFirst(RegExp(r'^[월화수목금토일]\s+'), '')
      .replaceAll(' - ', ' – ')
      .trim();
  text(g, classTime.isEmpty ? '' : '수업 $classTime', 'sub',
      _RefinedInk.secondary, right - 220, 35, 220,
      format: rightAlign);

  final arrMs = payload.arrivalTime?.millisecondsSinceEpoch ?? 0;
  final depMs = payload.departureTime.millisecondsSinceEpoch;
  final stayMs = (arrMs > 0 && depMs > arrMs) ? depMs - arrMs : 0;
  {
    final strip = Rect.fromLTWH(left, 55, width, 40);
    _refinedRoundRect(g, strip, radius: 11, brush: cardBrush);
    final cells = <(String, String)>[
      ('등원', _formatTime(payload.arrivalTime)),
      ('하원', _formatTime(payload.departureTime)),
      ('학습 시간', payload.learningTimeText),
      ('머문 시간', stayMs > 0 ? _formatDurationKorean(stayMs) : ''),
    ];
    final cellW = width / cells.length;
    for (int i = 0; i < cells.length; i++) {
      final x = left + cellW * i;
      if (i > 0) {
        g.drawLine(dividerPen, Offset(x, strip.top + 9),
            Offset(x, strip.bottom - 9));
      }
      text(g, cells[i].$1, 'stripLabel', _RefinedInk.tertiary, x + pad,
          strip.top + 6.5, cellW - pad * 2);
      final value = cells[i].$2.trim();
      text(g, value.isEmpty ? '-' : value, 'stripValue',
          value.isEmpty ? _RefinedInk.tertiary : _RefinedInk.ink, x + pad,
          strip.top + 18, cellW - pad * 2);
    }
  }

  // ── 1쪽 위: 수업 요약 카드 · 학습 기록 카드 ──
  const upperTop = 105.0;
  // 접는 눈금과 위 카드(수업 요약·학습 기록) 사이. 11의 1.5배.
  const upperGap = 16.5;
  final upperBottom = foldY - upperGap;
  const summaryCardW = 332.0;
  final summaryRect =
      Rect.fromLTRB(left, upperTop, left + summaryCardW, upperBottom);
  final recordRect = Rect.fromLTRB(
      left + summaryCardW + cardGap, upperTop, right, upperBottom);
  card(g, summaryRect);
  card(g, recordRect);

  final summaryBodyTop = cardTitle(g, summaryRect, '수업 요약');
  final donutEntries = payload.classWorkEntries;
  final totalLearningMs = payload.learningMs;
  final breakMs = math.max(0, stayMs - totalLearningMs);
  const donutR = 60.0;
  const donutInnerR = 42.0;
  final donutCx = summaryRect.left + pad + donutR;
  final donutCy = summaryBodyTop + donutR + 2;
  final legendX = summaryRect.left + pad + donutR * 2 + 20;
  final legendRight = summaryRect.right - pad;
  // 아래쪽은 학습 Flow와 특이 사항. 목록이 길어도 Flow 한 줄과 특이 사항은 남긴다.
  const flowReserve = 112.0;
  final legendLimitY = summaryRect.bottom - flowReserve;

  final hasDonut = !(donutEntries.isEmpty && totalLearningMs <= 0);
  double legendBottomY = summaryBodyTop;
  if (!hasDonut) {
    text(g, '오늘 수행 기록 없음', 'body', _RefinedInk.tertiary,
        summaryRect.left + pad, summaryBodyTop, summaryRect.width - pad * 2);
  } else {
    final palette = [
      sf.PdfColor(46, 170, 104),
      sf.PdfColor(64, 128, 238),
      sf.PdfColor(244, 163, 48),
      sf.PdfColor(146, 104, 230),
      sf.PdfColor(30, 182, 196),
      sf.PdfColor(236, 92, 98),
      sf.PdfColor(170, 132, 96),
      sf.PdfColor(92, 104, 226),
    ];
    final slices = <({
      String label,
      int ms,
      String? checkText,
      String? totalText,
      sf.PdfColor color,
    })>[];
    for (int i = 0; i < donutEntries.length; i++) {
      final e = donutEntries[i];
      if (e.studyMs <= 0) continue;
      final checks = e.totalCheckCount;
      final checkText = checks <= 0
          ? (e.passed ? '검사 없이 통과' : '검사 전')
          : (e.passed ? '$checks회 검사 후 통과' : '$checks회 검사 · 진행 중');
      final totalMin = (e.totalAccumulatedMs / 60000).round();
      slices.add((
        label: e.title,
        ms: e.studyMs,
        checkText: checkText,
        totalText: totalMin > 0 ? '누적 $totalMin분' : null,
        color: palette[i % palette.length],
      ));
    }
    if (breakMs > 0) {
      slices.add((
        label: '휴식',
        ms: breakMs,
        checkText: null,
        totalText: null,
        color: sf.PdfColor(208, 208, 214),
      ));
    }
    final totalSliceMs = slices.fold<int>(0, (s, e) => s + e.ms);
    final donutRect =
        Rect.fromCircle(center: Offset(donutCx, donutCy), radius: donutR);
    if (totalSliceMs > 0) {
      double startAngle = -90;
      final gapPen = sf.PdfPen(_RefinedInk.card, width: 2.2);
      for (final slice in slices) {
        final sweep = (slice.ms / totalSliceMs) * 360;
        g.drawPie(donutRect, startAngle, sweep,
            pen: slices.length > 1 ? gapPen : null,
            brush: sf.PdfSolidBrush(slice.color));
        startAngle += sweep;
      }
    } else {
      g.drawEllipse(donutRect, brush: whiteBrush);
    }
    g.drawEllipse(
      Rect.fromCircle(center: Offset(donutCx, donutCy), radius: donutInnerR),
      brush: cardBrush,
    );
    final totalMin = (totalLearningMs / 60000).round();
    final numText = '$totalMin';
    final groupW = widthOf(numText, 'center') + 3.5 + widthOf('분', 'unit');
    numberWithUnit(g, numText, '분',
        x: donutCx - groupW / 2,
        y: donutCy - 18,
        maxW: groupW + 4,
        numFont: 'center');
    text(g, '학습', 'tiny', _RefinedInk.tertiary, donutCx - 30, donutCy + 10,
        60,
        format: centerAlign);

    const swatch = 8.0;
    const nameGap = 7.0;
    const timeW = 40.0;
    final nameX = legendX + swatch + nameGap;
    final rowW = legendRight - nameX;
    final nameW = math.max(0.0, rowW - timeW - 4);
    double ly = summaryBodyTop - 1;
    for (int i = 0; i < slices.length; i++) {
      final slice = slices[i];
      final twoLine = slice.checkText != null || slice.totalText != null;
      final rowH = twoLine ? 33.0 : 22.0;
      final remaining = slices.length - i;
      if (ly + rowH + (remaining > 1 ? overflowH : 0) > legendLimitY) {
        overflow(g, nameX, ly, rowW, remaining);
        ly += overflowH;
        break;
      }
      _refinedRoundRect(g, Rect.fromLTWH(legendX, ly + 3.2, swatch, swatch),
          radius: 2.4, brush: sf.PdfSolidBrush(slice.color));
      await _refinedDrawRich(g, slice.label, fonts['legendBold'],
          fontSize: 9.4,
          bold: true,
          pdfColor: _RefinedInk.ink,
          color: _RefinedInk.inkColor,
          bounds: Rect.fromLTWH(nameX, ly, nameW, 14));
      text(g, '${(slice.ms / 60000).round()}분', 'legendBold',
          _RefinedInk.ink, legendRight - timeW, ly, timeW,
          format: rightAlign);
      if (twoLine) {
        final check = slice.checkText ?? '';
        final total = slice.totalText ?? '';
        final totalW = math.min(widthOf(total, 'legendSub') + 2, rowW * 0.45);
        text(g, check, 'legendSub', _RefinedInk.secondary, nameX, ly + 15,
            rowW - totalW - 4);
        text(g, total, 'legendSub', _RefinedInk.tertiary,
            legendRight - totalW, ly + 15, totalW,
            format: rightAlign);
      }
      ly += rowH;
    }
    legendBottomY = ly;
  }
  {
    // 학습 Flow: 수업 요약(도넛·목록) 아래.
    final flowTop = math.max(
          hasDonut ? donutCy + donutR + 6 : summaryBodyTop + 18,
          legendBottomY + 6,
        ) +
        8;
    final ix = summaryRect.left + pad;
    final iw = summaryRect.width - pad * 2;
    // 카드 아래는 특이 사항. Flow는 그 위에서 끝낸다.
    const notesBand = 52.0;
    final limitY = summaryRect.bottom - notesBand;
    divider(g, ix, ix + iw, flowTop - 7);
    var ry = flowTop;
    text(g, '학습 Flow', 'smallBold', _RefinedInk.secondary, ix, ry, iw);
    ry += 15;
    final rec = payload.lessonRecord;
    if (rec != null && rec.problemRecordCoverage == 'partial' && ry + 12 <= limitY) {
      text(g, '* 문항 기록이 없는 교재는 문항 수에서 빠짐', 'tiny',
          _RefinedInk.tertiary, ix, ry, iw);
      ry += 12;
    }
    var flowBottom = ry;
    if (rec == null || rec.flows.isEmpty) {
      if (ry + 13 <= limitY) {
        text(g, '오늘 과제에 연결된 Flow 없음', 'small', _RefinedInk.tertiary, ix,
            ry, iw);
        flowBottom = ry + 13;
      }
    } else {
      final nameCounts = <String, int>{};
      for (final f in rec.flows) {
        final key = '${f.flowName}|${f.bookName ?? ''}';
        nameCounts[key] = (nameCounts[key] ?? 0) + 1;
      }
      String flowLabel(LessonRecordFlowProgress f) {
        final flowName = f.flowName.trim().isEmpty ? 'Flow' : f.flowName.trim();
        final book = (f.bookName ?? '').trim();
        if (book.isEmpty) return flowName;
        final grade = (f.gradeLabel ?? '').trim();
        final dup = (nameCounts['${f.flowName}|${f.bookName ?? ''}'] ?? 0) > 1;
        return dup && grade.isNotEmpty
            ? '$flowName · $book ($grade)'
            : '$flowName · $book';
      }

      void drawFlowItem(
          LessonRecordFlowProgress flow, double x, double y, double w) {
        final pct = flow.progressPercent;
        final todayPct = pct == null
            ? 0.0
            : (flow.todayPercent ?? 0).clamp(
                0.0, 100.0 - (flow.beforePercent ?? pct).clamp(0.0, 100.0));
        final rightText = pct == null
            ? (flow.completed ? '완료' : '진행 중')
            : '${pct.round()}%';
        final rightW = widthOf(rightText, 'smallBold') + 2;
        final todayText =
            pct != null && todayPct > 0 ? '+${todayPct.round()}%' : '';
        final todayW =
            todayText.isEmpty ? 0.0 : widthOf(todayText, 'smallBold') + 2;
        text(g, flowLabel(flow), 'rowTitle', _RefinedInk.ink, x, y,
            math.max(0.0, w - rightW - todayW - 10));
        text(
            g,
            rightText,
            'smallBold',
            pct == null && flow.completed
                ? _RefinedInk.accent
                : _RefinedInk.secondary,
            x + w - rightW,
            y + 1,
            rightW,
            format: rightAlign);
        if (todayW > 0) {
          text(g, todayText, 'smallBold', _RefinedInk.accent,
              x + w - rightW - 4 - todayW, y + 1, todayW,
              format: rightAlign);
        }
        if (pct != null) {
          final beforePct = (flow.beforePercent ?? pct).clamp(0.0, 100.0);
          progressBar(g,
              x: x,
              y: y + 16,
              w: w,
              previousPct: beforePct,
              todayPct: todayPct,
              h: 4);
        }
      }

      double flowRowHeight(LessonRecordFlowProgress flow) =>
          flow.progressPercent != null ? 25.0 : 17.0;

      bool flowFits(double y, double rowH, int remaining) =>
          y + rowH + (remaining > 1 ? 13 : 0) <= limitY + 6;

      // 한 줄에 들어가면 가로로 둔다. 폭이 부족하면 두 칸으로 나눠 아래로 쌓는다.
      const flowGap = 8.0;
      const minFlowW = 100.0;
      final flows = rec.flows;
      final oneRow = flows.length == 1 ||
          flows.length * minFlowW + (flows.length - 1) * flowGap <= iw;
      if (oneRow) {
        final rowH = flows.map(flowRowHeight).reduce(math.max);
        if (ry + rowH > limitY + 6) {
          overflow(g, ix, ry, iw, flows.length);
          flowBottom = ry + overflowH;
        } else {
          final itemW =
              (iw - flowGap * (flows.length - 1)) / flows.length;
          for (int i = 0; i < flows.length; i++) {
            drawFlowItem(
                flows[i], ix + i * (itemW + flowGap), ry, itemW);
          }
          flowBottom = ry + rowH;
        }
      } else {
        final colW = (iw - flowGap) / 2;
        final colY = <double>[ry, ry];
        for (int i = 0; i < flows.length; i++) {
          final col = i.isEven ? 0 : 1;
          final rowH = flowRowHeight(flows[i]);
          final y = colY[col];
          final x = ix + col * (colW + flowGap);
          final remaining = flows.length - i;
          if (!flowFits(y, rowH, remaining)) {
            overflow(g, x, y, colW, remaining);
            colY[col] = y + overflowH;
            break;
          }
          drawFlowItem(flows[i], x, y, colW);
          colY[col] = y + rowH;
        }
        flowBottom = math.max(colY[0], colY[1]);
      }
    }

    final notesTop = flowBottom + 14;
    final notesLimitY = summaryRect.bottom - 8;
    if (notesTop + 12 <= notesLimitY) {
      divider(g, ix, ix + iw, notesTop - 7);
      text(g, '특이 사항', 'smallBold', _RefinedInk.secondary, ix, notesTop, iw);
      double ny = notesTop + 15;
      if (payload.specialNotes.isEmpty) {
        text(g, '특이 사항이 없습니다.', 'sub', _RefinedInk.tertiary, ix, ny, iw);
      } else {
        for (int i = 0; i < payload.specialNotes.length; i++) {
          final remaining = payload.specialNotes.length - i;
          if (ny + 14 + (remaining > 1 ? overflowH : 0) > notesLimitY) {
            overflow(g, ix, ny, iw, remaining);
            break;
          }
          g.drawEllipse(Rect.fromLTWH(ix + 0.5, ny + 4.6, 4, 4),
              brush: sf.PdfSolidBrush(_RefinedInk.alert));
          text(g, payload.specialNotes[i], 'sub', _RefinedInk.ink, ix + 10, ny,
              iw - 10);
          ny += 14;
        }
      }
    }
  }

  // 학습 기록: 큰 숫자 네 개, 그 아래 흰 타일.
  {
    final bodyTop = cardTitle(g, recordRect, '학습 기록');
    final ix = recordRect.left + 12;
    final iw = recordRect.width - 24;
    final rec = payload.lessonRecord;
    const tileH = 39.0;
    if (rec == null) {
      text(g, '학습 기록 없음', 'body', _RefinedInk.tertiary, ix, bodyTop, iw);
    } else {
      final solved = rec.solvedProblemCount;
      final firstTry = rec.firstTryCorrectCount;
      final avgTries = rec.avgTriesToPass;
      final corrTotal = rec.correctionRequiredCount;
      final corrDone =
          math.min(rec.correctionSuccessCount ?? 0, corrTotal ?? 0);
      final accuracy = solved == null || firstTry == null || solved <= 0
          ? null
          : '${(math.min(firstTry, solved) * 100 / solved).round()}';
      // 완료 문항은 오늘 푼 문항 중 하원까지 정답인 수다. 오늘 고친 문항은 여기에 포함된다.
      final completed = rec.passedProblemCount;
      final String? paceText;
      final String paceUnit;
      if (solved == null) {
        paceText = null;
        paceUnit = '기록 없음';
      } else if (stayMs <= 0 || completed == null || completed <= 0) {
        paceText = null;
        paceUnit = '없음';
      } else {
        final minutes = stayMs / 60000 / completed;
        paceText = minutes >= 10
            ? minutes.toStringAsFixed(0)
            : minutes.toStringAsFixed(1);
        paceUnit = '분';
      }

      void valueOrEmpty(String? big, String small,
          {required double x,
          required double y,
          required double w,
          required String numFont}) {
        if (big == null) {
          text(g, small, 'sub', _RefinedInk.tertiary, x,
              y + (fonts.sizeOf(numFont) - 9) * ascent, w);
        } else {
          numberWithUnit(g, big, small,
              x: x, y: y, maxW: w, numFont: numFont);
        }
      }

      final heroW = (iw - 8) / 2;
      // 제목 잉크 6.9pt, 숫자는 좌표보다 7.5pt 아래에서 시작해 27pt에서 끝난다.
      // 제목과 숫자 사이 10pt. 숫자 하단에서 다음 제목까지는 두 줄 24pt,
      // 세 줄(수정률·최대 수정 횟수)은 카드 안에 들어가도록 18pt.
      const titleDy = -2.0;
      const numberDy = 7.4;
      const heroInkBottom = numberDy + 27.0;
      final poolLayout = rec.correctionPoolMetrics;
      final afterNumberGap = poolLayout ? 18.0 : 24.0;
      final solvedRow = <(String, String?, String)>[
        ('새로 푼 문제', solved?.toString(), solved == null ? '기록 없음' : '문항'),
        (
          '정답률',
          accuracy,
          accuracy != null ? '%' : (solved == null ? '기록 없음' : '없음'),
        ),
      ];
      final avgCell = (
        '평균 수정 횟수',
        solved == null ? null : avgTries?.toStringAsFixed(1),
        solved == null ? '기록 없음' : (avgTries == null ? '없음' : '회'),
      );
      final rows = <List<(String, String?, String)>>[solvedRow];
      if (poolLayout) {
        final String? rateText;
        final String rateUnit;
        if (corrTotal == null) {
          rateText = null;
          rateUnit = '기록 없음';
        } else if (corrTotal <= 0) {
          rateText = null;
          rateUnit = '없음';
        } else {
          rateText =
              '${(math.min(corrDone, corrTotal) * 100 / corrTotal).round()}';
          rateUnit = '%';
        }
        final maxTries = rec.maxCorrectionTries;
        rows.add([
          (
            '수정한 문제',
            corrTotal == null || corrTotal <= 0 ? null : '$corrTotal',
            corrTotal == null ? '기록 없음' : (corrTotal <= 0 ? '없음' : '문항'),
          ),
          ('수정률', rateText, rateUnit),
        ]);
        rows.add([
          avgCell,
          (
            '최대 수정 횟수',
            solved == null || maxTries == null ? null : '$maxTries',
            solved == null ? '기록 없음' : (maxTries == null ? '없음' : '회'),
          ),
        ]);
      } else {
        rows.add([
          (
            '수정한 문제',
            corrTotal == null || corrTotal <= 0 ? null : '$corrDone',
            corrTotal == null
                ? '기록 없음'
                : (corrTotal <= 0 ? '없음' : '/ $corrTotal 성공'),
          ),
          avgCell,
        ]);
      }
      final rowStep = heroInkBottom + afterNumberGap - titleDy;
      for (int r = 0; r < rows.length; r++) {
        final top = bodyTop + r * rowStep;
        for (int i = 0; i < rows[r].length; i++) {
          final x = ix + i * (heroW + 8);
          text(g, rows[r][i].$1, 'small', _RefinedInk.secondary, x,
              top + titleDy, heroW);
          valueOrEmpty(rows[r][i].$2, rows[r][i].$3,
              x: x - 0.5, y: top + numberDy, w: heroW, numFont: 'hero');
        }
      }

      final hwProblemTotal = rec.homeworkProblemTotal;
      final hwProblemSolved = rec.homeworkProblemSolved;
      final String? hwProblemText;
      final String hwProblemUnit;
      if (hwProblemTotal == null || hwProblemSolved == null) {
        hwProblemText = null;
        hwProblemUnit = rec.homeworkTotal > 0 ? '기록 없음' : '없음';
      } else if (hwProblemTotal <= 0) {
        hwProblemText = null;
        hwProblemUnit = '없음';
      } else {
        hwProblemText = '${math.min(hwProblemSolved, hwProblemTotal)}';
        hwProblemUnit = '/ $hwProblemTotal';
      }

      // 2x2: 숙제(완료·문항) 한 줄, 과제·진행속도 한 줄.
      const tileGap = 6.0;
      final tiles = <(String, String?, String)>[
        (
          '완료한 숙제',
          rec.homeworkTotal > 0 ? '${rec.homeworkCompleted}' : null,
          rec.homeworkTotal > 0 ? '/ ${rec.homeworkTotal}' : '없음',
        ),
        ('숙제로 푼 문항', hwProblemText, hwProblemUnit),
        (
          '완료한 과제',
          rec.assignmentTotal > 0 ? '${rec.assignmentCompleted}' : null,
          rec.assignmentTotal > 0 ? '/ ${rec.assignmentTotal}' : '없음',
        ),
        ('문항 당 진행속도', paceText, paceUnit),
      ];
      final tileW = (iw - tileGap) / 2;
      final tilesTop = bodyTop +
          (rows.length - 1) * rowStep +
          heroInkBottom +
          afterNumberGap;
      for (int i = 0; i < tiles.length; i++) {
        final tx = ix + (i % 2) * (tileW + tileGap);
        final ty = tilesTop + (i ~/ 2) * (tileH + tileGap);
        _refinedRoundRect(g, Rect.fromLTWH(tx, ty, tileW, tileH),
            radius: 9, brush: whiteBrush);
        text(g, tiles[i].$1, 'tiny', _RefinedInk.tertiary, tx + 9, ty + 5.5,
            tileW - 18);
        valueOrEmpty(tiles[i].$2, tiles[i].$3,
            x: tx + 9, y: ty + 16, w: tileW - 18, numFont: 'tileValue');
      }
    }
  }

  foldTicks(g, size.width, foldY);

  // ── 1쪽 아래: 숙제 리스트 · 행동 리스트 카드 ──
  const lineStep = 16.0;
  const textH = 13.6;
  const inlineGap = 6.0;
  const itemGap = 6.0;
  final lowerTop = foldY + 11;
  final halfW = (width - cardGap) / 2;
  final todoRect = Rect.fromLTRB(left, lowerTop, left + halfW, bottom);
  final behaviorRect =
      Rect.fromLTRB(left + halfW + cardGap, lowerTop, right, bottom);
  card(g, todoRect);
  card(g, behaviorRect);

  double leftY =
      cardTitle(g, todoRect, '숙제 리스트', count: payload.todoEntries.length);
  {
    final dueText = payload.dueDate == null
        ? '검사일 미정'
        : '${_formatMonthDay(payload.dueDate!)} (${_formatWeekdayKorean(payload.dueDate!)}) 검사';
    final chipW = widthOf(dueText, 'smallBold') + 16;
    final chip = Rect.fromLTWH(
        todoRect.right - pad - chipW + 4, todoRect.top + 11, chipW, 17);
    _refinedRoundRect(g, chip,
        radius: 8.5,
        brush: payload.dueDate == null
            ? whiteBrush
            : sf.PdfSolidBrush(_RefinedInk.accentSoft));
    text(
        g,
        dueText,
        'smallBold',
        payload.dueDate == null
            ? _RefinedInk.secondary
            : _RefinedInk.accentDeep,
        chip.left,
        chip.top + 2.8,
        chip.width,
        format: centerAlign);
  }

  final todoX = todoRect.left + pad;
  final todoW = todoRect.width - pad * 2;
  final todoLimit = todoRect.bottom - 12;
  final todoEntries = payload.todoEntries;
  if (todoEntries.isEmpty) {
    text(g, '숙제 없음', 'body', _RefinedInk.tertiary, todoX, leftY, todoW);
  }
  for (int i = 0; i < todoEntries.length; i++) {
    final entry = todoEntries[i];
    const cardH = lineStep * 2 + textH;
    final remaining = todoEntries.length - i;
    if (leftY + cardH + (remaining > 1 ? overflowH + itemGap : 0) >
        todoLimit) {
      overflow(g, todoX, leftY, todoW, remaining);
      break;
    }
    final prim = entry.primary;
    final hasCheckbox = prim.startsWith('□');
    if (hasCheckbox) checkbox(g, todoX, leftY + 1.8);
    final textX = todoX + (hasCheckbox ? 18.0 : 0.0);
    final textW = math.max(0.0, todoX + todoW - textX);

    final rightPrimary = (entry.rightPrimary ?? '').trim();
    final rightPrimaryText = rightPrimary.isEmpty ? '' : '$rightPrimary 출제';
    final rightPrimaryW = rightPrimaryText.isEmpty
        ? 0.0
        : math.min(widthOf(rightPrimaryText, 'small') + 2, textW * 0.32);
    final bookTitle = (entry.bookTitle ?? '').trim();
    final line1 = bookTitle.isNotEmpty
        ? bookTitle
        : (hasCheckbox ? prim.replaceFirst(RegExp(r'^□\s*'), '') : prim);
    await _refinedDrawRich(g, line1, fonts['bodyBold'],
        fontSize: 10,
        bold: true,
        pdfColor: _RefinedInk.ink,
        color: _RefinedInk.inkColor,
        bounds: Rect.fromLTWH(textX, leftY, 
            math.max(0.0, textW - rightPrimaryW - inlineGap), textH));
    if (rightPrimaryW > 0) {
      text(g, rightPrimaryText, 'small', _RefinedInk.tertiary,
          textX + textW - rightPrimaryW, leftY + 1, rightPrimaryW,
          format: rightAlign);
    }

    final secondary = (entry.secondary ?? '').trim();
    final rightSecondary = (entry.rightSecondary ?? '').trim();
    final rightSecondaryW = rightSecondary.isEmpty
        ? 0.0
        : math.min(widthOf(rightSecondary, 'smallBold') + 2, textW * 0.55);
    if (secondary.isNotEmpty) {
      await _refinedDrawRich(g, secondary, fonts['sub'],
          fontSize: 9,
          bold: false,
          pdfColor: _RefinedInk.secondary,
          color: _RefinedInk.secondaryColor,
          bounds: Rect.fromLTWH(textX, leftY + lineStep,
              math.max(0.0, textW - rightSecondaryW - inlineGap), textH));
    }
    if (rightSecondaryW > 0) {
      text(g, rightSecondary, 'smallBold', _RefinedInk.secondary,
          textX + textW - rightSecondaryW, leftY + lineStep + 1,
          rightSecondaryW,
          format: rightAlign);
    }

    final tertiary = (entry.tertiary ?? '').trim();
    final rightTertiary = (entry.rightTertiary ?? '').trim();
    final rightTertiaryW = rightTertiary.isEmpty
        ? 0.0
        : math.min(widthOf(rightTertiary, 'small') + 2, textW * 0.5);
    text(g, tertiary, 'small', _RefinedInk.tertiary, textX,
        leftY + lineStep * 2 + 1,
        math.max(0.0, textW - rightTertiaryW - inlineGap));
    if (rightTertiaryW > 0) {
      text(g, rightTertiary, 'small', _RefinedInk.accentDeep,
          textX + textW - rightTertiaryW, leftY + lineStep * 2 + 1,
          rightTertiaryW,
          format: rightAlign);
    }
    leftY += cardH + itemGap;
    if (i < todoEntries.length - 1) divider(g, textX, todoX + todoW, leftY);
    leftY += itemGap;
  }

  double rightY = cardTitle(g, behaviorRect, '행동 리스트',
      count: payload.behaviorEntries.length);
  final behX = behaviorRect.left + pad;
  final behW = behaviorRect.width - pad * 2;
  final behLimit = behaviorRect.bottom - 12;
  final behaviorEntries = payload.behaviorEntries;
  if (behaviorEntries.isEmpty) {
    text(g, '행동 없음', 'body', _RefinedInk.tertiary, behX, rightY, behW);
  }
  for (int i = 0; i < behaviorEntries.length; i++) {
    final entry = behaviorEntries[i];
    final secondary = (entry.secondary ?? '').trim();
    final rowH = (secondary.isNotEmpty ? lineStep : 0) + textH;
    final remaining = behaviorEntries.length - i;
    if (rightY + rowH + (remaining > 1 ? overflowH + itemGap : 0) >
        behLimit) {
      overflow(g, behX, rightY, behW, remaining);
      break;
    }
    var primary = entry.primary;
    final hasCheckbox = primary.startsWith('□');
    primary = primary.replaceFirst(RegExp(r'^□\s*'), '');
    String? level;
    final levelMatch = RegExp(r'\s·\s(lv\.\d+)$').firstMatch(primary);
    if (levelMatch != null) {
      level = levelMatch.group(1);
      primary = primary.substring(0, levelMatch.start);
    }
    if (hasCheckbox) checkbox(g, behX, rightY + 1.8);
    final textX = behX + (hasCheckbox ? 18.0 : 0.0);
    final textW = math.max(0.0, behX + behW - textX);
    double levelW = 0;
    if (level != null) {
      final label = level.toUpperCase().replaceAll('.', ' ');
      levelW = widthOf(label, 'smallBold') + 12;
      final chip = Rect.fromLTWH(textX + textW - levelW, rightY, levelW, 14);
      _refinedRoundRect(g, chip, radius: 7, brush: whiteBrush);
      text(g, label, 'smallBold', _RefinedInk.secondary, chip.left,
          chip.top + 1.8, chip.width,
          format: centerAlign);
    }
    text(g, primary, 'bodyBold', _RefinedInk.ink, textX, rightY,
        textW - levelW - (levelW > 0 ? inlineGap : 0));
    if (secondary.isNotEmpty) {
      text(g, secondary, 'small', _RefinedInk.secondary, textX,
          rightY + lineStep + 1, textW);
    }
    rightY += rowH + itemGap;
    if (i < behaviorEntries.length - 1) divider(g, textX, behX + behW, rightY);
    rightY += itemGap;
  }

  // ── 2쪽: 학습 내역 ──
  final page2 = doc.pages.add();
  final g2 = page2.graphics;
  final size2 = page2.getClientSize();
  final right2 = size2.width - 10;
  final width2 = right2 - left;
  final bottom2 = size2.height - 6;
  final foldY2 = size2.height / 2 + _todoSheetFoldDrop;

  text(g2, '학습 내역', 'pageTitle', _RefinedInk.ink, left - 0.5, 6, 200);
  text(
      g2,
      [
        payload.studentName.trim(),
        _refinedLongDate(payload.classDateTime),
      ].where((s) => s.isNotEmpty).join('  ·  '),
      'small',
      _RefinedInk.tertiary,
      left,
      13,
      width2,
      format: rightAlign);
  foldTicks(g2, size2.width, foldY2);

  const p2Top = 38.0;
  final p2Half = (width2 - cardGap) / 2;
  final doneRect = Rect.fromLTRB(left, p2Top, left + p2Half, foldY2 - 11);
  final classRect =
      Rect.fromLTRB(left + p2Half + cardGap, p2Top, right2, foldY2 - 11);
  final checkRect =
      Rect.fromLTRB(left, foldY2 + 11, left + p2Half, bottom2);
  card(g2, doneRect);
  card(g2, classRect);
  card(g2, checkRect);

  // 오늘 완료한 과제
  {
    double y = cardTitle(g2, doneRect, '오늘 완료한 과제',
        count: payload.completedSummaries.length);
    final x = doneRect.left + pad;
    final w = doneRect.width - pad * 2;
    final limit = doneRect.bottom - 12;
    final completed = payload.completedSummaries;
    if (completed.isEmpty) {
      text(g2, '완료 과제 없음', 'body', _RefinedInk.tertiary, x, y, w);
    }
    const cardH = lineStep * 2 + textH + 3 + 4.6;
    for (int i = 0; i < completed.length; i++) {
      final cs = completed[i];
      final remaining = completed.length - i;
      if (y + cardH + (remaining > 1 ? overflowH + itemGap : 0) > limit) {
        overflow(g2, x, y, w, remaining);
        break;
      }
      final bookText =
          cs.bookAndCourse.trim().isEmpty ? '-' : cs.bookAndCourse.trim();
      final groupText =
          cs.groupTitle.trim().isEmpty ? '(제목 없음)' : cs.groupTitle.trim();
      final totalPctText = '${cs.totalProgressPct.toStringAsFixed(0)}%';
      final totalPctW = widthOf(totalPctText, 'bodyBold') + 2;
      await _refinedDrawRich(g2, bookText, fonts['bodyBold'],
          fontSize: 10,
          bold: true,
          pdfColor: _RefinedInk.ink,
          color: _RefinedInk.inkColor,
          bounds: Rect.fromLTWH(x, y, w - totalPctW - inlineGap, textH));
      text(g2, totalPctText, 'bodyBold', _RefinedInk.ink, x + w - totalPctW, y,
          totalPctW,
          format: rightAlign);
      final todayText = '오늘 +${cs.progressPct.toStringAsFixed(0)}%';
      final todayW = widthOf(todayText, 'smallBold') + 2;
      await _refinedDrawRich(g2, groupText, fonts['sub'],
          fontSize: 9,
          bold: false,
          pdfColor: _RefinedInk.secondary,
          color: _RefinedInk.secondaryColor,
          bounds: Rect.fromLTWH(
              x, y + lineStep, w - todayW - inlineGap, textH));
      text(g2, todayText, 'smallBold', _RefinedInk.accent, x + w - todayW,
          y + lineStep + 1, todayW,
          format: rightAlign);
      final totalMin = (cs.totalMs / 60000).round();
      text(
          g2,
          [
            '누적 $totalMin분',
            '${cs.assignmentCount}회 출제',
            '${cs.checkCount}회 검사',
          ].join(' · '),
          'small',
          _RefinedInk.tertiary,
          x,
          y + lineStep * 2 + 1,
          w);
      progressBar(g2,
          x: x,
          y: y + lineStep * 2 + textH + 3,
          w: w,
          previousPct: cs.previousProgressPct,
          todayPct: cs.progressPct);
      y += cardH + itemGap;
      if (i < completed.length - 1) divider(g2, x, x + w, y);
      y += itemGap;
    }
  }

  // 수업
  {
    double y = cardTitle(g2, classRect, '수업',
        count: payload.classWorkEntries.length);
    final x = classRect.left + pad;
    final w = classRect.width - pad * 2;
    final limit = classRect.bottom - 12;
    final lines = payload.classWorkEntries;
    if (lines.isEmpty) {
      text(g2, '오늘 수행 기록 없음', 'body', _RefinedInk.tertiary, x, y, w);
    }
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final groupTitle = line.title.trim();
      final subCount = line.subEntries.length;
      final lastOffset = subCount == 0
          ? (groupTitle.isNotEmpty ? lineStep : 0.0)
          : lineStep * (1 + subCount);
      final cardH = lastOffset + textH;
      final remaining = lines.length - i;
      if (y + cardH + (remaining > 1 ? overflowH + itemGap : 0) > limit) {
        overflow(g2, x, y, w, remaining);
        break;
      }
      final timeText =
          line.studyMs > 0 ? _formatDurationKorean(line.studyMs) : '';
      final timeW = timeText.isEmpty ? 0.0 : widthOf(timeText, 'bodyBold') + 2;
      final bookText = line.bookAndCourse.trim();
      if (bookText.isNotEmpty) {
        await _refinedDrawRich(g2, bookText, fonts['bodyBold'],
            fontSize: 10,
            bold: true,
            pdfColor: _RefinedInk.ink,
            color: _RefinedInk.inkColor,
            bounds: Rect.fromLTWH(
                x, y, math.max(0.0, w - timeW - inlineGap), textH));
      }
      if (timeW > 0) {
        text(g2, timeText, 'bodyBold', _RefinedInk.ink, x + w - timeW, y,
            timeW,
            format: rightAlign);
      }
      if (groupTitle.isNotEmpty) {
        await _refinedDrawRich(g2, groupTitle, fonts['sub'],
            fontSize: 9,
            bold: false,
            pdfColor: _RefinedInk.secondary,
            color: _RefinedInk.secondaryColor,
            bounds: Rect.fromLTWH(x, y + lineStep, w, textH));
      }
      var lineY = y + lineStep * 2;
      for (final sub in line.subEntries) {
        if (lineY + textH > limit) break;
        final subText = [
          sub.title,
          if (_formatPageTextCompact(sub.page) != '-')
            _formatPageTextCompact(sub.page),
          if (_formatCountText(sub.count) != '-') _formatCountText(sub.count),
        ].join(' · ');
        g2.drawEllipse(Rect.fromLTWH(x + 1, lineY + 5.2, 3, 3),
            brush: sf.PdfSolidBrush(_RefinedInk.before));
        text(g2, subText, 'small', _RefinedInk.tertiary, x + 9, lineY + 1,
            w - 9);
        lineY += lineStep;
      }
      y += cardH + itemGap;
      if (i < lines.length - 1) divider(g2, x, x + w, y);
      y += itemGap;
    }
  }

  // 숙제 검사 내역 (아래 오른쪽은 비워 둔다)
  {
    final visibleCount =
        payload.checkRates.where((e) => e.progress != null).length;
    double y = cardTitle(g2, checkRect, '숙제 검사 내역', count: visibleCount);
    final x = checkRect.left + pad;
    final w = checkRect.width - pad * 2;
    final limit = checkRect.bottom - 12;
    final hasCheckData = payload.checkRates.any((e) => e.progress != null);
    if (hasCheckData) {
      int sumTodayPct = 0;
      int sumRemainingPct = 0;
      for (final cr in payload.checkRates) {
        if (cr.progress == null) continue;
        sumTodayPct += (cr.todayProgress ?? 0);
        if (!cr.isExtra) {
          sumRemainingPct += math.max(0, 100 - (cr.previousProgress ?? 0));
        }
      }
      final ratioPct = sumRemainingPct > 0
          ? ((sumTodayPct * 100) / sumRemainingPct).round()
          : (sumTodayPct > 0 ? 101 : 0);
      final mood = _todoCheckMoodFor(ratioPct);
      final moodText = '${mood.label} $ratioPct%';
      const emSize = 15.0;
      final pillW = widthOf(moodText, 'mood') + emSize + 22;
      final pill = Rect.fromLTWH(
          checkRect.right - pad - pillW + 4, checkRect.top + 10, pillW, 20);
      _refinedRoundRect(g2, pill, radius: 10, brush: whiteBrush);
      final emojiBmp = await _loadTodoEmojiBitmap(mood.asset);
      if (emojiBmp != null) {
        final emRect =
            Rect.fromLTWH(pill.left + 6, pill.top + 2.5, emSize, emSize);
        g2.drawImage(emojiBmp, emRect);
        if (mood.fire) {
          final flameBmp =
              await _loadTodoEmojiBitmap('assets/emoji/flame.png');
          if (flameBmp != null) {
            g2.drawImage(flameBmp,
                Rect.fromLTWH(emRect.right - 7, emRect.top - 4, 10, 10));
          }
        }
      }
      text(g2, moodText, 'mood', _RefinedInk.ink, pill.left + emSize + 11,
          pill.top + 4, pillW - emSize - 14);
    }

    if (!hasCheckData) {
      text(g2, '검사 내역 없음', 'body', _RefinedInk.tertiary, x, y, w);
    } else {
      final rows = payload.checkRates;
      const cardH = lineStep * 2 + textH + 3 + 4.6;
      for (int i = 0; i < rows.length; i++) {
        final cr = rows[i];
        final remaining = rows.length - i;
        if (y + cardH + (remaining > 1 ? overflowH + itemGap : 0) > limit) {
          overflow(g2, x, y, w, remaining);
          break;
        }
        final bookText = cr.bookAndCourse.trim();
        final groupText = cr.title.trim();
        final titleText = bookText.isEmpty && groupText.isEmpty
            ? '(제목 없음)'
            : bookText.isEmpty
                ? groupText
                : groupText.isEmpty
                    ? bookText
                    : '$bookText · $groupText';
        final todayPct = cr.todayProgress ?? 0;
        final previousPct = cr.previousProgress ?? 0;
        final missedLabel = switch (cr.outcome) {
          'left_behind' => '숙제 안 함 (두고 옴)',
          'not_done' => '숙제 안 함',
          _ => null,
        };
        final pctText = missedLabel ?? '+$todayPct%';
        final pctW = widthOf(pctText, 'smallBold') + 2;
        final pctColor = missedLabel != null
            ? _RefinedInk.alert
            : (todayPct > 0 ? _RefinedInk.accent : _RefinedInk.secondary);
        await _refinedDrawRich(g2, titleText, fonts['rowTitle'],
            fontSize: 9.4,
            bold: true,
            pdfColor: _RefinedInk.ink,
            color: _RefinedInk.inkColor,
            bounds: Rect.fromLTWH(x, y, w - pctW - inlineGap, textH));
        text(g2, pctText, 'smallBold', pctColor, x + w - pctW, y + 1, pctW,
            format: rightAlign);

        final line2 = [
          if (_formatPageTextCompact(cr.page) != '-')
            _formatPageTextCompact(cr.page),
          if (_formatCountText(cr.count) != '-') _formatCountText(cr.count),
        ].join(' · ');
        text(g2, line2, 'sub', _RefinedInk.secondary, x, y + lineStep, w);

        final line3Left = [
          '내준 ${cr.assignedAt != null ? _formatMonthDay(cr.assignedAt!) : '-'}',
          '마감 ${cr.dueDate != null ? _formatMonthDay(cr.dueDate!) : '-'}',
        ].join(' · ');
        final line3Right =
            '검사 ${cr.checkedAt != null ? _formatMonthDay(cr.checkedAt!) : '-'}';
        final line3RightW = widthOf(line3Right, 'small') + 2;
        text(g2, line3Left, 'small', _RefinedInk.tertiary, x,
            y + lineStep * 2 + 1, math.max(0.0, w - line3RightW - inlineGap));
        text(g2, line3Right, 'small', _RefinedInk.tertiary,
            x + w - line3RightW, y + lineStep * 2 + 1, line3RightW,
            format: rightAlign);
        progressBar(g2,
            x: x,
            y: y + lineStep * 2 + textH + 3,
            w: w,
            previousPct: previousPct.toDouble(),
            todayPct: todayPct.toDouble());
        y += cardH + itemGap;
        if (i < rows.length - 1) divider(g2, x, x + w, y);
        y += itemGap;
      }
    }
  }

  final bytes = await doc.save();
  doc.dispose();
  return bytes;
}
