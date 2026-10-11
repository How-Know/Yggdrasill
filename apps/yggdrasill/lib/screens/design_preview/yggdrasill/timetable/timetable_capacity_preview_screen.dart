import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../widgets/dialog_tokens.dart';
import '../../../../widgets/pill_tab_selector.dart';
import '../settings/fab_tab_bar_preview.dart';

/// 시간표 인원 히트맵 정리 시안 비교 (mock 전용, 기능 연결 없음).
/// 현재 / ① 70% 미만 한 색 / ② 같은 인원 구분선 제거 / ③ 4단계 + 띠 묶기.
class TimetableCapacityPreviewScreen extends StatefulWidget {
  const TimetableCapacityPreviewScreen({super.key});

  @override
  State<TimetableCapacityPreviewScreen> createState() =>
      _TimetableCapacityPreviewScreenState();
}

enum _Variant { current, flatLow, mergeSame, bands }

const List<String> _kVariantTabs = ['현재', '① 70% 통일', '② 선 제거', '③ 추천'];
const List<String> _kVariantNotes = [
  '지금 학습앱 상태. 인원 1명마다 밝기가 달라지고, 30분 칸마다 세로선과 숫자가 있다.',
  '정원 70% 미만은 모두 같은 옅은 색. 70% 이상만 인원에 따라 진해진다. 칸 선과 숫자는 그대로.',
  '밝기는 현재와 같고, 앞 칸과 인원이 같으면 세로선을 없애 하나로 잇는다. 숫자는 인원이 바뀌는 칸에만.',
  '색은 여유·혼잡·정원 3단계뿐. 같은 단계는 둥근 띠 하나로 묶고, 숫자는 띠 시작(밝게)과 띠 안에서 바뀌는 곳(흐리게)에만. 세로선은 정시에만.',
];

// ── mock 데이터 ─────────────────────────────────────────────

const int _kCapacity = 10;
const int _kStartHour = 15;
const int _kBlockCount = 15; // 15:00 ~ 22:00
const List<String> _kDays = ['월', '화', '수', '목', '금', '토', '일'];
const int _kTodayIdx = 3;
const int _kNowBlock = 3; // 16:30

const List<List<int>> _kCounts = [
  [5, 6, 6, 7, 7, 8, 8, 7, 7, 6, 6, 5, 4, 3, 2],
  [3, 4, 5, 5, 7, 8, 9, 7, 6, 8, 7, 5, 4, 3, 2],
  [2, 7, 8, 8, 5, 5, 5, 4, 4, 4, 4, 4, 3, 3, 2],
  [3, 4, 10, 11, 8, 6, 6, 6, 6, 6, 8, 7, 5, 4, 3],
  [4, 4, 5, 8, 6, 6, 6, 6, 6, 6, 6, 5, 5, 4, 3],
  [8, 8, 6, 6, 6, 5, 5, 5, 4, 4, 3, 2, 1, 0, 0],
  [1, 0, 0, 0, 0, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0],
];

bool _isBreak(int day, int block) => day == 6 && block >= 1 && block <= 4;

int _countAt(int day, int block) =>
    _isBreak(day, block) ? 0 : _kCounts[day][block];

/// 0 비어 있음 / 1 여유(70% 미만) / 2 혼잡(70~99%) / 3 정원 도달.
int _levelFor(int count) {
  if (count <= 0) return 0;
  if (count >= _kCapacity) return 3;
  if (count >= _kCapacity * 0.7) return 2;
  return 1;
}

bool _isHourBoundary(int block) => (_kStartHour * 60 + block * 30) % 60 == 0;

enum _ChipKind { makeup, extra, trial, inquiry }

class _MockChip {
  final int day;
  final int block;
  final _ChipKind kind;
  final String text;
  final bool completed;

  const _MockChip(
    this.day,
    this.block,
    this.kind,
    this.text, {
    this.completed = false,
  });
}

const List<_MockChip> _kChips = [
  _MockChip(1, 0, _ChipKind.makeup, '전성호 보강'),
  _MockChip(1, 4, _ChipKind.makeup, '박성아 보강', completed: true),
  _MockChip(1, 10, _ChipKind.makeup, '지건우 보강'),
  _MockChip(3, 10, _ChipKind.makeup, '박도윤 보강'),
  _MockChip(3, 6, _ChipKind.inquiry, '중2 문의'),
  _MockChip(4, 8, _ChipKind.trial, '김하린 체험'),
  _MockChip(0, 12, _ChipKind.extra, '이서준 추가'),
];

