import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/student_textbook_report_service.dart';
import 'dialog_tokens.dart';

/// 학생 교재 문항 신고 검토 다이얼로그.
///
/// 좌측 신고 목록, 우측에 신고 문항 본문을 학생 앱과 동일한 렌더
/// (단일 문항 PDF, 없으면 원본 교재 crop)로 보여주고 인정/반려를 판정한다.
Future<void> showTextbookReportReviewDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _TextbookReportReviewDialog(),
  );
}

class _TextbookReportReviewDialog extends StatefulWidget {
  const _TextbookReportReviewDialog();

  @override
  State<_TextbookReportReviewDialog> createState() =>
      _TextbookReportReviewDialogState();
}

class _TextbookReportReviewDialogState
    extends State<_TextbookReportReviewDialog> {
  List<StudentTextbookReport>? _reports;
  Object? _error;
  bool _openOnly = true;
  String? _selectedId;
  bool _resolving = false;

  final Map<String, Future<TextbookReportQuestionView>> _viewCache = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _reports = null;
      _error = null;
    });
    try {
      final reports = await StudentTextbookReportService.instance
          .listReports(includeResolved: true);
      if (!mounted) return;
      setState(() {
        _reports = reports;
        if (_selectedId == null || !reports.any((r) => r.id == _selectedId)) {
          _selectedId = reports.isEmpty ? null : reports.first.id;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<TextbookReportQuestionView> _questionView(
    StudentTextbookReport report,
  ) {
    return _viewCache.putIfAbsent(
      report.id,
      () => StudentTextbookReportService.instance.resolveQuestionView(report),
    );
  }

  List<StudentTextbookReport> get _visibleReports {
    final reports = _reports ?? const <StudentTextbookReport>[];
    if (!_openOnly) return reports;
    return reports.where((r) => r.isOpen).toList(growable: false);
  }

  Future<void> _accept(StudentTextbookReport report) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      await StudentTextbookReportService.instance.resolveReport(
        reportId: report.id,
        status: 'accepted',
      );
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('신고 판정을 저장하지 못했습니다.')),
        );
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _reject(StudentTextbookReport report) async {
    if (_resolving) return;
    final choice = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _RejectResolutionDialog(report: report),
    );
    if (choice == null || !mounted) return;
    setState(() => _resolving = true);
    try {
      await StudentTextbookReportService.instance.resolveReport(
        reportId: report.id,
        status: 'rejected',
        resolution: choice.$1,
        resolutionNote: choice.$2,
      );
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('신고 판정을 저장하지 못했습니다.')),
        );
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reports = _visibleReports;
    StudentTextbookReport? selected;
    for (final report in reports) {
      if (report.id == _selectedId) {
        selected = report;
        break;
      }
    }
    selected ??= reports.isEmpty ? null : reports.first;

    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Text(
            '문항 신고',
            style: TextStyle(
              color: kDlgText,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          FilterChip(
            label: const Text('검토 중만'),
            selected: _openOnly,
            onSelected: (on) => setState(() => _openOnly = on),
            selectedColor: kDlgAccent.withValues(alpha: 0.22),
            checkmarkColor: kDlgAccent,
            labelStyle: TextStyle(
              color: _openOnly ? kDlgAccent : kDlgTextSub,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
            backgroundColor: Colors.white.withValues(alpha: 0.05),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '새로고침',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, color: kDlgTextSub),
          ),
        ],
      ),
      content: SizedBox(
        width: 1120,
        height: 640,
        child: _buildBody(reports, selected),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '닫기',
            style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    List<StudentTextbookReport> reports,
    StudentTextbookReport? selected,
  ) {
    if (_error != null) {
      return const Center(
        child: Text(
          '신고 목록을 불러오지 못했습니다.',
          style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w700),
        ),
      );
    }
    if (_reports == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
          ),
        ),
      );
    }
    if (reports.isEmpty) {
      return Center(
        child: Text(
          _openOnly ? '검토 중인 신고가 없습니다.' : '접수된 신고가 없습니다.',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 360,
          child: ListView.separated(
            itemCount: reports.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) =>
                _reportTile(reports[index], reports[index].id == selected?.id),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: selected == null
              ? const SizedBox.shrink()
              : _detailPane(selected),
        ),
      ],
    );
  }

  Widget _reportTile(StudentTextbookReport report, bool selected) {
    final statusLabel = switch (report.status) {
      'open' => '검토 중',
      'accepted' => '신고 인정',
      'rejected' =>
        '반려${report.resolution != null ? ' · ${kTextbookReportResolutionLabels[report.resolution] ?? ''}' : ''}',
      _ => report.status,
    };
    final statusColor = switch (report.status) {
      'open' => const Color(0xFFE0A63C),
      'accepted' => kDlgAccent,
      _ => kDlgTextSub,
    };
    return Material(
      color: selected
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _selectedId = report.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? kDlgAccent.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${report.studentName} · ${report.problemNumber}번',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kDlgText,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${report.bookName} · p.${report.shownPage}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                report.issueTypes
                    .map((t) => kTextbookReportIssueLabels[t] ?? t)
                    .join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailPane(StudentTextbookReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${report.studentName} · ${report.bookName} '
                'p.${report.shownPage} · ${report.problemNumber}번',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgText,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (report.isOpen) ...[
              OutlinedButton(
                onPressed: _resolving ? null : () => _reject(report),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kDlgTextSub,
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
                child: const Text(
                  '반려',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _resolving ? null : () => _accept(report),
                style: FilledButton.styleFrom(
                  backgroundColor: kDlgAccent,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  '신고 인정',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '사유: ${report.issueTypes.map((t) => kTextbookReportIssueLabels[t] ?? t).join(', ')}'
          '${report.note.trim().isEmpty ? '' : '\n메모: ${report.note.trim()}'}',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FutureBuilder<TextbookReportQuestionView>(
                future: _questionView(report),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
                        ),
                      ),
                    );
                  }
                  final view = snapshot.data;
                  if (snapshot.hasError || view == null) {
                    return const Center(
                      child: Text('문항을 불러오지 못했습니다.'),
                    );
                  }
                  if (view.isReady && view.pdfUrl != null) {
                    return _ReportRenderedPdfPage(
                      key: ValueKey<String>('ready|${view.pdfUrl}'),
                      uri: Uri.parse(view.pdfUrl!),
                    );
                  }
                  if (view.isFallback &&
                      view.bodyPdfUrl != null &&
                      view.rawPage != null) {
                    return _ReportCroppedPdfPage(
                      key: ValueKey<String>(
                        'fallback|${view.bodyPdfUrl}|${view.rawPage}',
                      ),
                      uri: Uri.parse(view.bodyPdfUrl!),
                      pageNumber: view.rawPage!,
                      itemRegion1k: view.itemRegion1k,
                    );
                  }
                  return const Center(
                    child: Text('이 문항의 렌더를 찾지 못했습니다.'),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 반려 시 후속 처리 선택.
class _RejectResolutionDialog extends StatefulWidget {
  const _RejectResolutionDialog({required this.report});

  final StudentTextbookReport report;

  @override
  State<_RejectResolutionDialog> createState() =>
      _RejectResolutionDialogState();
}

class _RejectResolutionDialogState extends State<_RejectResolutionDialog> {
  String _resolution = 'redo';
  final TextEditingController _noteController = TextEditingController();

  static const List<(String, String, String)> _options = [
    ('regrade', '저장된 답 채점', '학생이 입력해 둔 답을 그대로 채점해 반영합니다.'),
    ('redo', '재풀이 요청', '별도 확인 문제로 다시 풀게 합니다. 원래 과제 점수는 바뀌지 않습니다.'),
    ('waive', '면제', '이 문항은 풀지 않아도 되는 것으로 처리합니다.'),
  ];

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        '${widget.report.problemNumber}번 신고 반려',
        style: const TextStyle(
          color: kDlgText,
          fontSize: 17,
          fontWeight: FontWeight.w900,
        ),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (key, label, description) in _options)
              RadioListTile<String>(
                value: key,
                groupValue: _resolution,
                onChanged: (value) =>
                    setState(() => _resolution = value ?? 'redo'),
                activeColor: kDlgAccent,
                title: Text(
                  label,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  description,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              maxLines: 2,
              style: const TextStyle(color: kDlgText, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '학생에게 남길 메모 (선택)',
                hintStyle: const TextStyle(color: kDlgTextSub),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '취소',
            style: TextStyle(color: kDlgTextSub, fontWeight: FontWeight.w800),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop((_resolution, _noteController.text.trim())),
          style: FilledButton.styleFrom(
            backgroundColor: kDlgAccent,
            foregroundColor: Colors.white,
          ),
          child: const Text(
            '반려 확정',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

/// 워커가 렌더한 단일 문항 PDF의 정적 표시 — 학생 앱과 동일한 보기.
class _ReportRenderedPdfPage extends StatefulWidget {
  const _ReportRenderedPdfPage({super.key, required this.uri});

  final Uri uri;

  @override
  State<_ReportRenderedPdfPage> createState() => _ReportRenderedPdfPageState();
}

class _ReportRenderedPdfPageState extends State<_ReportRenderedPdfPage> {
  PdfDocument? _document;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final document = await PdfDocument.openUri(widget.uri);
      if (!mounted) {
        await document.dispose();
        return;
      }
      setState(() => _document = document);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    final document = _document;
    if (document != null) unawaited(document.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(child: Text('문항 PDF를 표시할 수 없습니다.'));
    }
    final document = _document;
    if (document == null || document.pages.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
          ),
        ),
      );
    }
    final page = document.pages.first;
    const inset = 10.0;
    return Padding(
      padding: const EdgeInsets.all(inset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 학생 앱과 동일한 가로 우선 contain 계산.
          final aspect = page.height / page.width;
          var width = constraints.maxWidth;
          var height = width * aspect;
          if (height > constraints.maxHeight) {
            height = constraints.maxHeight;
            width = height / aspect;
          }
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              height: height,
              child: PdfPageView(
                document: document,
                pageNumber: 1,
                decoration: const BoxDecoration(color: Colors.white),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 원본 교재 body PDF에서 crop 영역만 확대해 보여주는 fallback 보기.
class _ReportCroppedPdfPage extends StatefulWidget {
  const _ReportCroppedPdfPage({
    super.key,
    required this.uri,
    required this.pageNumber,
    this.itemRegion1k,
  });

  final Uri uri;
  final int pageNumber;
  final List<int>? itemRegion1k;

  @override
  State<_ReportCroppedPdfPage> createState() => _ReportCroppedPdfPageState();
}

class _ReportCroppedPdfPageState extends State<_ReportCroppedPdfPage> {
  PdfDocument? _document;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final document = await PdfDocument.openUri(widget.uri);
      if (!mounted) {
        await document.dispose();
        return;
      }
      setState(() => _document = document);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    final document = _document;
    if (document != null) unawaited(document.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(child: Text('원본 교재 PDF를 열 수 없습니다.'));
    }
    final document = _document;
    if (document == null || document.pages.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
          ),
        ),
      );
    }
    final pageNumber =
        widget.pageNumber.clamp(1, document.pages.length).toInt();
    final region = widget.itemRegion1k;
    if (region == null || region.length != 4) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
          decoration: const BoxDecoration(color: Colors.white),
        ),
      );
    }

    final page = document.pages[pageNumber - 1];
    const padding = 16.0;
    final top = ((region[0] - padding) / 1000).clamp(0.0, 1.0).toDouble();
    final left = ((region[1] - padding) / 1000).clamp(0.0, 1.0).toDouble();
    final bottom = ((region[2] + padding) / 1000).clamp(0.0, 1.0).toDouble();
    final right = ((region[3] + padding) / 1000).clamp(0.0, 1.0).toDouble();
    final regionWidth = right - left;
    final regionHeight = bottom - top;
    if (regionWidth <= 0.01 || regionHeight <= 0.01) {
      return InteractiveViewer(
        minScale: 1,
        maxScale: 6,
        child: PdfPageView(
          document: document,
          pageNumber: pageNumber,
          decoration: const BoxDecoration(color: Colors.white),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 학생 앱 fallback과 동일한 crop contain 계산.
        final widthScale = constraints.maxWidth / (page.width * regionWidth);
        final heightScale =
            constraints.maxHeight / (page.height * regionHeight);
        final scale = widthScale < heightScale ? widthScale : heightScale;
        final pageWidth = page.width * scale;
        final pageHeight = page.height * scale;
        final cropWidth = pageWidth * regionWidth;
        final cropHeight = pageHeight * regionHeight;
        final offsetX =
            (constraints.maxWidth - cropWidth) / 2 - pageWidth * left;
        final offsetY =
            (constraints.maxHeight - cropHeight) / 2 - pageHeight * top;

        return InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          boundaryMargin: const EdgeInsets.all(80),
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: offsetX,
                    top: offsetY,
                    width: pageWidth,
                    height: pageHeight,
                    child: PdfPageView(
                      document: document,
                      pageNumber: pageNumber,
                      decoration: const BoxDecoration(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
