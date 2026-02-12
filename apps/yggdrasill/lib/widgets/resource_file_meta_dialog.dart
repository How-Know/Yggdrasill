import 'package:flutter/material.dart';

import '../services/data_manager.dart';
import 'dialog_tokens.dart';

class ResourceFileMetaDialog extends StatefulWidget {
  final String? bookId;
  final String fileName;
  final String? description;
  final String? categoryLabel;
  final String? parentLabel;
  final String? gradeLabel;
  final int? linkCount;
  final bool hasCover;
  final bool hasIcon;

  const ResourceFileMetaDialog({
    super.key,
    this.bookId,
    required this.fileName,
    this.description,
    this.categoryLabel,
    this.parentLabel,
    this.gradeLabel,
    this.linkCount,
    required this.hasCover,
    required this.hasIcon,
  });

  @override
  State<ResourceFileMetaDialog> createState() => _ResourceFileMetaDialogState();
}

class _ResourceFileMetaDialogState extends State<ResourceFileMetaDialog> {
  bool _loading = false;
  String? _errorText;
  List<_BigUnitNode> _units = const <_BigUnitNode>[];
  Map<String, _SmallUnitStats> _statsBySmallKey = const <String, _SmallUnitStats>{};

  bool get _isTextbook => (widget.categoryLabel ?? '').trim() == '교재';
  bool get _hasBookId => (widget.bookId ?? '').trim().isNotEmpty;
  bool get _hasGradeLabel => (widget.gradeLabel ?? '').trim().isNotEmpty;
  bool get _canLoadUnitStats => _isTextbook && _hasBookId && _hasGradeLabel;

  @override
  void initState() {
    super.initState();
    _loadUnitStats();
  }