// ── 색 규칙: 회색 명도(양) / 초록(지금·오늘) / 앰버(정원 도달) ──────────

const Color _kAmber = Color(0xFFF2B45B);

class _Palette {
  final PreviewAcademyPanelStyle panel;
  final Color data;

  _Palette(Brightness brightness)
      : panel = FabTabBarTokens.previewAcademyPanelStyleFor(brightness),
        data = brightness == Brightness.dark ? Colors.white : Colors.black;

  Color get divider => panel.divider;
  Color get ink => panel.title;
  Color get hint => panel.hint;
  Color get hatch => data.withValues(alpha: 0.06);
  Color get hoverColumn => data.withValues(alpha: 0.03);
  Color get chipFill => data.withValues(alpha: 0.06);
  Color get chipBorder => data.withValues(alpha: 0.10);
  Color get flatLow => data.withValues(alpha: 0.05);
  Color get bandLow => data.withValues(alpha: 0.06);
  Color get bandHigh => data.withValues(alpha: 0.15);
  Color get fullFill => _kAmber.withValues(alpha: 0.16);

  Color heat(int count) =>
      data.withValues(alpha: 0.03 + 0.11 * (count / _kCapacity).clamp(0.0, 1.0));
}

const double _kDayLabelWidth = 60;
const double _kHeaderHeight = 40;
const double _kChipTop = 32;
const double _kBandInset = 6;

TextStyle _numberStyle(Color color) => TextStyle(
      color: color,
      fontSize: 12,
      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
      fontWeight: FontWeight.w700,
      height: 1.0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

class _TimetableCapacityPreviewScreenState
    extends State<TimetableCapacityPreviewScreen> {
  _Variant _variant = _Variant.current;
  int? _hoverDay;
  int? _hoverBlock;

  void _setHover(int? day, int? block) {
    if (_hoverDay == day && _hoverBlock == block) return;
    setState(() {
      _hoverDay = day;
      _hoverBlock = block;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = _Palette(Theme.of(context).brightness);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        foregroundColor: palette.ink,
        title: const Text('시간표 인원 표시 시안'),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PillTabSelector(
                  selectedIndex: _variant.index,
                  tabs: _kVariantTabs,
                  width: 480,
                  height: 44,
                  onTabSelected: (i) =>
                      setState(() => _variant = _Variant.values[i]),
                ),
                const SizedBox(width: 24),
                Expanded(child: _Legend(palette: palette, variant: _variant)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _kVariantNotes[_variant.index],
              style: TextStyle(
                color: palette.hint,
                fontSize: 14,
                fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _TimetableMock(
                variant: _variant,
                palette: palette,
                hoverDay: _hoverDay,
                hoverBlock: _hoverBlock,
                onHover: _setHover,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final _Palette palette;
  final _Variant variant;

  const _Legend({required this.palette, required this.variant});

  @override
  Widget build(BuildContext context) {
    Widget swatch(Widget child) => ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(width: 16, height: 10, child: child),
        );

    Widget item(Widget sw, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          sw,
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: palette.hint,
              fontSize: 13,
              fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
            ),
          ),
        ],
      );
    }

    Widget solid(Color c) => swatch(ColoredBox(color: c));
    Widget gradient(Color a, Color b) => swatch(
          DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(colors: [a, b])),
          ),
        );

    final items = <Widget>[];
    switch (variant) {
      case _Variant.current:
      case _Variant.mergeSame:
        items.add(item(
          gradient(palette.heat(1), palette.heat(_kCapacity - 1)),
          '적음 → 많음 (1명마다 다름)',
        ));
        break;
      case _Variant.flatLow:
        items
          ..add(item(solid(palette.flatLow), '70% 미만 (한 색)'))
          ..add(item(
            gradient(palette.heat(7), palette.heat(_kCapacity - 1)),
            '70% 이상 (많을수록 진함)',
          ));
        break;
      case _Variant.bands:
        items
          ..add(item(solid(palette.bandLow), '여유 (70% 미만)'))
          ..add(item(solid(palette.bandHigh), '혼잡 (70% 이상)'));
        break;
    }
    items
      ..add(item(solid(_kAmber.withValues(alpha: 0.40)), '정원 도달'))
      ..add(item(solid(kDlgAccent.withValues(alpha: 0.6)), '지금·오늘'));

    return Wrap(spacing: 16, runSpacing: 8, children: items);
  }
}

