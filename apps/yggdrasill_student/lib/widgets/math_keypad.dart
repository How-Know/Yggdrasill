import 'package:flutter/material.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

/// 수식 입력 키패드.
/// 문자 키는 [onInsert]로, 분수/루트/n제곱근/거듭제곱/순환점 구조 키는
/// 전용 콜백으로 전달해 수식 에디터(MathExpressionEditor)가 슬롯을 만든다.
///
/// 키 구성은 마이그레이션된 정답 DB 전수 감사 결과를 커버하고,
/// 아직 마이그레이션 전인 교재(기하 기호 등)를 위한 선반을 포함한다.
class MathKeypad extends StatefulWidget {
  const MathKeypad({
    super.key,
    required this.onInsert,
    required this.onFraction,
    required this.onSqrt,
    required this.onNthRoot,
    required this.onPower,
    required this.onRepeatingDot,
    required this.onBackspace,
    required this.onClear,
  });

  final ValueChanged<String> onInsert;
  final VoidCallback onFraction;
  final VoidCallback onSqrt;
  final VoidCallback onNthRoot;
  final VoidCallback onPower;
  final VoidCallback onRepeatingDot;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  @override
  State<MathKeypad> createState() => _MathKeypadState();
}

enum _Shelf { variables, units, geometry }

class _MathKeypadState extends State<MathKeypad> {
  _Shelf _shelf = _Shelf.variables;

  /// 자주 쓰는 순서로 앞에 배치하고, 나머지 알파벳도 스크롤로 제공.
  static final List<String> _variables = () {
    const common = ['x', 'y', 'z', 'a', 'b', 'c', 'k', 'm', 'n', 'p'];
    final lower = List.generate(26, (i) => String.fromCharCode(97 + i))
        .where((c) => !common.contains(c));
    final upper = List.generate(26, (i) => String.fromCharCode(65 + i));
    return [...common, ...lower, ...upper, 'α', 'β', 'γ', 'δ'];
  }();

  static const List<String> _units = [
    'cm', 'm', 'km', 'mm', 'cm^(2)', 'm^(2)', 'cm^(3)', 'm^(3)',
    'g', 'kg', 't', 'L', 'mL', '원', '개', '명', '초', '분', '시간',
    '배', '장', '점', '마리', '살', '번', '가지',
  ];

  static const List<String> _geometry = [
    '∠', '△', '□', '≡', '∽', '⊥', '∥', '⌒', '°', 'Ⓞ', '…',
  ];

  /// 지수 표기가 있는 단위(cm² 등)는 보기 좋게 표시
  static const Map<String, String> _unitLabels = {
    'cm^(2)': 'cm²', 'm^(2)': 'm²', 'cm^(3)': 'cm³', 'm^(3)': 'm³',
    'Ⓞ': '○',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final keyColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);
    final accentColor = YggGlassTokens.confirmActionColor.withValues(
      alpha: isDark ? 0.22 : 0.14,
    );

    Widget key(
      String label, {
      VoidCallback? onTap,
      Widget? child,
      int flex = 1,
      bool accent = false,
    }) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: accent ? accentColor : keyColor,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: onTap ?? () => widget.onInsert(label),
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 42,
                child: Center(
                  child: child ??
                      Text(
                        label,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 분수 키 아이콘 (▢/▢ 세로 표기)
    Widget fracIcon() {
      final color = theme.textTheme.titleMedium?.color ?? Colors.black;
      Widget box() => Container(
            width: 11,
            height: 9,
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 1.2),
              borderRadius: BorderRadius.circular(2),
            ),
          );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          box(),
          Container(
            width: 15,
            height: 1.4,
            margin: const EdgeInsets.symmetric(vertical: 2),
            color: color,
          ),
          box(),
        ],
      );
    }

    Widget shelfChip(String label, _Shelf value) {
      final selected = _shelf == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          labelStyle: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: selected ? YggGlassTokens.confirmActionColor : null,
          ),
          selectedColor: accentColor,
          onSelected: (_) => setState(() => _shelf = value),
        ),
      );
    }

    final shelfItems = switch (_shelf) {
      _Shelf.variables => _variables,
      _Shelf.units => _units,
      _Shelf.geometry => _geometry,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            shelfChip('변수', _Shelf.variables),
            shelfChip('단위', _Shelf.units),
            shelfChip('기하', _Shelf.geometry),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final v in shelfItems)
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: Material(
                    color: keyColor,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () => widget.onInsert(v),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 52),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Center(
                          child: Text(
                            _unitLabels[v] ?? v,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontStyle: _shelf == _Shelf.variables &&
                                      v.length == 1
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Row(children: [
          key('7'), key('8'), key('9'), key('÷', onTap: () => widget.onInsert('/')),
          key('분수', onTap: widget.onFraction, child: fracIcon(), accent: true),
          key('√', onTap: widget.onSqrt, accent: true),
          key('ⁿ√', onTap: widget.onNthRoot, accent: true,
              child: Text('ⁿ√',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        Row(children: [
          key('4'), key('5'), key('6'), key('×', onTap: () => widget.onInsert('*')),
          key('('), key(')'),
          key('xⁿ', onTap: widget.onPower, accent: true,
              child: Text('xⁿ',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        Row(children: [
          key('1'), key('2'), key('3'), key('-'),
          key('<'), key('>'),
          key('0.ẋ', onTap: widget.onRepeatingDot, accent: true,
              child: Text('0.ẋ',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        Row(children: [
          key('0'), key('.'), key(','), key('+'),
          key('='), key('≤'), key('≥'),
        ]),
        Row(children: [
          key('±'), key('π'), key('%'), key(':'), key('|'), key('≠'),
          key('또는', onTap: () => widget.onInsert('또는'),
              child: Text('또는',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        Row(children: [
          key('', onTap: widget.onBackspace, flex: 3,
              child: const Icon(Icons.backspace_outlined, size: 20)),
          key('', onTap: widget.onClear, flex: 4,
              child: Text('모두 지우기',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600))),
        ]),
      ],
    );
  }
}
