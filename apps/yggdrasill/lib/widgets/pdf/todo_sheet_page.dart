part of '../homework_assign_dialog.dart';

/// 저장된 알림장 JSON을 종이 알림장과 같은 배치로 연다.
/// 종이에서 잘리는 목록은 `외 N개`를 눌러 펼친다.
class TodoSheetPage extends StatefulWidget {
  const TodoSheetPage({super.key, required this.snapshotId});

  final String snapshotId;

  @override
  State<TodoSheetPage> createState() => _TodoSheetPageState();
}

class _SheetInk {
  const _SheetInk({
    required this.page,
    required this.ink,
    required this.secondary,
    required this.tertiary,
    required this.card,
    required this.before,
    required this.accent,
    required this.accentSoft,
    required this.accentDeep,
    required this.alert,
    required this.checkbox,
    required this.white,
    required this.rest,
  });

  final Color page;
  final Color ink;
  final Color secondary;
  final Color tertiary;
  final Color card;
  final Color before;
  final Color accent;
  final Color accentSoft;
  final Color accentDeep;
  final Color alert;
  final Color checkbox;

  /// 카드 위의 칸·막대·체크. 라이트에서는 흰색이다.
  final Color white;
  final Color rest;

  static const light = _SheetInk(
    page: Color(0xFFFFFFFF),
    ink: Color(0xFF1D1D1F),
    secondary: Color(0xFF636369),
    tertiary: Color(0xFF8E8E94),
    card: Color(0xFFF3F3F6),
    before: Color(0xFFC2C2C9),
    accent: Color(0xFF1CA058),
    accentSoft: Color(0xFFDCF1E4),
    accentDeep: Color(0xFF106C38),
    alert: Color(0xFFD64248),
    checkbox: Color(0xFFA8A8B0),
    white: Color(0xFFFFFFFF),
    rest: Color(0xFFD0D0D6),
  );

  static const dark = _SheetInk(
    page: Color(0xFF000000),
    ink: Color(0xFFFFFFFF),
    secondary: Color(0xB3FFFFFF),
    tertiary: Color(0xFF8E8E93),
    card: Color(0xFF1C1C1E),
    before: Color(0xFF636366),
    accent: Color(0xFF33A373),
    accentSoft: Color(0xFF1A3A2A),
    accentDeep: Color(0xFF8FD9B0),
    alert: Color(0xFFFF6B6B),
    checkbox: Color(0xFF8E8E93),
    white: Color(0xFF2C2C2E),
    rest: Color(0xFF3A3A3C),
  );

  static _SheetInk of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }
}

String _todoSheetPageFontFamily() =>
    Platform.isWindows ? 'Malgun Gothic' : 'KakaoSmallSans';

class _TodoSheetPageState extends State<TodoSheetPage> {
  _TodoSheetPayload? _payload;
  String _studentId = '';
  Object? _error;
  final Set<String> _open = <String>{};

  _SheetInk get _ink => _SheetInk.of(context);

  static const _clientH = 841.89 - 18;
  static const _widthScale = 1.3;
  static const _clientW = (595.28 - 36) * _widthScale;
  static const _inset = 10.0 * _widthScale;
  static const _foldY = _clientH / 2 + 4 * 72 / 25.4;
  static const _upperTop = 105.0;
  static const _upperH = _foldY - 16.5 - _upperTop;
  static const _lowerTop = _foldY + 11;
  static const _lowerH = _clientH - 6 - _lowerTop;
  static const _contentW = _clientW - _inset * 2;
  static const _summaryW = 332.0 * _widthScale;
  static const _gap = 10.0 * _widthScale;

  /// 종이 좌표를 화면에 그릴 때 쓰는 배율. 글자는 이 배율로 나눈 뒤 넣어야
  /// 하단에 보이는 크기가 다이얼로그 글자와 같다.
  static const _screenScale = 16 / 10;

  static Future<void>? _sheetFont;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static Future<void> _ensureSheetFont() {
    final pending = _sheetFont;
    if (pending != null) return pending;
    final loading = _loadSheetFont();
    _sheetFont = loading;
    return loading;
  }

