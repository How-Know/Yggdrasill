import 'package:flutter/material.dart';

import '../../services/think/think_api.dart';
import '../../services/think/think_controller.dart';
import '../../services/think/think_models.dart';
import 'think_style.dart';

enum _Period { thisMonth, last30, lastMonth }

class _Agg {
  int runs = 0;
  int errors = 0;
  int input = 0;
  int cached = 0;
  int output = 0;
  int reasoning = 0;
  int web = 0;
  double cost = 0;

  void add(ThinkUsageRow r) {
    runs += r.runs;
    errors += r.errors;
    input += r.inputTokens;
    cached += r.cachedInputTokens;
    output += r.outputTokens;
    reasoning += r.reasoningTokens;
    web += r.webSearchCalls;
    cost += r.costUsd;
  }
}

class ThinkUsageTab extends StatefulWidget {
  const ThinkUsageTab({super.key});

  @override
  State<ThinkUsageTab> createState() => _ThinkUsageTabState();
}

class _ThinkUsageTabState extends State<ThinkUsageTab> {
  _Period _period = _Period.thisMonth;
  List<ThinkUsageRow>? _rows;
  String? _error;
  bool _loading = false;

  final _budget = TextEditingController();
  final _codeLimit = TextEditingController(text: '10');
  String _mode = 'warn';
  bool _webSearch = true;
  bool _settingsLoaded = false;
  bool _savingSettings = false;

  ThinkController get _c => ThinkController.instance;

  @override
  void initState() {
    super.initState();
    _load();
    _loadSettings();
  }

  @override
  void dispose() {
    _budget.dispose();
    _codeLimit.dispose();
    super.dispose();
  }

