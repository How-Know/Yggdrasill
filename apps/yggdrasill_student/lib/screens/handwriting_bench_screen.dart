import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/handwriting_ink_png.dart';
import '../services/latex_linear.dart';
import '../services/myscript_math.dart';
import '../services/textbook_api.dart';
import '../widgets/pencil_input_pad.dart';

/// 필기 인식 벤치마크 (개발용).
///
/// 신고로 쌓인 내 필기 샘플(student_handwriting_samples)을 불러와
/// 같은 획을 ML Kit / MyScript iink / VLM(Gemini) 세 엔진에 재생해
/// 인식 결과를 나란히 비교한다. MyScript 기본 엔진 채택 여부를
/// 판단하기 위한 화면으로, 일반 학생 사용 흐름과는 무관하다.
class HandwritingBenchScreen extends StatefulWidget {
  const HandwritingBenchScreen({super.key});

  @override
  State<HandwritingBenchScreen> createState() => _HandwritingBenchScreenState();
}

class _BenchSample {
  _BenchSample({
    required this.id,
    required this.sampleNo,
    required this.strokes,
    required this.canvasSize,
    required this.originalText,
    required this.expectedAnswer,
    required this.answerKind,
    required this.createdAt,
  });

  final String id;
  final int sampleNo;

  /// 스냅샷 계약 형식 그대로: [{x:[],y:[],t:[],p:[]}]
  final List<Map<String, dynamic>> strokes;
  final Size canvasSize;

  /// 신고 당시 온디바이스 인식 결과.
  final String originalText;
  final String expectedAnswer;
  final String answerKind;
  final DateTime? createdAt;

  String? mlkitResult;
  String? myscriptLatex;
  String? myscriptResult;
  String? vlmResult;
  bool running = false;
  bool vlmRunning = false;

  List<List<Offset>> get strokeOffsets => <List<Offset>>[
        for (final s in strokes)
          <Offset>[
            for (var i = 0;
                i < math.min((s['x'] as List).length, (s['y'] as List).length);
                i++)
              Offset(
                ((s['x'] as List)[i] as num).toDouble(),
                ((s['y'] as List)[i] as num).toDouble(),
              ),
          ],
      ];

  static _BenchSample? fromRow(Map<String, dynamic> row) {
    final payload = row['payload'];
    if (payload is! Map) return null;
    final rawStrokes = payload['strokes'];
    if (rawStrokes is! List || rawStrokes.isEmpty) return null;
    return _BenchSample(
      id: row['id'] as String,
      sampleNo: (row['sample_no'] as num?)?.toInt() ?? 0,
      strokes: <Map<String, dynamic>>[
        for (final s in rawStrokes)
          if (s is Map) Map<String, dynamic>.from(s),
      ],
      canvasSize: Size(
        ((payload['canvas_width'] as num?) ?? 0).toDouble(),
        ((payload['canvas_height'] as num?) ?? 0).toDouble(),
      ),
      originalText: (row['recognized_text'] as String?) ?? '',
      expectedAnswer: (row['expected_answer'] as String?) ?? '',
      answerKind: (row['expected_answer_kind'] as String?) ?? 'subjective',
      createdAt: DateTime.tryParse((row['created_at'] as String?) ?? ''),
    );
  }
}