  static Future<void> _loadSheetFont() async {
    if (!Platform.isWindows) return;
    try {
      final loader = FontLoader('Malgun Gothic');
      Future<ByteData> read(String path) async {
        final bytes = await File(path).readAsBytes();
        return ByteData.sublistView(bytes);
      }

      loader.addFont(read(r'C:\Windows\Fonts\malgun.ttf'));
      loader.addFont(read(r'C:\Windows\Fonts\malgunbd.ttf'));
      await loader.load();
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      await _ensureSheetFont();
      final loaded = await TodoSheetSnapshotService.instance
          .loadForPage(widget.snapshotId.trim());
      if (!mounted) return;
      setState(() {
        _studentId = loaded.studentId;
        _payload = _todoSheetPayloadFromSnapshotJson(
          loaded.payload,
          academyLogo: DataManager.instance.academySettings.logo,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  void _toggle(String key) {
    setState(() {
      if (!_open.add(key)) _open.remove(key);
    });
  }

  TextStyle _nameStyle(Color color) {
    return TextStyle(
      fontSize: 32 / _screenScale,
      height: 1.15,
      color: color,
      fontWeight: FontWeight.w700,
      fontFamily: _todoSheetPageFontFamily(),
    );
  }

  /// 화면에 보이는 픽셀. 종이 좌표는 [_screenScale]로 줄어 있다.
  double get _screenPx => 1 / _screenScale;

  /// 작은 글씨 16에 맞춘 줄 사이. 예전 13 기준 3에서 키운 값.
  double get _lineGap => 4 * _screenPx;

  /// 홈·커리큘럼·문제은행과 같은 페이지 제목 줄. 위에서 12, 높이 56.
  static const double _pageTitleTop =
      FabTabBarTokens.previewAcademyTopInset - 12;
  static const double _pageTitleBandHeight = FabTabBarTokens.fabBarHeight;
  static const double _pageTitleLineHeight =
      FabTabBarTokens.previewAcademyMainTitleFontSize * 1.15;

  /// 제목 글자 아래에서 종이까지 16.
  double get _sheetTop =>
      _pageTitleTop +
      (_pageTitleBandHeight - _pageTitleLineHeight) / 2 +
      _pageTitleLineHeight +
      16;

  TextStyle _screenPageTitleStyle() {
    return FabTabBarTokens.previewAcademyMainTitleStyle(
      PreviewAcademyPanelStyle.forBrightness(Theme.of(context).brightness),
    );
  }

  /// 제목에 수식이 있으면 학습 화면과 같이 2차원으로 그린다.
  /// 한글 줄높이는 그대로 두고, 수식만 그 줄 가운데에 키만큼 둔다.
  Widget _sheetText(
    String text, {
    required TextStyle style,
    int? maxLines,
    TextOverflow overflow = TextOverflow.ellipsis,
  }) {
    final normalized = normalizeTodoSheetMath(text);
    if (!todoSheetMathNeedsPaint(normalized)) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: maxLines == null ? TextOverflow.clip : overflow,
        softWrap: maxLines == null || maxLines > 1,
      );
    }
    return _SheetMathLine(
      text: normalized,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  /// 종이 11.2pt 이상은 화면 20, 그 아래는 16.
  /// 리스트 제목은 굵기 800, 내용은 600.
  /// 큰 글씨 줄높이 1.2, 작은 글씨 1.25.
  TextStyle _ts(double size, Color color, {bool bold = false, bool title = false}) {
    final large = size >= 11.2;
    return TextStyle(
      fontSize: (large ? 20.0 : 16.0) / _screenScale,
      height: large ? 1.2 : 1.25,
      color: color,
      fontWeight: title ? FontWeight.w800 : FontWeight.w600,
      fontFamily: _todoSheetPageFontFamily(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _ink.page,
      body: Stack(
        children: [
          Positioned.fill(
            child: _payload == null
                ? Padding(
                    padding: EdgeInsets.only(top: _sheetTop),
                    child: _status(),
                  )
                : _sheet(_payload!),
          ),
          Positioned(
            top: _pageTitleTop,
            left: 24,
            right: 24,
            height: _pageTitleBandHeight,
            child: _pageTitleBar(),
          ),
        ],
      ),
    );
  }

  Widget _pageTitleBar() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SharedBackButton(
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 16),
        IgnorePointer(
          child: Text('학습 리포트', style: _screenPageTitleStyle()),
        ),
        const Spacer(),
        SolidCapsuleActionBar(
          children: [
            SolidCapsuleActionButton(
              tooltip: '이전 알림장',
              iconBuilder: (color, size) => SvgPicture.string(
                pastTodoSheetSvg,
                width: size,
                height: size,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
              onPressed: () {
                final studentId = _studentId.trim();
                if (studentId.isEmpty) {
                  showAppSnackBar(context, '이전 알림장을 불러오지 못했어요');
                  return;
                }
                final name = _payload?.studentName.trim() ?? '';
                unawaited(
                  showPastTodoSheetsDialog(
                    context,
                    studentId: studentId,
                    studentName: name.isEmpty ? '학생' : name,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _status() {
    if (_error != null) {
      return Center(
        child: Text('알림장을 열지 못했어요', style: _ts(14, _ink.secondary)),
      );
    }
    return Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: _ink.accent,
        ),
      ),
    );
  }

  Widget _sheet(_TodoSheetPayload payload) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(payload),
          const SizedBox(height: 10),
          _timeStrip(payload),
          const SizedBox(height: 10),
          _upper(payload),
          const SizedBox(height: 16),
          _page2(payload),
          const SizedBox(height: 16),
          _lower(payload),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 종이 본문 10pt → 홈 메뉴 본문 16pt. 칸·여백도 같은 배율이다.
        const homeScale = 16 / 10;
        final scale = math.min(homeScale, constraints.maxWidth / _clientW);
        return ScrollConfiguration(
          behavior:
              ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(0, _sheetTop, 0, 28),
            child: Center(
              child: SizedBox(
                width: _clientW * scale,
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.topCenter,
                  child: SizedBox(width: _clientW, child: body),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(_TodoSheetPayload payload) {
    final name =
        payload.studentName.trim().isEmpty ? '-' : payload.studentName.trim();
    final classTime = payload.classTimeText
        .replaceAll(RegExp(r'^\(|\)$'), '')
        .replaceFirst(RegExp(r'^[월화수목금토일]\s+'), '')
        .replaceAll(' - ', ' – ')
        .trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(name, style: _nameStyle(_ink.ink)),
            const SizedBox(width: 9),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _sheetText(
                payload.className.trim(),
                maxLines: 1,
                style: _ts(10, _ink.secondary),
              ),
            ),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_refinedLongDate(payload.classDateTime),
                    style: _ts(12, _ink.ink, bold: true)),
                if (classTime.isNotEmpty)
                  Text('수업 $classTime', style: _ts(9, _ink.secondary)),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _timeStrip(_TodoSheetPayload payload) {
    final arr = payload.arrivalTime;
    final dep = payload.departureTime;
    final stayMs = arr != null && dep.isAfter(arr)
        ? dep.difference(arr).inMilliseconds
        : 0;
    final cells = <(String, String)>[
      ('등원', _formatTime(arr)),
      ('하원', _formatTime(dep)),
      ('학습 시간', payload.learningTimeText),
      ('머문 시간', stayMs > 0 ? _formatDurationKorean(stayMs) : ''),
    ];
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: _ink.card,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0)
              Container(width: 1, height: 22, color: _ink.white),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cells[i].$1, style: _ts(7.8, _ink.tertiary)),
                    Text(
                      cells[i].$2.trim().isEmpty ? '-' : cells[i].$2,
                      style: _ts(
                        12.4,
                        cells[i].$2.trim().isEmpty
                            ? _ink.tertiary
                            : _ink.ink,
                        bold: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _upper(_TodoSheetPayload payload) {
    const recordW = _contentW - _gap - _summaryW;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: _summaryW, child: _summaryCard(payload)),
        const SizedBox(width: _gap),
        SizedBox(width: recordW, child: _recordCard(payload)),
      ],
    );
  }

  Widget _summaryCard(_TodoSheetPayload payload) {
    final legendMax = math.max(88.0, _upperH - 38 - 112);
    return _card(
      minHeight: _upperH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('수업 요약', style: _ts(11.2, _ink.ink, title: true)),
            const SizedBox(height: 12),
            _donutBlock(payload, legendMax),
            const SizedBox(height: 10),
            Container(height: 1, color: _ink.white),
            const SizedBox(height: 8),
            Text('학습 Flow', style: _ts(8.4, _ink.secondary, title: true)),
            const SizedBox(height: 6),
            if (payload.lessonRecord?.problemRecordCoverage == 'partial')
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('* 문항 기록이 없는 교재는 문항 수에서 빠짐',
                    style: _ts(7.6, _ink.tertiary)),
              ),
            _flows(payload),
            const SizedBox(height: 10),
            Text('특이 사항', style: _ts(8.4, _ink.secondary, title: true)),
            const SizedBox(height: 6),
            _notes(payload),
          ],
        ),
      ),
    );
  }

  Widget _donutBlock(_TodoSheetPayload payload, double legendMax) {
    final arr = payload.arrivalTime;
    final dep = payload.departureTime;
    final stayMs = arr != null && dep.isAfter(arr)
        ? dep.difference(arr).inMilliseconds
        : 0;
    final breakMs = math.max(0, stayMs - payload.learningMs);
    final hasDonut =
        payload.classWorkEntries.isNotEmpty || payload.learningMs > 0;
    if (!hasDonut) {
      return Text('오늘 수행 기록 없음', style: _ts(10, _ink.tertiary));
    }
    const palette = <Color>[
      Color(0xFF2EAA68),
      Color(0xFF4080EE),
      Color(0xFFF4A330),
      Color(0xFF9268E6),
      Color(0xFF1EB6C4),
      Color(0xFFEC5C62),
      Color(0xFFAA8460),
      Color(0xFF5C68E2),
    ];
    final slices = <({String label, int ms, String? check, String? total, Color color})>[];
    for (var i = 0; i < payload.classWorkEntries.length; i++) {
      final entry = payload.classWorkEntries[i];
      if (entry.studyMs <= 0) continue;
      final checks = entry.totalCheckCount;
      final check = checks <= 0
          ? (entry.passed ? '검사 없이 통과' : '검사 전')
          : (entry.passed ? '$checks회 검사 후 통과' : '$checks회 검사 · 진행 중');
      final totalMin = (entry.totalAccumulatedMs / 60000).round();
      slices.add((
        label: entry.title,
        ms: entry.studyMs,
        check: check,
        total: totalMin > 0 ? '누적 $totalMin분' : null,
        color: palette[i % palette.length],
      ));
    }
    if (breakMs > 0) {
      slices.add((
        label: '휴식',
        ms: breakMs,
        check: null,
        total: null,
        color: _ink.rest,
      ));
    }
    final totalMin = (payload.learningMs / 60000).round();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(120, 120),
                painter: _DonutPainter(
                  slices.map((e) => (e.ms, e.color)).toList(),
                  _ink,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: '$totalMin',
                        style: _ts(22, _ink.ink, bold: true)),
                    TextSpan(
                        text: ' 분', style: _ts(8.6, _ink.secondary)),
                  ])),
                  Text('학습', style: _ts(7.6, _ink.tertiary)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _SheetOverflow(
            maxHeight: legendMax,
            expanded: _open.contains('legend'),
            onToggle: () => _toggle('legend'),
            children: [
              for (final slice in slices) _legendRow(slice),
            ],
          ),
        ),
      ],
    );
  }

  Widget _legendRow(
    ({String label, int ms, String? check, String? total, Color color}) slice,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 3),
            decoration: BoxDecoration(
              color: slice.color,
              borderRadius: BorderRadius.circular(2.4),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _sheetText(
                        slice.label,
                        maxLines: 1,
                        style: _ts(9.4, _ink.ink, bold: true),
                      ),
                    ),
                    Text('${(slice.ms / 60000).round()}분',
                        style: _ts(9.4, _ink.ink, bold: true)),
                  ],
                ),
                if (slice.check != null || slice.total != null) ...[
                  SizedBox(
                    height: _lineGap,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(slice.check ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _ts(8.2, _ink.secondary)),
                      ),
                      if (slice.total != null)
                        Text(slice.total!, style: _ts(8.2, _ink.tertiary)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _flows(_TodoSheetPayload payload) {
    final flows = payload.lessonRecord?.flows ?? const <LessonRecordFlowProgress>[];
    if (flows.isEmpty) {
      return Text('오늘 과제에 연결된 Flow 없음',
          style: _ts(8.4, _ink.tertiary));
    }
    final counts = <String, int>{};
    for (final flow in flows) {
      final key = '${flow.flowName}|${flow.bookName ?? ''}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return _SheetOverflow(
      maxHeight: 52,
      expanded: _open.contains('flows'),
      onToggle: () => _toggle('flows'),
      spacing: 9,
      children: [
        for (final flow in flows) _flowItem(flow, counts),
      ],
    );
  }

  Widget _flowItem(LessonRecordFlowProgress flow, Map<String, int> counts) {
    final flowName = flow.flowName.trim().isEmpty ? 'Flow' : flow.flowName.trim();
    final book = (flow.bookName ?? '').trim();
    final grade = (flow.gradeLabel ?? '').trim();
    final dup = (counts['${flow.flowName}|${flow.bookName ?? ''}'] ?? 0) > 1;
    final label = book.isEmpty
        ? flowName
        : (dup && grade.isNotEmpty
            ? '$flowName · $book ($grade)'
            : '$flowName · $book');
    final pct = flow.progressPercent;
    final before = (flow.beforePercent ?? pct ?? 0).clamp(0.0, 100.0);
    final today = pct == null
        ? 0.0
        : (flow.todayPercent ?? 0).clamp(0.0, math.max(0.0, 100 - before));
    final right = pct == null
        ? (flow.completed ? '완료' : '진행 중')
        : '${pct.round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _sheetText(
                label,
                maxLines: 1,
                style: _ts(9.4, _ink.ink, bold: true),
              ),
            ),
            if (pct != null && today > 0)
              Text('+${today.round()}%',
                  style: _ts(8.4, _ink.accent, bold: true)),
            const SizedBox(width: 6),
            Text(right,
                style: _ts(
                  8.4,
                  pct == null && flow.completed
                      ? _ink.accent
                      : _ink.secondary,
                  bold: true,
                )),
          ],
        ),
        if (pct != null) ...[
          SizedBox(
            height:
                _lineGap,
          ),
          _bar(before.toDouble(), today.toDouble(), height: 4),
        ],
      ],
    );
  }

  Widget _notes(_TodoSheetPayload payload) {
    if (payload.specialNotes.isEmpty) {
      return Text('특이 사항이 없습니다.', style: _ts(9, _ink.tertiary));
    }
    return _SheetOverflow(
      maxHeight: 32,
      expanded: _open.contains('notes'),
      onToggle: () => _toggle('notes'),
      spacing: 12 * _screenPx,
      children: [
        for (final note in payload.specialNotes)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.only(top: 4, right: 6),
                decoration: BoxDecoration(
                  color: _ink.alert,
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(child: _sheetText(note, style: _ts(9, _ink.ink))),
            ],
          ),
      ],
    );
  }

  Widget _recordCard(_TodoSheetPayload payload) {
    return _card(
      minHeight: _upperH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('학습 기록', style: _ts(11.2, _ink.ink, title: true)),
            const SizedBox(height: 12),
            _recordBody(payload),
          ],
        ),
      ),
    );
  }

  Widget _recordBody(_TodoSheetPayload payload) {
    final rec = payload.lessonRecord;
    if (rec == null) {
      return Text('학습 기록 없음', style: _ts(10, _ink.tertiary));
    }
    final arr = payload.arrivalTime;
    final dep = payload.departureTime;
    final stayMs = arr != null && dep.isAfter(arr)
        ? dep.difference(arr).inMilliseconds
        : 0;
    final solved = rec.solvedProblemCount;
    final firstTry = rec.firstTryCorrectCount;
    final accuracy = solved == null || firstTry == null || solved <= 0
        ? null
        : '${(math.min(firstTry, solved) * 100 / solved).round()}';
    final corrTotal = rec.correctionRequiredCount;
    final corrDone = math.min(rec.correctionSuccessCount ?? 0, corrTotal ?? 0);
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
    final pool = rec.correctionPoolMetrics;
    final String? rateText;
    final String rateUnit;
    if (!pool || corrTotal == null) {
      rateText = null;
      rateUnit = '기록 없음';
    } else if (corrTotal <= 0) {
      rateText = null;
      rateUnit = '없음';
    } else {
      rateText = '${(corrDone * 100 / corrTotal).round()}';
      rateUnit = '%';
    }
    final rows = <List<(String, String?, String)>>[
      [
        ('새로 푼 문제', solved?.toString(), solved == null ? '기록 없음' : '문항'),
        (
          '정답률',
          accuracy,
          accuracy != null ? '%' : (solved == null ? '기록 없음' : '없음'),
        ),
      ],
      if (pool)
        [
          (
            '수정한 문제',
            corrTotal == null || corrTotal <= 0 ? null : '$corrTotal',
            corrTotal == null ? '기록 없음' : (corrTotal <= 0 ? '없음' : '문항'),
          ),
          ('수정률', rateText, rateUnit),
        ]
      else
        [
          (
            '수정한 문제',
            corrTotal == null || corrTotal <= 0 ? null : '$corrDone',
            corrTotal == null
                ? '기록 없음'
                : (corrTotal <= 0 ? '없음' : '/ $corrTotal 성공'),
          ),
          (
            '평균 수정 횟수',
            solved == null ? null : rec.avgTriesToPass?.toStringAsFixed(1),
            solved == null
                ? '기록 없음'
                : (rec.avgTriesToPass == null ? '없음' : '회'),
          ),
        ],
      if (pool)
        [
          (
            '평균 수정 횟수',
            solved == null ? null : rec.avgTriesToPass?.toStringAsFixed(1),
            solved == null
                ? '기록 없음'
                : (rec.avgTriesToPass == null ? '없음' : '회'),
          ),
          (
            '최대 수정 횟수',
            solved == null || rec.maxCorrectionTries == null
                ? null
                : '${rec.maxCorrectionTries}',
            solved == null
                ? '기록 없음'
                : (rec.maxCorrectionTries == null ? '없음' : '회'),
          ),
        ],
    ];
    final hwTotal = rec.homeworkProblemTotal;
    final hwSolved = rec.homeworkProblemSolved;
    final String? hwText;
    final String hwUnit;
    if (hwTotal == null || hwSolved == null) {
      hwText = null;
      hwUnit = rec.homeworkTotal > 0 ? '기록 없음' : '없음';
    } else if (hwTotal <= 0) {
      hwText = null;
      hwUnit = '없음';
    } else {
      hwText = '${math.min(hwSolved, hwTotal)}';
      hwUnit = '/ $hwTotal';
    }
    final tiles = <(String, String?, String)>[
      (
        '완료한 숙제',
        rec.homeworkTotal > 0 ? '${rec.homeworkCompleted}' : null,
        rec.homeworkTotal > 0 ? '/ ${rec.homeworkTotal}' : '없음',
      ),
      ('숙제로 푼 문항', hwText, hwUnit),
      (
        '완료한 과제',
        rec.assignmentTotal > 0 ? '${rec.assignmentCompleted}' : null,
        rec.assignmentTotal > 0 ? '/ ${rec.assignmentTotal}' : '없음',
      ),
      ('문항 당 진행속도', paceText, paceUnit),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < row.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _hero(row[i].$1, row[i].$2, row[i].$3)),
              ],
            ],
          ),
          const SizedBox(height: 18),
        ],
        for (var i = 0; i < tiles.length; i += 2) ...[
          Row(
            children: [
              Expanded(child: _tile(tiles[i].$1, tiles[i].$2, tiles[i].$3)),
              const SizedBox(width: 6),
              Expanded(
                  child: _tile(tiles[i + 1].$1, tiles[i + 1].$2, tiles[i + 1].$3)),
            ],
          ),
          if (i + 2 < tiles.length) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _hero(String title, String? big, String unit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: _ts(8.4, _ink.secondary)),
        const SizedBox(height: 5),
        if (big == null)
          Text(unit, style: _ts(9, _ink.tertiary))
        else
          Text.rich(TextSpan(children: [
            TextSpan(text: big, style: _ts(27, _ink.ink, bold: true)),
            TextSpan(text: ' $unit', style: _ts(8.6, _ink.secondary)),
          ])),
      ],
    );
  }

  Widget _tile(String title, String? big, String unit) {
    return Container(
      height: 48,
      padding: const EdgeInsets.fromLTRB(9, 5, 9, 4),
      decoration: BoxDecoration(
        color: _ink.white,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _ts(7.6, _ink.tertiary)),
          if (big == null)
            Text(unit, style: _ts(9, _ink.tertiary))
          else
            Text.rich(TextSpan(children: [
              TextSpan(text: big, style: _ts(14.5, _ink.ink, bold: true)),
              TextSpan(text: ' $unit', style: _ts(8.6, _ink.secondary)),
            ])),
        ],
      ),
    );
  }

  Widget _lower(_TodoSheetPayload payload) {
    const half = (_contentW - _gap) / 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: half, child: _todoCard(payload)),
        const SizedBox(width: _gap),
        SizedBox(width: half, child: _behaviorCard(payload)),
      ],
    );
  }

  Widget _todoCard(_TodoSheetPayload payload) {
    final due = payload.dueDate;
    final dueText = due == null
        ? '검사일 미정'
        : '${_formatMonthDay(due)} (${_formatWeekdayKorean(due)}) 검사';
    const bodyMax = _lowerH - 38 - 24;
    return _card(
      minHeight: _lowerH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('숙제 리스트', style: _ts(11.2, _ink.ink, title: true)),
                if (payload.todoEntries.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  Text('${payload.todoEntries.length}',
                      style: _ts(11.2, _ink.tertiary, bold: true)),
                ],
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: due == null ? _ink.white : _ink.accentSoft,
                    borderRadius: BorderRadius.circular(8.5),
                  ),
                  child: Text(
                    dueText,
                    style: _ts(
                      8.4,
                      due == null ? _ink.secondary : _ink.accentDeep,
                      bold: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (payload.todoEntries.isEmpty)
              Text('숙제 없음', style: _ts(10, _ink.tertiary))
            else
              _SheetOverflow(
                maxHeight: bodyMax,
                expanded: _open.contains('todo'),
                onToggle: () => _toggle('todo'),
                spacing: 14,
                children: [
                  for (final entry in payload.todoEntries) _todoRow(entry),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _todoRow(_TodoListEntry entry) {
    final primary = entry.primary;
    final hasBox = primary.startsWith('□');
    final book = (entry.bookTitle ?? '').trim();
    final line1 = book.isNotEmpty
        ? book
        : (hasBox ? primary.replaceFirst(RegExp(r'^□\s*'), '') : primary);
    final right1 = (entry.rightPrimary ?? '').trim();
    final secondary = (entry.secondary ?? '').trim();
    final right2 = (entry.rightSecondary ?? '').trim();
    final tertiary = (entry.tertiary ?? '').trim();
    final right3 = (entry.rightTertiary ?? '').trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasBox) ...[
          _checkBox(),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _twoSide(
                _sheetText(
                  line1,
                  maxLines: 1,
                  style: _ts(10, _ink.ink, bold: true),
                ),
                right1.isEmpty
                    ? null
                    : Text('$right1 출제', style: _ts(8.4, _ink.tertiary)),
              ),
              if (secondary.isNotEmpty || right2.isNotEmpty) ...[
                SizedBox(
                  height: _lineGap,
                ),
                _twoSide(
                  _sheetText(
                    secondary,
                    maxLines: 1,
                    style: _ts(9, _ink.secondary),
                  ),
                  right2.isEmpty
                      ? null
                      : Text(right2,
                          style: _ts(8.4, _ink.secondary, bold: true)),
                ),
              ],
              if (tertiary.isNotEmpty || right3.isNotEmpty) ...[
                SizedBox(
                  height: _lineGap,
                ),
                _twoSide(
                  _sheetText(
                    tertiary,
                    maxLines: 1,
                    style: _ts(8.4, _ink.tertiary),
                  ),
                  right3.isEmpty
                      ? null
                      : Text(right3, style: _ts(8.4, _ink.accentDeep)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _behaviorCard(_TodoSheetPayload payload) {
    const bodyMax = _lowerH - 38 - 24;
    return _card(
      minHeight: _lowerH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('행동 리스트', style: _ts(11.2, _ink.ink, title: true)),
                if (payload.behaviorEntries.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  Text('${payload.behaviorEntries.length}',
                      style: _ts(11.2, _ink.tertiary, bold: true)),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (payload.behaviorEntries.isEmpty)
              Text('행동 없음', style: _ts(10, _ink.tertiary))
            else
              _SheetOverflow(
                maxHeight: bodyMax,
                expanded: _open.contains('behavior'),
                onToggle: () => _toggle('behavior'),
                spacing: 14,
                children: [
                  for (final entry in payload.behaviorEntries)
                    _behaviorRow(entry),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _behaviorRow(_TodoListEntry entry) {
    var primary = entry.primary;
    final hasBox = primary.startsWith('□');
    primary = primary.replaceFirst(RegExp(r'^□\s*'), '');
    String? level;
    final match = RegExp(r'\s·\s(lv\.\d+)$').firstMatch(primary);
    if (match != null) {
      level = match.group(1);
      primary = primary.substring(0, match.start);
    }
    final secondary = (entry.secondary ?? '').trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasBox) ...[
          _checkBox(),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _sheetText(
                      primary,
                      maxLines: 1,
                      style: _ts(10, _ink.ink, bold: true),
                    ),
                  ),
                  if (level != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: _ink.white,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        level.toUpperCase().replaceAll('.', ' '),
                        style: _ts(8.4, _ink.secondary, bold: true),
                      ),
                    ),
                ],
              ),
              if (secondary.isNotEmpty) ...[
                SizedBox(
                  height: _lineGap,
                ),
                _sheetText(secondary, style: _ts(8.4, _ink.secondary)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _page2(_TodoSheetPayload payload) {
    const half = (_contentW - _gap) / 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('학습 내역', style: _ts(16, _ink.ink, title: true)),
            const Spacer(),
            Text(
              [
                payload.studentName.trim(),
                _refinedLongDate(payload.classDateTime),
              ].where((s) => s.isNotEmpty).join('  ·  '),
              style: _ts(8.4, _ink.tertiary),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: half, child: _doneCard(payload)),
              const SizedBox(width: _gap),
              SizedBox(width: half, child: _classCard(payload)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: half, child: _checkCard(payload, _lowerH)),
        ),
      ],
    );
  }

  Widget _doneCard(_TodoSheetPayload payload) {
    final items = payload.completedSummaries;
    return _card(
      minHeight: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _countTitle('오늘 완료한 과제', items.length),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Text('완료 과제 없음', style: _ts(10, _ink.tertiary))
            else
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                _doneRow(items[i], openKey: 'done:$i'),
              ],
          ],
        ),
      ),
    );
  }

  Widget _doneRow(_CompletedSummaryEntry item, {required String openKey}) {
    final book =
        item.bookAndCourse.trim().isEmpty ? '-' : item.bookAndCourse.trim();
    final group =
        item.groupTitle.trim().isEmpty ? '(제목 없음)' : item.groupTitle.trim();
    final totalMin = (item.totalMs / 60000).round();
    final open = _open.contains(openKey);
    return _assignmentBlock(
      open: open,
      onTap: () => _toggle(openKey),
      summary: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _twoSide(
            _sheetText(
              book,
              maxLines: 1,
              style: _ts(10, _ink.ink, bold: true),
            ),
            Text('${item.totalProgressPct.toStringAsFixed(0)}%',
                style: _ts(10, _ink.ink, bold: true)),
          ),
          SizedBox(height: _lineGap),
          _twoSide(
            _sheetText(
              group,
              maxLines: 1,
              style: _ts(9, _ink.secondary),
            ),
            Text('오늘 +${item.progressPct.toStringAsFixed(0)}%',
                style: _ts(8.4, _ink.accent, bold: true)),
          ),
        ],
      ),
      detail: item.subEntries.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: _lineGap),
                Text(
                  '누적 $totalMin분 · ${item.assignmentCount}회 출제 · ${item.checkCount}회 검사',
                  style: _ts(8.4, _ink.tertiary),
                ),
                SizedBox(height: _lineGap),
                _bar(item.previousProgressPct, item.progressPct),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final sub in item.subEntries)
                  Padding(
                    padding: EdgeInsets.only(top: _lineGap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sheetText(
                          sub.title,
                          maxLines: 1,
                          style: _ts(9, _ink.secondary),
                        ),
                        SizedBox(height: _lineGap),
                        Text(
                          '진행 ${sub.progressPct}% · 검사 ${sub.checkCount}회 · 출제 ${sub.assignmentCount}회',
                          style: _ts(8.4, _ink.tertiary),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _classCard(_TodoSheetPayload payload) {
    final items = payload.classWorkEntries;
    return _card(
      minHeight: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _countTitle('수업', items.length),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Text('오늘 수행 기록 없음', style: _ts(10, _ink.tertiary))
            else
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                _classRow(items[i], openKey: 'class:$i'),
              ],
          ],
        ),
      ),
    );
  }

  Widget _assignmentBlock({
    required bool open,
    required VoidCallback? onTap,
    required Widget summary,
    required Widget detail,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          summary,
          if (open) detail,
          if (onTap != null) ...[
            SizedBox(height: _lineGap),
            Text(
              open ? '접기' : '상세내역 표시',
              style: _ts(9, _ink.accent, bold: true),
            ),
          ],
        ],
      ),
    );
  }

  Widget _classRow(_ClassWorkEntry item, {required String openKey}) {
    final time = item.studyMs > 0 ? _formatDurationKorean(item.studyMs) : '';
    final open = _open.contains(openKey);
    final hasDetail = item.subEntries.isNotEmpty;
    return _assignmentBlock(
      open: open && hasDetail,
      onTap: hasDetail ? () => _toggle(openKey) : null,
      summary: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (item.bookAndCourse.trim().isNotEmpty || time.isNotEmpty)
            _twoSide(
              _sheetText(
                item.bookAndCourse.trim(),
                maxLines: 1,
                style: _ts(10, _ink.ink, bold: true),
              ),
              time.isEmpty
                  ? null
                  : Text(time, style: _ts(10, _ink.ink, bold: true)),
            ),
          if (item.title.trim().isNotEmpty) ...[
            SizedBox(height: _lineGap),
            _sheetText(
              item.title.trim(),
              maxLines: 1,
              style: _ts(9, _ink.secondary),
            ),
          ],
        ],
      ),
      detail: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final sub in item.subEntries)
            Padding(
              padding: EdgeInsets.only(top: _lineGap),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 3,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _ink.before,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: _sheetText(
                      [
                        sub.title,
                        if (_formatPageTextCompact(sub.page) != '-')
                          _formatPageTextCompact(sub.page),
                        if (_formatCountText(sub.count) != '-')
                          _formatCountText(sub.count),
                      ].join(' · '),
                      maxLines: 1,
                      style: _ts(8.4, _ink.tertiary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _checkCard(_TodoSheetPayload payload, double paperH) {
    final rows = payload.checkRates.where((e) => e.progress != null).toList();
    var sumToday = 0;
    var sumRemain = 0;
    for (final row in payload.checkRates) {
      if (row.progress == null) continue;
      sumToday += row.todayProgress ?? 0;
      if (!row.isExtra) {
        sumRemain += math.max(0, 100 - (row.previousProgress ?? 0));
      }
    }
    final ratio = sumRemain > 0
        ? ((sumToday * 100) / sumRemain).round()
        : (sumToday > 0 ? 101 : 0);
    final mood = rows.isEmpty ? null : _todoCheckMoodFor(ratio);
    return _card(
      minHeight: paperH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('숙제 검사 내역', style: _ts(11.2, _ink.ink, title: true)),
                if (rows.isNotEmpty) ...[
                  const SizedBox(width: 5),
                  Text('${rows.length}',
                      style: _ts(11.2, _ink.tertiary, bold: true)),
                ],
                const Spacer(),
                if (mood != null) _moodPill(mood, ratio),
              ],
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Text('검사 내역 없음', style: _ts(10, _ink.tertiary))
            else
              _SheetOverflow(
                maxHeight: paperH - 50,
                expanded: _open.contains('checks'),
                onToggle: () => _toggle('checks'),
                spacing: 14,
                children: [for (final row in rows) _checkRow(row)],
              ),
          ],
        ),
      ),
    );
  }

  Widget _moodPill(
    ({String asset, String label, bool fire}) mood,
    int ratio,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      decoration: BoxDecoration(
        color: _ink.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('${mood.label} $ratio%',
          style: _ts(9.4, _ink.ink, bold: true)),
    );
  }

  Widget _checkRow(_CheckRateEntry row) {
    final book = row.bookAndCourse.trim();
    final group = row.title.trim();
    final title = book.isEmpty && group.isEmpty
        ? '(제목 없음)'
        : book.isEmpty
            ? group
            : group.isEmpty
                ? book
                : '$book · $group';
    final today = row.todayProgress ?? 0;
    final previous = (row.previousProgress ?? 0).toDouble();
    final missed = switch (row.outcome) {
      'left_behind' => '숙제 안 함 (두고 옴)',
      'not_done' => '숙제 안 함',
      _ => null,
    };
    final line2 = [
      if (_formatPageTextCompact(row.page) != '-')
        _formatPageTextCompact(row.page),
      if (_formatCountText(row.count) != '-') _formatCountText(row.count),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _twoSide(
          _sheetText(
            title,
            maxLines: 1,
            style: _ts(9.4, _ink.ink, bold: true),
          ),
          Text(
            missed ?? '+$today%',
            style: _ts(
              8.4,
              missed != null
                  ? _ink.alert
                  : (today > 0 ? _ink.accent : _ink.secondary),
              bold: true,
            ),
          ),
        ),
        if (line2.isNotEmpty) ...[
          SizedBox(
            height:
                _lineGap,
          ),
          _sheetText(
            line2,
            maxLines: 1,
            style: _ts(9, _ink.secondary),
          ),
        ],
        SizedBox(
          height: _lineGap,
        ),
        _twoSide(
          Text(
            '내준 ${row.assignedAt != null ? _formatMonthDay(row.assignedAt!) : '-'} · 마감 ${row.dueDate != null ? _formatMonthDay(row.dueDate!) : '-'}',
            style: _ts(8.4, _ink.tertiary),
          ),
          Text(
            '검사 ${row.checkedAt != null ? _formatMonthDay(row.checkedAt!) : '-'}',
            style: _ts(8.4, _ink.tertiary),
          ),
        ),
        SizedBox(
          height: _lineGap,
        ),
        _bar(previous, today.toDouble()),
      ],
    );
  }

  Widget _countTitle(String title, int count) {
    return Row(
      children: [
        Text(title, style: _ts(11.2, _ink.ink, title: true)),
        if (count > 0) ...[
          const SizedBox(width: 5),
          Text('$count', style: _ts(11.2, _ink.tertiary, bold: true)),
        ],
      ],
    );
  }

  Widget _card({required Widget child, required double minHeight}) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _ink.card,
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      ),
    );
  }

  Widget _checkBox() {
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: _ink.white,
        borderRadius: BorderRadius.circular(2.6),
        border: Border.all(color: _ink.checkbox, width: 0.8),
      ),
    );
  }

  Widget _twoSide(Widget left, Widget? right) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        if (right != null) ...[const SizedBox(width: 6), right],
      ],
    );
  }

  Widget _bar(double previousPct, double todayPct, {double height = 4.6}) {
    final prev = previousPct.clamp(0.0, 100.0);
    final today = todayPct.clamp(0.0, math.max(0.0, 100.0 - prev));
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: _ink.white,
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              if (prev + today > 0)
                Container(
                  width: math.max(height, w * (prev + today) / 100),
                  decoration: BoxDecoration(
                    color: _ink.accent,
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                ),
              if (prev > 0)
                Container(
                  width: math.max(height, w * prev / 100),
                  decoration: BoxDecoration(
                    color: _ink.before,
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices, this.ink);

  final List<(int, Color)> slices;
  final _SheetInk ink;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<int>(0, (sum, slice) => sum + slice.$1);
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: size.width / 2);
    if (total <= 0) {
      canvas.drawCircle(center, size.width / 2, Paint()..color = ink.white);
    } else {
      var start = -math.pi / 2;
      for (final slice in slices) {
        final sweep = slice.$1 / total * math.pi * 2;
        canvas.drawArc(
          rect,
          start,
          sweep,
          true,
          Paint()..color = slice.$2,
        );
        start += sweep;
      }
    }
    canvas.drawCircle(center, 42, Paint()..color = ink.card);
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.slices != slices || oldDelegate.ink != ink;
}

class _SheetMathPiece {
  const _SheetMathPiece.plain(this.plain) : formula = null;
  const _SheetMathPiece.formula(this.formula) : plain = '';

  final String plain;
  final String? formula;
}

/// 한글은 기존 줄높이를 유지하고, 수식은 그 줄의 가운데에 자기 키로 둔다.
class _SheetMathLine extends StatelessWidget {
  const _SheetMathLine({
    required this.text,
    required this.style,
    required this.maxLines,
    required this.overflow,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final softWrap = maxLines == null || maxLines! > 1;
    final children = <Widget>[];
    for (final piece in _pieces(text)) {
      final formula = piece.formula;
      if (formula != null) {
        children.add(
          Math.tex(
            formula,
            mathStyle: _stacked(formula) ? MathStyle.display : MathStyle.text,
            textStyle: TextStyle(
              inherit: false,
              color: style.color,
              fontSize: style.fontSize,
              fontWeight: style.fontWeight,
              fontFamily: style.fontFamily,
            ),
            onErrorFallback: (_) => Text(
              formula,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
            ),
          ),
        );
        continue;
      }
      if (piece.plain.isEmpty) continue;
      children.add(
        Flexible(
          flex: piece.plain.length.clamp(1, 10000),
          child: Text(
            piece.plain,
            style: style,
            maxLines: maxLines,
            overflow: maxLines == null ? TextOverflow.clip : overflow,
            softWrap: softWrap,
          ),
        ),
      );
    }
    if (children.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: maxLines == null ? TextOverflow.clip : overflow,
        softWrap: softWrap,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }

  static List<_SheetMathPiece> _pieces(String raw) {
    final pieces = <_SheetMathPiece>[];
    var plain = '';
    var i = 0;
    void flush() {
      if (plain.isEmpty) return;
      pieces.add(_SheetMathPiece.plain(plain));
      plain = '';
    }

    while (i < raw.length) {
      if (raw.startsWith(r'$$', i)) {
        final end = raw.indexOf(r'$$', i + 2);
        if (end < 0) {
          plain += raw.substring(i);
          break;
        }
        flush();
        final formula = raw.substring(i + 2, end).trim();
        if (formula.isNotEmpty) pieces.add(_SheetMathPiece.formula(formula));
        i = end + 2;
        continue;
      }
      if (raw.startsWith(r'\(', i)) {
        final end = raw.indexOf(r'\)', i + 2);
        if (end < 0) {
          plain += raw.substring(i);
          break;
        }
        flush();
        final formula = raw.substring(i + 2, end).trim();
        if (formula.isNotEmpty) pieces.add(_SheetMathPiece.formula(formula));
        i = end + 2;
        continue;
      }
      plain += raw[i];
      i += 1;
    }
    flush();
    return pieces;
  }

  static bool _stacked(String formula) {
    final f = formula.toLowerCase();
    return f.contains(r'\frac') ||
        f.contains(r'\dfrac') ||
        f.contains(r'\tfrac') ||
        f.contains(r'\sqrt') ||
        f.contains(r'\sum') ||
        f.contains(r'\int') ||
        f.contains(r'\binom') ||
        f.contains(r'\over') ||
        f.contains(r'\begin{');
  }
}

class _OverflowParentData extends ContainerBoxParentData<RenderBox> {}

class _SheetOverflow extends MultiChildRenderObjectWidget {
  const _SheetOverflow({
    required this.maxHeight,
    required this.expanded,
    required this.onToggle,
    required super.children,
    this.spacing = 0,
  });

  final double maxHeight;
  final bool expanded;
  final VoidCallback onToggle;
  final double spacing;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSheetOverflow(
      maxHeight: maxHeight,
      expanded: expanded,
      spacing: spacing,
      onToggle: onToggle,
      buttonColor: _SheetInk.of(context).tertiary,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSheetOverflow renderObject,
  ) {
    renderObject
      ..maxHeight = maxHeight
      ..expanded = expanded
      ..spacing = spacing
      ..onToggle = onToggle
      ..buttonColor = _SheetInk.of(context).tertiary;
  }
}

class _RenderSheetOverflow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _OverflowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _OverflowParentData> {
  _RenderSheetOverflow({
    required double maxHeight,
    required bool expanded,
    required double spacing,
    required VoidCallback onToggle,
    required Color buttonColor,
  })  : _maxHeight = maxHeight,
        _expanded = expanded,
        _spacing = spacing,
        _onToggle = onToggle,
        _buttonColor = buttonColor;

  double _maxHeight;
  bool _expanded;
  double _spacing;
  VoidCallback _onToggle;
  Color _buttonColor;
  bool _showButton = false;
  String _buttonText = '';
  double _buttonTop = 0;
  int _shown = 0;

  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  set expanded(bool value) {
    if (value == _expanded) return;
    _expanded = value;
    markNeedsLayout();
  }

  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  set onToggle(VoidCallback value) => _onToggle = value;

  set buttonColor(Color value) {
    if (value == _buttonColor) return;
    _buttonColor = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _OverflowParentData) {
      child.parentData = _OverflowParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    final childConstraints = BoxConstraints.tightFor(width: width);
    final boxes = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      boxes.add(child);
      child = childAfter(child);
    }
    final total = boxes.length;
    var collapsedY = 0.0;
    var collapsedShown = 0;
    for (var i = 0; i < total; i++) {
      final gap = collapsedShown == 0 ? 0.0 : _spacing;
      final more = total - i - 1;
      final reserve = more > 0 ? _spacing + 16.0 : 0.0;
      final height = boxes[i].size.height;
      if (collapsedShown > 0 &&
          collapsedY + gap + height + reserve > _maxHeight) {
        break;
      }
      collapsedY += gap + height;
      collapsedShown++;
    }
    final hidden = total - collapsedShown;
    final shown = _expanded ? total : collapsedShown;
    var y = 0.0;
    for (var i = 0; i < shown; i++) {
      final gap = i == 0 ? 0.0 : _spacing;
      (boxes[i].parentData! as _OverflowParentData).offset =
          Offset(0, y + gap);
      y += gap + boxes[i].size.height;
    }
    final showButton = hidden > 0;
    if (showButton) {
      _buttonTop = y + (shown > 0 ? _spacing : 0);
      y = _buttonTop + 16;
      _buttonText = _expanded ? '접기' : '외 $hidden개';
    }
    _shown = shown;
    _showButton = showButton;
    size = constraints.constrain(Size(width, y));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    var index = 0;
    while (child != null && index < _shown) {
      final parentData = child.parentData! as _OverflowParentData;
      context.paintChild(child, offset + parentData.offset);
      child = childAfter(child);
      index++;
    }
    if (!_showButton) return;
    final painter = TextPainter(
      text: TextSpan(
        text: _buttonText,
        style: TextStyle(
          fontSize: 16 / (16 / 10),
          height: 1.25,
          color: _buttonColor,
          fontWeight: FontWeight.w600,
          fontFamily: _todoSheetPageFontFamily(),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    painter.paint(context.canvas, offset + Offset(0, _buttonTop));
    painter.dispose();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final hitChild = hitTestChildren(result, position: position);
    if (hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return hitChild;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    var child = firstChild;
    final shown = <RenderBox>[];
    var index = 0;
    while (child != null && index < _shown) {
      shown.add(child);
      child = childAfter(child);
      index++;
    }
    for (final box in shown.reversed) {
      final parentData = box.parentData! as _OverflowParentData;
      if (box.hitTest(result, position: position - parentData.offset)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool hitTestSelf(Offset position) {
    return _showButton &&
        position.dy >= _buttonTop &&
        position.dy <= _buttonTop + 16;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerUpEvent) _onToggle();
  }
}

/// 학생의 저장된 알림장 목록. 항목을 누르면 학습 리포트 화면으로 연다.
Future<void> showPastTodoSheetsDialog(
  BuildContext context, {
  required String studentId,
  required String studentName,
}) async {
  List<TodoSheetSnapshotSummary> snapshots;
  try {
    snapshots =
        await TodoSheetSnapshotService.instance.listForStudent(studentId);
  } catch (error) {
    if (context.mounted) {
      showAppSnackBar(context, '이전 알림장을 불러오지 못했어요: $error');
    }
    return;
  }
  if (!context.mounted) return;

  String dateLabel(DateTime value) {
    const weekdays = <String>['월', '화', '수', '목', '금', '토', '일'];
    return '${value.year}.${value.month.toString().padLeft(2, '0')}.'
        '${value.day.toString().padLeft(2, '0')} '
        '(${weekdays[value.weekday - 1]})';
  }

  await showUtilityGlassDialog(
    context: context,
    title: '$studentName 이전 알림장',
    icon: Icons.history_rounded,
    preferredWidth: math.min(MediaQuery.sizeOf(context).width - 48, 620),
    maxWidth: math.min(MediaQuery.sizeOf(context).width - 48, 620),
    maxHeight: math.min(MediaQuery.sizeOf(context).height - 48, 680),
    child: Builder(
      builder: (dialogContext) {
        final dlg = YggDialogColors.of(dialogContext);
        if (snapshots.isEmpty) {
          return Center(
            child: Text(
              '저장된 이전 알림장이 없습니다.',
              style: TextStyle(
                color: dlg.textSub,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          itemCount: snapshots.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (itemContext, index) {
            final snapshot = snapshots[index];
            return Material(
              color: dlg.fieldBg,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.of(dialogContext).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TodoSheetPage(snapshotId: snapshot.id),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 20,
                        color: kDlgAccent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dateLabel(snapshot.sessionDate),
                              style: TextStyle(
                                color: dlg.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              snapshot.className.isEmpty
                                  ? '정규 수업'
                                  : snapshot.className,
                              style: TextStyle(
                                color: dlg.textSub,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 22,
                        color: dlg.textSub,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