class _Band {
  final int start;
  final int end;
  final int level;

  const _Band(this.start, this.end, this.level);
}

List<_Band> _bandsFor(int day) {
  final bands = <_Band>[];
  int b = 0;
  while (b < _kBlockCount) {
    final level = _levelFor(_countAt(day, b));
    if (level == 0) {
      b++;
      continue;
    }
    int e = b;
    while (e + 1 < _kBlockCount &&
        _levelFor(_countAt(day, e + 1)) == level) {
      e++;
    }
    bands.add(_Band(b, e, level));
    b = e + 1;
  }
  return bands;
}

class _TimetableMock extends StatelessWidget {
  final _Variant variant;
  final _Palette palette;
  final int? hoverDay;
  final int? hoverBlock;
  final void Function(int? day, int? block) onHover;

  const _TimetableMock({
    required this.variant,
    required this.palette,
    required this.hoverDay,
    required this.hoverBlock,
    required this.onHover,
  });

  bool _countChanged(int day, int block) {
    if (block == 0 || _isBreak(day, block - 1)) return true;
    return _countAt(day, block - 1) != _countAt(day, block);
  }

  bool _isBandStart(int day, int block) {
    if (block == 0) return true;
    return _levelFor(_countAt(day, block - 1)) !=
        _levelFor(_countAt(day, block));
  }

