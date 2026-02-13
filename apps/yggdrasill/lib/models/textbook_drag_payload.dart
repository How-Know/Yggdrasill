class TextbookDragPayload {
  final String bookId;
  final String bookName;
  final String gradeLabel;

  const TextbookDragPayload({
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
  });

  TextbookDragPayload copyWith({
    String? bookId,
    String? bookName,
    String? gradeLabel,
  }) {
    return TextbookDragPayload(
      bookId: bookId ?? this.bookId,
      bookName: bookName ?? this.bookName,
      gradeLabel: gradeLabel ?? this.gradeLabel,
    );
  }
}