class _HandwritingBenchScreenState extends State<HandwritingBenchScreen> {
  List<_BenchSample> _samples = const [];
  bool _loading = true;
  String? _error;
  bool _myscriptAvailable = false;
  String _myscriptStatus = '확인 중…';
  bool _runningAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final available = await MyScriptMath.instance.available();
      final rows = await Supabase.instance.client
          .from('student_handwriting_samples')
          .select(
            'id, sample_no, payload, recognized_text, submitted_answer, '
            'expected_answer, expected_answer_kind, created_at',
          )
          .order('created_at', ascending: false)
          .limit(30);
      if (!mounted) return;
      setState(() {
        _myscriptAvailable = available;
        _myscriptStatus = MyScriptMath.instance.status;
        _samples = <_BenchSample>[
          for (final row in rows)
            if (_BenchSample.fromRow(Map<String, dynamic>.from(row)) != null)
              _BenchSample.fromRow(Map<String, dynamic>.from(row))!,
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '샘플을 불러오지 못했어요.\n$e';
        _loading = false;
      });
    }
  }

  Future<void> _runSample(_BenchSample sample) async {
    setState(() => sample.running = true);
    try {
      // ML Kit — 신고 당시와 동일한 온디바이스 인식.
      try {
        final candidates = await debugRecognizeStrokesWithMlKit(
          strokes: sample.strokes,
          canvasWidth: sample.canvasSize.width,
          canvasHeight: sample.canvasSize.height,
        );
        sample.mlkitResult = candidates.isEmpty
            ? '(후보 없음)'
            : candidates.take(3).join(' | ');
      } catch (e) {
        sample.mlkitResult = '(실패: $e)';
      }

      // MyScript iink.
      if (_myscriptAvailable) {
        final latex = await MyScriptMath.instance.recognizeLatex(
          sample.strokes,
        );
        sample.myscriptLatex = latex;
        sample.myscriptResult =
            latex == null ? '(인식 실패)' : latexToLinear(latex);
      } else {
        sample.myscriptResult = '(엔진 없음: $_myscriptStatus)';
      }
    } finally {
      if (mounted) setState(() => sample.running = false);
    }
  }

  Future<void> _runVlm(_BenchSample sample) async {
    setState(() => sample.vlmRunning = true);
    try {
      final png = await renderHandwritingPng(
        strokes: sample.strokeOffsets,
        canvasSize: sample.canvasSize,
      );
      if (png == null) {
        sample.vlmResult = '(렌더 실패)';
        return;
      }
      final text = await TextbookApi.instance.recognizeHandwriting(
        imageBase64: base64Encode(png),
        answerKind: sample.answerKind,
      );
      sample.vlmResult = (text == null || text.isEmpty) ? '(인식 실패)' : text;
    } catch (e) {
      sample.vlmResult = '(실패: $e)';
    } finally {
      if (mounted) setState(() => sample.vlmRunning = false);
    }
  }

  Future<void> _runAll() async {
    if (_runningAll) return;
    setState(() => _runningAll = true);
    for (final sample in _samples) {
      if (!mounted) break;
      await _runSample(sample);
    }
    if (mounted) setState(() => _runningAll = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('필기 인식 벤치마크'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(_error!, textAlign: TextAlign.center),
                )
              : Column(
                  children: [
                    _EngineStatusBanner(
                      available: _myscriptAvailable,
                      status: _myscriptStatus,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Text(
                            '신고 샘플 ${_samples.length}건',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed:
                                _samples.isEmpty || _runningAll ? null : _runAll,
                            icon: _runningAll
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow_rounded),
                            label: const Text('전체 재생 (ML Kit + MyScript)'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _samples.isEmpty
                          ? const Center(
                              child: Text('신고된 필기 샘플이 없어요.\n'
                                  '교재 풀기에서 "필기인식이 잘 안돼요"로 신고하면 쌓여요.'),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              itemCount: _samples.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, index) {
                                final sample = _samples[index];
                                return _SampleCard(
                                  sample: sample,
                                  onRun: () => _runSample(sample),
                                  onRunVlm: () => _runVlm(sample),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _EngineStatusBanner extends StatelessWidget {
  const _EngineStatusBanner({required this.available, required this.status});

  final bool available;
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = available ? Colors.green : Colors.orange;
    final text = available
        ? 'MyScript iink 사용 가능 (status: $status)'
        : 'MyScript iink 비활성 (status: $status) — '
            'ios/MyScriptMath/Classes/MyCertificate.c 를 발급 인증서로 교체하면 활성화돼요.';
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            available ? Icons.check_circle_rounded : Icons.info_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color.shade700))),
        ],
      ),
    );
  }
}

class _SampleCard extends StatelessWidget {
  const _SampleCard({
    required this.sample,
    required this.onRun,
    required this.onRunVlm,
  });

  final _BenchSample sample;
  final VoidCallback onRun;
  final VoidCallback onRunVlm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '#${sample.sampleNo}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 10),
                if (sample.createdAt != null)
                  Text(
                    '${sample.createdAt!.toLocal()}'.split('.').first,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: sample.vlmRunning ? null : onRunVlm,
                  icon: sample.vlmRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_outlined, size: 18),
                  label: const Text('VLM'),
                ),
                IconButton(
                  tooltip: '이 샘플 재생',
                  onPressed: sample.running ? null : onRun,
                  icon: sample.running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_circle_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 170,
                  height: 100,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: CustomPaint(
                    painter: _MiniStrokePainter(
                      strokes: sample.strokeOffsets,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ResultLine(
                        label: '정답',
                        value: sample.expectedAnswer.isEmpty
                            ? '(없음)'
                            : sample.expectedAnswer,
                        bold: true,
                      ),
                      _ResultLine(
                        label: '신고 당시',
                        value: sample.originalText.isEmpty
                            ? '(없음)'
                            : sample.originalText,
                      ),
                      const Divider(height: 14),
                      _ResultLine(
                        label: 'ML Kit',
                        value: sample.mlkitResult ?? '—',
                      ),
                      _ResultLine(
                        label: 'MyScript',
                        value: sample.myscriptResult == null
                            ? '—'
                            : sample.myscriptLatex == null
                                ? sample.myscriptResult!
                                : '${sample.myscriptResult}   '
                                    '(LaTeX: ${sample.myscriptLatex})',
                        highlight: sample.myscriptResult != null &&
                            sample.myscriptResult ==
                                sample.expectedAnswer.replaceAll(' ', ''),
                      ),
                      _ResultLine(
                        label: 'VLM',
                        value: sample.vlmResult ?? '—',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({
    required this.label,
    required this.value,
    this.bold = false,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool bold;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                color: highlight ? Colors.green : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 획을 미리보기 박스에 맞춰 축소해 그리는 단순 폴리라인 페인터.
class _MiniStrokePainter extends CustomPainter {
  const _MiniStrokePainter({required this.strokes, required this.color});

  final List<List<Offset>> strokes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final stroke in strokes) {
      for (final p in stroke) {
        minX = math.min(minX, p.dx);
        minY = math.min(minY, p.dy);
        maxX = math.max(maxX, p.dx);
        maxY = math.max(maxY, p.dy);
      }
    }
    if (!minX.isFinite) return;
    final inkWidth = math.max(maxX - minX, 1.0);
    final inkHeight = math.max(maxY - minY, 1.0);
    const pad = 8.0;
    final scale = math.min(
      (size.width - pad * 2) / inkWidth,
      (size.height - pad * 2) / inkHeight,
    );
    final offsetX = (size.width - inkWidth * scale) / 2;
    final offsetY = (size.height - inkHeight * scale) / 2;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < stroke.length; i++) {
        final p = Offset(
          offsetX + (stroke[i].dx - minX) * scale,
          offsetY + (stroke[i].dy - minY) * scale,
        );
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (stroke.length == 1) {
        canvas.drawCircle(
          Offset(
            offsetX + (stroke.first.dx - minX) * scale,
            offsetY + (stroke.first.dy - minY) * scale,
          ),
          1.6,
          paint..style = PaintingStyle.fill,
        );
        paint.style = PaintingStyle.stroke;
        continue;
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniStrokePainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.color != color;
}