  Future<void> _loadUnitStats() async {
    if (!_canLoadUnitStats) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final payloadRow = await DataManager.instance.loadTextbookMetadataPayload(
        bookId: widget.bookId!.trim(),
        gradeLabel: widget.gradeLabel!.trim(),
      );
      final rows = await DataManager.instance.loadHomeworkUnitStats(
        bookId: widget.bookId!.trim(),
        gradeLabel: widget.gradeLabel!.trim(),
        groupLevel: 'small',
      );
      final units = _parseUnits(payloadRow?['payload']);
      final stats = _parseSmallStats(rows);
      if (!mounted) return;
      setState(() {
        _units = units;
        _statsBySmallKey = stats;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = '단원 통계를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  List<_BigUnitNode> _parseUnits(dynamic payload) {
    if (payload is! Map) return const <_BigUnitNode>[];
    final unitsRaw = payload['units'];
    if (unitsRaw is! List) return const <_BigUnitNode>[];
    final units = unitsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    units.sort((a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));

    final out = <_BigUnitNode>[];
    for (final u in units) {
      final big = _BigUnitNode(
        name: (u['name'] as String?)?.trim().isNotEmpty == true
            ? (u['name'] as String).trim()
            : '대단원',
        orderIndex: _orderIndex(u['order_index']),
      );
      final midsRaw = u['middles'];
      if (midsRaw is List) {
        final mids = midsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        mids.sort((a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));
        for (final m in mids) {
          final mid = _MidUnitNode(
            name: (m['name'] as String?)?.trim().isNotEmpty == true
                ? (m['name'] as String).trim()
                : '중단원',
            orderIndex: _orderIndex(m['order_index']),
          );
          final smallsRaw = m['smalls'];
          if (smallsRaw is List) {
            final smalls = smallsRaw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            smalls.sort((a, b) => _orderIndex(a['order_index']).compareTo(_orderIndex(b['order_index'])));
            for (final s in smalls) {
              mid.smalls.add(
                _SmallUnitNode(
                  name: (s['name'] as String?)?.trim().isNotEmpty == true
                      ? (s['name'] as String).trim()
                      : '소단원',
                  orderIndex: _orderIndex(s['order_index']),
                  startPage: _toInt(s['start_page']),
                  endPage: _toInt(s['end_page']),
                ),
              );
            }
          }
          big.middles.add(mid);
        }
      }
      out.add(big);
    }
    return out;
  }

  Map<String, _SmallUnitStats> _parseSmallStats(List<Map<String, dynamic>> rows) {
    final out = <String, _SmallUnitStats>{};
    for (final row in rows) {
      final big = _toInt(row['big_order']);
      final mid = _toInt(row['mid_order']);
      final small = _toInt(row['small_order']);
      if (big == null || mid == null || small == null) continue;
      out[_smallKey(big, mid, small)] = _SmallUnitStats(
        avgMinutes: _toDouble(row['avg_minutes']),
        avgChecks: _toDouble(row['avg_checks']),
        totalChecks: _toInt(row['total_checks']),
        totalStudents: _toInt(row['total_students']),
      );
    }
    return out;
  }

  int _orderIndex(dynamic v) => _toInt(v) ?? (1 << 30);

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  String _smallKey(int big, int mid, int small) => '$big|$mid|$small';

  String _orderText(int order) => order >= (1 << 29) ? '-' : '${order + 1}';

  String _formatDouble(double? value, {int fraction = 1}) {
    if (value == null) return '-';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(fraction);
  }

  String _formatMinutes(double? value) {
    if (value == null) return '-';
    return '${_formatDouble(value, fraction: 2)}분';
  }

  String _formatChecks(double? value) {
    if (value == null) return '-';
    return '${_formatDouble(value, fraction: 2)}회';
  }

  String _formatTotalChecks(int? value) => value == null ? '-' : '${value}건';
  String _formatStudents(int? value) => value == null ? '-' : '${value}명';

  String _smallPageText(_SmallUnitNode small) {
    if (small.startPage == null && small.endPage == null) return '';
    if (small.startPage != null && small.endPage != null) {
      if (small.startPage == small.endPage) return 'p.${small.startPage}';
      return 'p.${small.startPage}-${small.endPage}';
    }
    return small.startPage != null ? 'p.${small.startPage}' : 'p.${small.endPage}';
  }

  Widget _buildInfoPanel({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildUnitStatsSection() {
    if (!_isTextbook) {
      return _buildNoticeCard('교재 메뉴에서만 단원 통계를 표시해요.');
    }
    if (!_hasGradeLabel) {
      return _buildNoticeCard('과정 정보가 없어 단원 통계를 조회할 수 없어요.');
    }
    if (!_hasBookId) {
      return _buildNoticeCard('교재 식별 정보가 없어 단원 통계를 조회할 수 없어요.');
    }
    if (_loading) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: kDlgPanelBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDlgBorder),
        ),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation<Color>(kDlgTextSub),
            ),
          ),
        ),
      );
    }
    if (_errorText != null) {
      return _buildNoticeCard(_errorText!);
    }
    if (_units.isEmpty) {
      return _buildNoticeCard('해당 교재의 메타데이터 단원 정보가 없습니다.');
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: Column(
          children: [
            for (final big in _units) _buildBigTile(big),
          ],
        ),
      ),
    );
  }

  Widget _buildBigTile(_BigUnitNode big) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
      iconColor: kDlgTextSub,
      collapsedIconColor: kDlgTextSub,
      title: Text(
        '${_orderText(big.orderIndex)}. ${big.name}',
        style: const TextStyle(
          color: kDlgText,
          fontWeight: FontWeight.w700,
        ),
      ),
      children: [
        if (big.middles.isEmpty)
          const Padding(
            padding: EdgeInsets.only(left: 8, right: 8, bottom: 8),
            child: Text(
              '하위 중단원이 없습니다.',
              style: TextStyle(color: kDlgTextSub, fontSize: 12),
            ),
          ),
        for (final mid in big.middles) _buildMidTile(big, mid),
      ],
    );
  }

  Widget _buildMidTile(_BigUnitNode big, _MidUnitNode mid) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.only(left: 8, right: 8),
      childrenPadding: const EdgeInsets.only(left: 8, right: 2, bottom: 6),
      iconColor: kDlgTextSub,
      collapsedIconColor: kDlgTextSub,
      title: Text(
        '${_orderText(big.orderIndex)}.${_orderText(mid.orderIndex)} ${mid.name}',
        style: const TextStyle(
          color: kDlgText,
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
        ),
      ),
      children: [
        if (mid.smalls.isEmpty)
          const Padding(
            padding: EdgeInsets.only(left: 8, right: 8, bottom: 8),
            child: Text(
              '하위 소단원이 없습니다.',
              style: TextStyle(color: kDlgTextSub, fontSize: 12),
            ),
          ),
        for (final small in mid.smalls) _buildSmallRow(big, mid, small),
      ],
    );
  }

  Widget _buildSmallRow(
    _BigUnitNode big,
    _MidUnitNode mid,
    _SmallUnitNode small,
  ) {
    final key = _smallKey(big.orderIndex, mid.orderIndex, small.orderIndex);
    final stats = _statsBySmallKey[key];
    final pageText = _smallPageText(small);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_orderText(big.orderIndex)}.${_orderText(mid.orderIndex)}.(${_orderText(small.orderIndex)}) ${small.name}',
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          if (pageText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              pageText,
              style: const TextStyle(
                color: kDlgTextSub,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: kDlgPanelBg.withOpacity(0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kDlgBorder.withOpacity(0.8)),
            ),
            child: Column(
              children: [
                _StatListRow(
                  label: '평균 시간',
                  value: _formatMinutes(stats?.avgMinutes),
                ),
                const Divider(height: 1, thickness: 1, color: kDlgBorder),
                _StatListRow(
                  label: '평균 검사',
                  value: _formatChecks(stats?.avgChecks),
                ),
                const Divider(height: 1, thickness: 1, color: kDlgBorder),
                _StatListRow(
                  label: '검사 건수',
                  value: _formatTotalChecks(stats?.totalChecks),
                ),
                const Divider(height: 1, thickness: 1, color: kDlgBorder),
                _StatListRow(
                  label: '참여자수',
                  value: _formatStudents(stats?.totalStudents),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: kDlgPanelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDlgBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: kDlgTextSub,
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kDlgBorder),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      title: const Text(
        '교재 정보',
        style: TextStyle(
          color: kDlgText,
          fontWeight: FontWeight.w900,
          fontSize: 20,
        ),
      ),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 620),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const YggDialogSectionHeader(
                  icon: Icons.info_outline,
                  title: '기본 정보',
                ),
                _buildInfoPanel(
                  children: [
                    _MetaRow(label: '이름', value: widget.fileName),
                    if ((widget.description ?? '').trim().isNotEmpty)
                      _MetaRow(label: '설명', value: widget.description!.trim()),
                    if ((widget.categoryLabel ?? '').trim().isNotEmpty)
                      _MetaRow(label: '분류', value: widget.categoryLabel!.trim()),
                    if ((widget.parentLabel ?? '').trim().isNotEmpty)
                      _MetaRow(label: '폴더', value: widget.parentLabel!.trim()),
                  ],
                ),
                const SizedBox(height: 12),
                const YggDialogSectionHeader(
                  icon: Icons.link_outlined,
                  title: '연결 정보',
                ),
                _buildInfoPanel(
                  children: [
                    _MetaRow(
                      label: '과정',
                      value: (widget.gradeLabel ?? '').trim().isEmpty
                          ? '-'
                          : widget.gradeLabel!.trim(),
                    ),
                    _MetaRow(
                      label: '링크',
                      value: widget.linkCount == null ? '-' : '${widget.linkCount}개',
                    ),
                    _MetaRow(label: '표지', value: widget.hasCover ? '있음' : '없음'),
                    _MetaRow(label: '아이콘', value: widget.hasIcon ? '있음' : '없음'),
                  ],
                ),
                const SizedBox(height: 12),
                const YggDialogSectionHeader(
                  icon: Icons.account_tree_outlined,
                  title: '소단원 통계',
                ),
                _buildUnitStatsSection(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: kDlgTextSub,
          ),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _MetaRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(
              label,
              style: const TextStyle(
                color: kDlgTextSub,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatListRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatListRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: kDlgTextSub,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

class _BigUnitNode {
  final String name;
  final int orderIndex;
  final List<_MidUnitNode> middles = <_MidUnitNode>[];

  _BigUnitNode({
    required this.name,
    required this.orderIndex,
  });
}

class _MidUnitNode {
  final String name;
  final int orderIndex;
  final List<_SmallUnitNode> smalls = <_SmallUnitNode>[];

  _MidUnitNode({
    required this.name,
    required this.orderIndex,
  });
}

class _SmallUnitNode {
  final String name;
  final int orderIndex;
  final int? startPage;
  final int? endPage;

  _SmallUnitNode({
    required this.name,
    required this.orderIndex,
    required this.startPage,
    required this.endPage,
  });
}

class _SmallUnitStats {
  final double? avgMinutes;
  final double? avgChecks;
  final int? totalChecks;
  final int? totalStudents;

  const _SmallUnitStats({
    required this.avgMinutes,
    required this.avgChecks,
    required this.totalChecks,
    required this.totalStudents,
  });
}
