import 'dart:async';

import 'package:flutter/material.dart';
import '../problem_bank_models.dart';
import '../../../services/problem_bank_service.dart';
import 'figure_utils.dart' as fig;

class FigureCompareResult {
  const FigureCompareResult({required this.accepted, this.job});
  final bool accepted;
  final ProblemBankFigureJob? job;
}

class FigureCompareDialog extends StatefulWidget {
  const FigureCompareDialog({
    super.key,
    required this.service,
    required this.academyId,
    required this.question,
    required this.documentId,
    this.currentFigureUrls = const <int, String>{},
  });

  final ProblemBankService service;
  final String academyId;
  final String documentId;
  final ProblemBankQuestion question;
  final Map<int, String> currentFigureUrls;

  static Future<FigureCompareResult?> show({
    required BuildContext context,
    required ProblemBankService service,
    required String academyId,
    required String documentId,
    required ProblemBankQuestion question,
    Map<int, String> currentFigureUrls = const <int, String>{},
  }) {
    return showDialog<FigureCompareResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => FigureCompareDialog(
        service: service,
        academyId: academyId,
        documentId: documentId,
        question: question,
        currentFigureUrls: currentFigureUrls,
      ),
    );
  }

  @override
  State<FigureCompareDialog> createState() => _FigureCompareDialogState();
}

enum _Phase { idle, generating, done, failed }