  (DateTime, DateTime) _range() {
    final now = DateTime.now();
    final soon = now.add(const Duration(minutes: 1));
    return switch (_period) {
      _Period.thisMonth => (DateTime(now.year, now.month, 1), soon),
      _Period.last30 => (DateTime(now.year, now.month, now.day).subtract(const Duration(days: 29)), soon),
      _Period.lastMonth => (DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 1)),
    };
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (from, to) = _range();
      final rows = await ThinkApi.instance.usageSummary(from, to);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '사용량을 불러오지 못했습니다: $e';
        _loading = false;
      });
    }
  }

  Future<void> _loadSettings() async {
    try {
      final s = await ThinkApi.instance.settings();
      if (!mounted) return;
      setState(() {
        _budget.text = s.monthlyBudgetUsd == null ? '' : _trimNum(s.monthlyBudgetUsd!);
        _mode = s.budgetMode;
        _webSearch = s.webSearchEnabled;
        _codeLimit.text = '${s.codeRequestDailyLimit}';
        _settingsLoaded = true;
      });
    } catch (e) {
      if (mounted) showThinkSnack(context, '설정을 불러오지 못했습니다: $e', error: true);
    }
  }

  String _trimNum(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Future<void> _saveSettings() async {
    final raw = _budget.text.trim().replaceAll(r'$', '').replaceAll(',', '');
    double? budget;
    if (raw.isNotEmpty) {
      budget = double.tryParse(raw);
      if (budget == null || budget < 0) {
        showThinkSnack(context, '한도는 0 이상의 숫자(USD)로 입력하세요.', error: true);
        return;
      }
    }
    final codeLimit = int.tryParse(_codeLimit.text.trim());
    if (codeLimit == null || codeLimit < 0 || codeLimit > 100) {
      showThinkSnack(context, '코드 조사 하루 한도는 0~100 사이의 정수로 입력하세요.', error: true);
      return;
    }
    setState(() => _savingSettings = true);
    try {
      await ThinkApi.instance.updateSettings(
        monthlyBudgetUsd: budget,
        budgetMode: _mode,
        webSearchEnabled: _webSearch,
        codeRequestDailyLimit: codeLimit,
      );
      await _c.refreshStatus();
      if (!_webSearch) _c.setWebSearch(false);
      if (mounted) showThinkSnack(context, '설정을 저장했습니다.');
    } catch (e) {
      if (mounted) showThinkSnack(context, '설정을 저장하지 못했습니다: $e', error: true);
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: _c, builder: (context, _) => _build());
  }

  Widget _build() {
    final rows = _rows ?? const <ThinkUsageRow>[];
    final total = _Agg();
    for (final r in rows) {
      total.add(r);
    }
    return ListView(
      children: [
        Row(
          children: [
            ThinkPillTabs(
              labels: const ['이번 달', '최근 30일', '지난 달'],
              icons: const [Icons.calendar_month_outlined, Icons.date_range_outlined, Icons.history],
              selected: _period.index,
              onSelected: (i) {
                setState(() => _period = _Period.values[i]);
                _load();
              },
            ),
            const SizedBox(width: 12),
            if (_loading)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kThinkAccent)),
            const Spacer(),
            IconButton(
              tooltip: '새로고침',
              color: kThinkSub,
              onPressed: () {
                _load();
                _c.refreshStatus();
              },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          ThinkNotice(text: _error!, color: kThinkError, icon: Icons.error_outline),
          const SizedBox(height: 16),
        ],
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _stat('비용', formatUsd(total.cost), '가격표에 없는 모델은 제외'),
            _stat('호출', '${total.runs}회', total.errors > 0 ? '오류 ${total.errors}회' : '오류 없음'),
            _stat('입력 토큰', formatTokens(total.input), '캐시 ${formatTokens(total.cached)}'),
            _stat('출력 토큰', formatTokens(total.output), '추론 ${formatTokens(total.reasoning)}'),
            _stat('웹 검색', '${total.web}회', '1회 \$0.01'),
          ],
        ),
        const SizedBox(height: 16),
        _budgetCard(),
        const SizedBox(height: 16),
        _breakdown('기능별', rows, (r) => kThinkFeatureLabels[r.feature] ?? r.feature),
        const SizedBox(height: 16),
        _breakdown('모델별', rows, (r) => r.model.isEmpty ? '(없음)' : r.model),
        const SizedBox(height: 16),
        _daily(rows),
      ],
    );
  }

  Widget _stat(String label, String value, String caption) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kThinkPanel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kThinkBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kThinkSub, fontSize: 12)),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(color: kThinkText, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(caption, style: const TextStyle(color: kThinkHint, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _budgetCard() {
    final status = _c.status;
    final limit = status?.budgetLimitUsd;
    final spent = status?.spentUsd ?? 0;
    final ratio = limit == null || limit <= 0 ? null : (spent / limit).clamp(0.0, 1.0);
    return ThinkPanel(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('월 사용 한도', style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
            '플랫폼 전체 AI 비용(한국 시간 기준 달) 한도입니다. 비워 두면 한도가 없습니다.\n'
            '경고만: 넘어도 쓰되 알림을 띄웁니다. 차단: 넘으면 Think와 메모 요약을 멈춥니다.\n'
            '코드 조사(Cursor)는 금액을 받을 수 없어 이 한도에 들어가지 않습니다. 대신 하루에 보낼 수 있는 요청 수로 제한합니다.',
            style: TextStyle(color: kThinkSub, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 16),
          if (!_settingsLoaded)
            const LinearProgressIndicator(color: kThinkAccent, backgroundColor: kThinkField)
          else ...[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _budget,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: kThinkText, fontSize: 14),
                    decoration: thinkInputDecoration(label: '한도 (USD)', hint: '예: 30', dense: true),
                  ),
                ),
                ThinkToggleChip(
                  label: '경고만',
                  icon: Icons.notifications_active_outlined,
                  selected: _mode == 'warn',
                  onChanged: (_) => setState(() => _mode = 'warn'),
                ),
                ThinkToggleChip(
                  label: '차단',
                  icon: Icons.block,
                  selected: _mode == 'block',
                  onChanged: (_) => setState(() => _mode = 'block'),
                ),
                ThinkToggleChip(
                  label: _webSearch ? '웹 검색 허용' : '웹 검색 꺼짐',
                  icon: Icons.travel_explore,
                  selected: _webSearch,
                  onChanged: (v) => setState(() => _webSearch = v),
                ),
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _codeLimit,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: kThinkText, fontSize: 14),
                    decoration: thinkInputDecoration(label: '코드 조사 하루 한도 (건)', hint: '0~100', dense: true),
                  ),
                ),
                ElevatedButton(
                  onPressed: _savingSettings ? null : _saveSettings,
                  style: thinkPrimaryButton(),
                  child: const Text('저장'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              limit == null
                  ? '이번 달 사용 ${formatUsd(spent)} · 한도 없음'
                  : '이번 달 사용 ${formatUsd(spent)} / 한도 ${formatUsd(limit, digits: 2)}${status!.budgetExceeded ? ' · 한도 초과' : ''}',
              style: TextStyle(
                color: status?.budgetExceeded == true ? kThinkError : kThinkSub,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (ratio != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 8,
                  color: status!.budgetExceeded ? kThinkError : kThinkAccent,
                  backgroundColor: kThinkField,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _breakdown(String title, List<ThinkUsageRow> rows, String Function(ThinkUsageRow) keyOf) {
    final groups = <String, _Agg>{};
    for (final r in rows) {
      groups.putIfAbsent(keyOf(r), _Agg.new).add(r);
    }
    final entries = groups.entries.toList()..sort((a, b) => b.value.cost.compareTo(a.value.cost));
    const head = TextStyle(color: kThinkSub, fontSize: 12, fontWeight: FontWeight.w700);
    const cell = TextStyle(color: kThinkText, fontSize: 13);
    Widget c(String t, {TextStyle style = cell, TextAlign align = TextAlign.right}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(t, style: style, textAlign: align, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    return ThinkPanel(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (entries.isEmpty)
            const Text('기록이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13))
          else
            Table(
              columnWidths: const {0: FlexColumnWidth(3)},
              defaultColumnWidth: const FlexColumnWidth(1),
              border: const TableBorder(horizontalInside: BorderSide(color: kThinkBorder)),
              children: [
                TableRow(children: [
                  c('항목', style: head, align: TextAlign.left),
                  c('호출', style: head),
                  c('오류', style: head),
                  c('입력', style: head),
                  c('캐시', style: head),
                  c('출력', style: head),
                  c('웹 검색', style: head),
                  c('비용', style: head),
                ]),
                for (final e in entries)
                  TableRow(children: [
                    c(e.key, align: TextAlign.left),
                    c('${e.value.runs}'),
                    c('${e.value.errors}', style: e.value.errors > 0 ? cell.copyWith(color: kThinkError) : cell),
                    c(formatTokens(e.value.input)),
                    c(formatTokens(e.value.cached)),
                    c(formatTokens(e.value.output)),
                    c('${e.value.web}'),
                    c(formatUsd(e.value.cost)),
                  ]),
              ],
            ),
        ],
      ),
    );
  }

  Widget _daily(List<ThinkUsageRow> rows) {
    final byDay = <DateTime, _Agg>{};
    for (final r in rows) {
      byDay.putIfAbsent(DateTime(r.day.year, r.day.month, r.day.day), _Agg.new).add(r);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final maxCost = byDay.values.fold<double>(0, (m, a) => a.cost > m ? a.cost : m);
    return ThinkPanel(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('일별', style: TextStyle(color: kThinkText, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (days.isEmpty)
            const Text('기록이 없습니다.', style: TextStyle(color: kThinkHint, fontSize: 13))
          else
            for (final d in days)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text('${d.month}월 ${d.day}일', style: const TextStyle(color: kThinkSub, fontSize: 12)),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: maxCost <= 0 ? 0.01 : (byDay[d]!.cost / maxCost).clamp(0.01, 1.0),
                          child: Container(
                            height: 12,
                            decoration: BoxDecoration(
                              color: kThinkAccent.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 160,
                      child: Text(
                        '${formatUsd(byDay[d]!.cost)} · ${byDay[d]!.runs}회',
                        textAlign: TextAlign.right,
                        style: const TextStyle(color: kThinkText, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
