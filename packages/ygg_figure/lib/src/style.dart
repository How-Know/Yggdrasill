/// 그림체 규격. 길이는 모두 mm, 글자는 pt.
///
/// 한 번 쓰인 규격은 고치지 않는다. 값을 바꿀 때는 새 이름(예: csat-2026.2)으로 더하고,
/// 그림 파일은 자기가 그려진 규격 이름을 적어 두므로 예전 그림은 그대로 나온다.
class FigureStyle {
  const FigureStyle({
    required this.name,
    required this.mainLine,
    required this.thinLine,
    required this.midLine,
    required this.dashOn,
    required this.dashOff,
    required this.dotRadius,
    required this.smallDotRadius,
    required this.openDotLine,
    required this.arrowLength,
    required this.arrowWidth,
    required this.arrowNotch,
    required this.lightGray,
    required this.darkGray,
    required this.labelPt,
    required this.labelGap,
    required this.angleRadius,
    required this.rightAngleSize,
    required this.bodyPt,
  });

  final String name;

  /// 도형의 변·곡선(굵은 선)과 축·보조선(가는 선)의 굵기.
  final double mainLine, thinLine;

  /// 입체 그림의 평면·단면처럼 주인공이 아닌 도형에 쓰는 중간 굵기.
  final double midLine;

  /// 점선의 선 길이와 빈 길이.
  final double dashOn, dashOff;

  /// 그래프 끝점(채운 점·빈 점)과 도형 위 작은 점의 반지름, 빈 점의 테두리 굵기.
  final double dotRadius, smallDotRadius, openDotLine;

  /// 축 화살촉의 길이·너비·뒤쪽이 파인 깊이.
  final double arrowLength, arrowWidth, arrowNotch;

  /// 채움 회색(0=검정, 1=흰색).
  final double lightGray, darkGray;

  /// 라벨 글자 크기와, 점에서 라벨까지의 기본 간격.
  final double labelPt, labelGap;

  /// 각 표시 호의 반지름, 직각 표시의 한 변.
  final double angleRadius, rightAngleSize;

  /// 이 규격을 잰 문제지의 본문 글자 크기. 다른 크기의 본문에 넣을 때 이 비율로 줄이거나 키운다.
  final double bodyPt;

  /// 2024~2026 수능 문제지 원본 그림(600~700ppi)에서 잰 값.
  static const csat2026 = FigureStyle(
    name: 'csat-2026.1',
    mainLine: 0.28,
    thinLine: 0.11,
    midLine: 0.17,
    dashOn: 0.55,
    dashOff: 0.35,
    dotRadius: 0.65,
    smallDotRadius: 0.4,
    openDotLine: 0.15,
    arrowLength: 1.7,
    arrowWidth: 1.05,
    arrowNotch: 0.25,
    lightGray: 0.847,
    darkGray: 0.69,
    labelPt: 10.5,
    labelGap: 0.7,
    angleRadius: 3.0,
    rightAngleSize: 1.5,
    bodyPt: 11.3,
  );

  static const _all = {'csat-2026.1': csat2026};

  static const latest = csat2026;

  static FigureStyle byName(String? name) {
    if (name == null) return latest;
    final style = _all[name];
    if (style == null) throw ArgumentError('모르는 그림체 규격입니다: $name');
    return style;
  }
}