class _FigureCompareDialogState extends State<FigureCompareDialog> {
  _Phase _phase = _Phase.idle;
  ProblemBankFigureJob? _job;
  String _errorText = '';
  final Map<int, String> _aiUrls = <int, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_startGeneration());
  }

  Future<void> _startGeneration() async {
    setState(() {
      _phase = _Phase.generating;
      _errorText = '';
      _aiUrls.clear();
    });

    try {
      final q = widget.question;
      final promptHint = _buildPromptHint(q);
      var job = await widget.service.createFigureJob(
        academyId: widget.academyId,
        documentId: widget.documentId,
        questionId: q.id,
        forceRegenerate: true,
        promptText: promptHint,
        options: <String, dynamic>{
          'renderQuality': 'ultra',
          'minSidePx': 3072,
          'forceRegenerate': true,
          'figureRenderScale': fig.figureRenderScaleOf(q),
          'figureRenderScales': fig.figureRenderScaleMapOf(q),
          'figureHorizontalPairs': fig.figureHorizontalPairsPayloadOf(q),
        },
      );

      for (var i = 0; i < 90; i += 1) {
        if (!mounted) return;
        if (job.isTerminal) break;
        await Future<void>.delayed(const Duration(seconds: 2));
        final latest = await widget.service.getFigureJob(
          academyId: widget.academyId,
          jobId: job.id,
        );
        if (latest == null) break;
        job = latest;
      }

      if (!mounted) return;
      _job = job;

      if (job.status == 'failed') {
        setState(() {
          _phase = _Phase.failed;
          _errorText = job.errorMessage.isNotEmpty
              ? job.errorMessage
              : (job.errorCode.isNotEmpty ? job.errorCode : '생성 실패');
        });
        return;
      }

      if (!job.isTerminal) {
        setState(() {
          _phase = _Phase.failed;
          _errorText = '생성 시간이 초과되었습니다. 잠시 후 다시 시도해주세요.';
        });
        return;
      }

      final outputPaths = job.resultSummary['outputPaths'];
      final paths = outputPaths is List
          ? outputPaths.map((e) => '$e').where((e) => e.isNotEmpty).toList()
          : <String>[];
      if (paths.isEmpty) {
        final single = '${job.resultSummary['outputPath'] ?? ''}'.trim();
        if (single.isNotEmpty) paths.add(single);
      }

      for (var i = 0; i < paths.length; i++) {
        try {
          final url = await widget.service.createStorageSignedUrl(
            bucket: 'problem-previews',
            path: paths[i],
            expiresInSeconds: 3600,
          );
          if (url.isNotEmpty) _aiUrls[i] = url;
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _phase = _aiUrls.isNotEmpty ? _Phase.done : _Phase.failed;
        if (_aiUrls.isEmpty) _errorText = 'AI 이미지 URL을 가져올 수 없습니다.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _errorText = '$e';
      });
    }
  }

  String _buildPromptHint(ProblemBankQuestion q) {
    final equations = q.equations
        .map((e) => (e.latex.isNotEmpty ? e.latex : e.raw).trim())
        .where((e) => e.isNotEmpty)
        .take(5)
        .toList(growable: false);
    final scaleMap = fig.figureRenderScaleMapOf(q);
    final orderedAssets = fig.orderedFigureAssetsOf(q);
    final keyLabelMap = <String, String>{};
    for (var i = 0; i < orderedAssets.length; i += 1) {
      final key = fig.figureScaleKeyForAsset(orderedAssets[i], i + 1);
      keyLabelMap[key] = fig.figureScaleKeyLabel(key, i + 1);
    }
    final scaleHintText = scaleMap.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    final scaleText = scaleHintText.asMap().entries.map((entry) {
      final key = entry.value.key;
      final label = fig.figureScaleKeyLabel(key, entry.key + 1);
      final pct = (entry.value.value * 100).round();
      return '$label $pct%';
    }).join(', ');
    final horizontalPairs = fig.figureHorizontalPairKeysOf(q)
        .map((pairKey) => fig.figurePairParts(pairKey))
        .where((parts) => parts.length == 2)
        .map((parts) {
      final left = keyLabelMap[parts[0]] ?? parts[0];
      final right = keyLabelMap[parts[1]] ?? parts[1];
      return '$left + $right';
    }).join(', ');
    return [
      '추가 생성 제약:',
      '- 도형 내부 수식/숫자/문자 라벨의 시각 크기를 문제 본문 수식 크기와 동일하게 맞출 것.',
      '- 분수/근호/지수 등 2차원 수식도 본문 수식과 동일한 굵기와 비율을 유지할 것.',
      '- 수식 라벨 배율 힌트: ${fig.figureRenderScaleLabel(q)}',
      if (scaleText.isNotEmpty) '- 그림별 라벨 배율: $scaleText',
      if (horizontalPairs.isNotEmpty) '- 가로 배치로 묶을 그림 쌍: $horizontalPairs',
      if (equations.isNotEmpty) '- 본문 수식 예시: ${equations.join(' | ')}',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final qNum = widget.question.questionNumber;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(qNum),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
            const Divider(height: 1),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String qNum) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.compare, size: 20),
          const SizedBox(width: 8),
          Text(
            '$qNum번 그림 비교',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(null),
            tooltip: '닫기',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildOriginalPanel()),
        const VerticalDivider(width: 1),
        Expanded(child: _buildAiPanel()),
      ],
    );
  }

  Widget _buildOriginalPanel() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '현재 (HWPX 원본)',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Expanded(
          child: _buildImageGrid(widget.currentFigureUrls),
        ),
      ],
    );
  }

  Widget _buildAiPanel() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'AI 생성',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              if (_phase == _Phase.generating) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: _buildAiContent()),
      ],
    );
  }

  Widget _buildAiContent() {
    switch (_phase) {
      case _Phase.idle:
      case _Phase.generating:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'AI가 그림을 생성하고 있습니다...',
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(height: 4),
              Text(
                '최대 3분 정도 소요될 수 있습니다.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        );
      case _Phase.failed:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _errorText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => unawaited(_startGeneration()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        );
      case _Phase.done:
        return _buildImageGrid(_aiUrls);
    }
  }

  Widget _buildImageGrid(Map<int, String> urls) {
    if (urls.isEmpty) {
      return const Center(
        child: Text('이미지 없음', style: TextStyle(color: Colors.grey)),
      );
    }
    final sorted = urls.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: sorted.map((e) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              children: [
                if (sorted.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '그림 ${e.key + 1}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    e.value,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => Container(
                      height: 120,
                      color: Colors.grey.shade200,
                      child: const Center(
                        child: Icon(Icons.broken_image, color: Colors.grey),
                      ),
                    ),
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        height: 120,
                        alignment: Alignment.center,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('원본 유지'),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _phase == _Phase.done
                ? () => Navigator.of(context).pop(
                      FigureCompareResult(accepted: true, job: _job),
                    )
                : null,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('AI 그림 사용'),
          ),
        ],
      ),
    );
  }
}
