class BehaviorCardDragPayload {
  final String cardId;
  final String name;
  final int repeatDays;
  final bool isIrregular;
  final List<String> levelContents;
  final int dragStartLevelIndex;
  final String dragStartLevelText;

  const BehaviorCardDragPayload({
    required this.cardId,
    required this.name,
    required this.repeatDays,
    required this.isIrregular,
    required this.levelContents,
    required this.dragStartLevelIndex,
    required this.dragStartLevelText,
  });
}