  /// 표시할 숫자 색. null이면 숫자를 그리지 않는다.
  Color? _numberColor(int day, int block) {
    final count = _countAt(day, block);
    if (count <= 0) return null;
    final isFull = count >= _kCapacity;
    final isHover = hoverDay == day && hoverBlock == block;
    final dim = palette.hint.withValues(alpha: 0.5);
    switch (variant) {
      case _Variant.current:
      case _Variant.flatLow:
        if (isFull) return _kAmber;
        return _countChanged(day, block) ? palette.ink : dim;
      case _Variant.mergeSame:
        if (_countChanged(day, block)) return isFull ? _kAmber : palette.ink;
        return isHover ? palette.hint : null;
      case _Variant.bands:
        if (_isBandStart(day, block)) return isFull ? _kAmber : palette.ink;
        if (_countChanged(day, block) || isHover) return palette.hint;
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colWidth = math.max(
          96.0,
          (constraints.maxWidth - _kDayLabelWidth) / _kBlockCount,
        );
        final rowHeight = math.max(
          92.0,
          (constraints.maxHeight - _kHeaderHeight) / _kDays.length,
        );
        final gridWidth = colWidth * _kBlockCount;
        return SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: MouseRegion(
              onExit: (_) => onHover(null, null),
              child: SizedBox(
                width: _kDayLabelWidth + gridWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(colWidth),
                    for (int d = 0; d < _kDays.length; d++)
                      _buildDayRow(d, colWidth, rowHeight, gridWidth),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(double colWidth) {
    return SizedBox(
      height: _kHeaderHeight,
      child: Row(
        children: [
          SizedBox(
            width: _kDayLabelWidth,
            child: Center(
              child: Text(
                '요일',
                style: TextStyle(color: palette.hint, fontSize: 13),
              ),
            ),
          ),
          for (int b = 0; b < _kBlockCount; b++)
            SizedBox(
              width: colWidth,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _timeLabel(b),
                    style: _numberStyle(
                      b == _kNowBlock
                          ? kDlgAccent
                          : (b == hoverBlock ? palette.ink : palette.hint),
                    ).copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _timeLabel(int block) {
    final minutes = _kStartHour * 60 + block * 30;
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildDayRow(
    int day,
    double colWidth,
    double rowHeight,
    double gridWidth,
  ) {
    final isToday = day == _kTodayIdx;
    final isBands = variant == _Variant.bands;
    return Container(
      height: rowHeight,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: [
          Container(
            width: _kDayLabelWidth,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: isToday ? kDlgAccent : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _kDays[day],
              style: TextStyle(
                color: isToday ? kDlgAccent : palette.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: gridWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Row(
                  children: [
                    for (int b = 0; b < _kBlockCount; b++)
                      MouseRegion(
                        onEnter: (_) => onHover(day, b),
                        child: _buildCellBackground(day, b, colWidth),
                      ),
                  ],
                ),
                if (isBands)
                  for (final band in _bandsFor(day))
                    Positioned(
                      left: band.start * colWidth + 3,
                      width: (band.end - band.start + 1) * colWidth - 6,
                      top: _kBandInset,
                      bottom: _kBandInset,
                      child: IgnorePointer(child: _buildBand(band.level)),
                    ),
                for (int b = 0; b < _kBlockCount; b++)
                  if (_numberColor(day, b) case final Color color)
                    Positioned(
                      left: b * colWidth + (isBands ? 12 : 8),
                      top: isBands ? _kBandInset + 7 : 8,
                      child: IgnorePointer(
                        child: Text(
                          '${_countAt(day, b)}',
                          style: _numberStyle(color),
                        ),
                      ),
                    ),
                for (final chip in _kChips.where((c) => c.day == day))
                  Positioned(
                    left: chip.block * colWidth + (isBands ? 8 : 4),
                    top: _kChipTop,
                    width: colWidth - 8,
                    child: _SlotChip(chip: chip, palette: palette),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBand(int level) {
    final isFull = level == 3;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isFull
            ? palette.fullFill
            : (level == 2 ? palette.bandHigh : palette.bandLow),
        borderRadius: BorderRadius.circular(10),
        border: isFull
            ? Border.all(color: _kAmber.withValues(alpha: 0.55))
            : null,
      ),
    );
  }

  Color? _cellTint(int count) {
    if (count <= 0) return null;
    if (count >= _kCapacity) return palette.fullFill;
    switch (variant) {
      case _Variant.current:
      case _Variant.mergeSame:
        return palette.heat(count);
      case _Variant.flatLow:
        return count >= _kCapacity * 0.7 ? palette.heat(count) : palette.flatLow;
      case _Variant.bands:
        return null;
    }
  }

  bool _showLeftDivider(int day, int block) {
    switch (variant) {
      case _Variant.current:
      case _Variant.flatLow:
        return true;
      case _Variant.mergeSame:
        if (block == 0) return true;
        if (_isBreak(day, block) != _isBreak(day, block - 1)) return true;
        return _countAt(day, block) != _countAt(day, block - 1);
      case _Variant.bands:
        return block > 0 && _isHourBoundary(block);
    }
  }

  Widget _buildCellBackground(int day, int block, double colWidth) {
    final isBreak = _isBreak(day, block);
    final count = _countAt(day, block);
    final isNow = day == _kTodayIdx && block == _kNowBlock;
    final isHoverColumn = hoverBlock == block;
    final isFull = count >= _kCapacity;
    final showFullTop = isFull && variant != _Variant.bands;
    final dividerColor = variant == _Variant.bands
        ? palette.divider.withValues(alpha: palette.divider.a * 0.6)
        : palette.divider;
    return Container(
      width: colWidth,
      decoration: BoxDecoration(
        color: _cellTint(count),
        border: Border(
          left: _showLeftDivider(day, block)
              ? BorderSide(color: dividerColor)
              : BorderSide.none,
          top: showFullTop
              ? const BorderSide(color: _kAmber, width: 2)
              : BorderSide.none,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (isHoverColumn) ColoredBox(color: palette.hoverColumn),
          if (isNow) ColoredBox(color: kDlgAccent.withValues(alpha: 0.10)),
          if (isBreak) ...[
            CustomPaint(painter: _HatchPainter(color: palette.hatch)),
            Center(
              child: Text(
                '휴식',
                style: TextStyle(
                  color: palette.hint,
                  fontSize: 13,
                  fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 휴식 칸: 진한 블록 대신 옅은 사선.
class _HatchPainter extends CustomPainter {
  final Color color;

  _HatchPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 10.0;
    for (double x = -size.height; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HatchPainter old) => old.color != color;
}

/// 보강·추가·체험·문의: 색 바탕 대신 같은 중립 캡슐 + 앞 아이콘.
class _SlotChip extends StatelessWidget {
  final _MockChip chip;
  final _Palette palette;

  const _SlotChip({required this.chip, required this.palette});

  IconData get _icon {
    switch (chip.kind) {
      case _ChipKind.makeup:
        return Icons.replay_rounded;
      case _ChipKind.extra:
        return Icons.add_rounded;
      case _ChipKind.trial:
        return Icons.auto_awesome_rounded;
      case _ChipKind.inquiry:
        return Icons.help_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: chip.completed ? 0.45 : 1.0,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          height: 26,
          padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
          decoration: BoxDecoration(
            color: palette.chipFill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.chipBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 14, color: palette.hint),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  chip.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 12.5,
                    fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
