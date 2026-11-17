/// 학생앱 "교재 풀기" 탭의 자습(바로풀기/정답입력하기) 진행 상태.
///
/// 학습앱이 `learning_sessions` 를 실시간 구독해 과제카드(`homework_items`)와
/// 섞지 않고도 학생의 자유풀이중·중단·정답입력중 상태를 표시하기 위해 쓴다.
class StudentTextbookStudyState {
  const StudentTextbookStudyState({
    required this.sessionId,
    required this.studentId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.entryMode,
    required this.status,
    required this.locationKind,
    required this.startedAt,
    this.lastResumedAt,
    this.pausedAt,
    this.lastBeatAt,
    this.elapsedSec = 0,
    this.interruptedSec = 0,
    required this.updatedAt,
  });

  static const Duration staleAfter = Duration(hours: 3);

  final String sessionId;
  final String studentId;
  final String bookId;
  final String bookName;
  final String gradeLabel;

  /// `'solve'` (바로풀기) | `'answer_entry'` (정답입력하기)
  final String entryMode;

  /// `'open'` | `'paused'`
  final String status;

  /// `'academy'` | `'home'` | ...
  final String locationKind;

  final DateTime startedAt;
  final DateTime? lastResumedAt;
  final DateTime? pausedAt;
  final DateTime? lastBeatAt;
  final int elapsedSec;
  final int interruptedSec;
  final DateTime updatedAt;

  bool get isSolve => entryMode == 'solve';
  bool get isAnswerEntry => entryMode == 'answer_entry';
  bool get isOpen => status == 'open';
  bool get isPaused => status == 'paused';

  DateTime get _lastActivityUtc =>
      (lastBeatAt ?? lastResumedAt ?? startedAt).toUtc();

  /// 박동이 3시간 넘게 끊긴 열린 세션은 오래된 잔여 세션으로 간주한다.
  bool get isFreshOpen =>
      isOpen && DateTime.now().toUtc().difference(_lastActivityUtc) < staleAfter;

  bool get isVisibleInHome {
    if (isSolve) return isPaused || isFreshOpen;
    if (isAnswerEntry) return isFreshOpen;
    return false;
  }

  String get statusLabel {
    if (isSolve && isOpen) return '자유풀이중';
    if (isSolve && isPaused) return '자유풀이 중단';
    if (isAnswerEntry && isOpen) return '정답입력중';
    return '';
  }

  String get locationLabel => switch (locationKind) {
        'academy' => '학원',
        'home' => '집',
        _ => '',
      };

  int get activeElapsedSec {
    if (!isSolve) return 0;
    if (!isOpen) return elapsedSec;
    final base = (lastResumedAt ?? startedAt).toUtc();
    final extra = DateTime.now().toUtc().difference(base).inSeconds;
    return elapsedSec + (extra > 0 ? extra : 0);
  }

  static StudentTextbookStudyState? fromRow(Map<String, dynamic> row) {
    final sessionId = '${row['id'] ?? ''}'.trim();
    final studentId = '${row['student_id'] ?? ''}'.trim();
    final bookId = '${row['book_id'] ?? ''}'.trim();
    final entryMode = '${row['entry_mode'] ?? ''}'.trim().toLowerCase();
    final status = '${row['status'] ?? ''}'.trim().toLowerCase();
    final startedAt = DateTime.tryParse('${row['started_at'] ?? ''}')?.toLocal();
    final updatedAt = DateTime.tryParse('${row['updated_at'] ?? ''}')?.toLocal();
    if (sessionId.isEmpty ||
        studentId.isEmpty ||
        bookId.isEmpty ||
        (entryMode != 'solve' && entryMode != 'answer_entry') ||
        (status != 'open' && status != 'paused') ||
        startedAt == null) {
      return null;
    }
    final rawBook = row['resource_files'];
    var bookName = '';
    if (rawBook is Map) {
      bookName = '${rawBook['name'] ?? ''}'.trim();
    }
    return StudentTextbookStudyState(
      sessionId: sessionId,
      studentId: studentId,
      bookId: bookId,
      bookName: bookName,
      gradeLabel: '${row['grade_label'] ?? ''}'.trim(),
      entryMode: entryMode,
      status: status,
      locationKind: '${row['location_kind'] ?? 'unknown'}'.trim().toLowerCase(),
      startedAt: startedAt,
      lastResumedAt:
          DateTime.tryParse('${row['last_resumed_at'] ?? ''}')?.toLocal(),
      pausedAt: DateTime.tryParse('${row['paused_at'] ?? ''}')?.toLocal(),
      lastBeatAt:
          DateTime.tryParse('${row['last_beat_at'] ?? ''}')?.toLocal(),
      elapsedSec: (row['elapsed_sec'] as num?)?.toInt() ?? 0,
      interruptedSec: (row['interrupted_sec'] as num?)?.toInt() ?? 0,
      updatedAt: updatedAt ?? startedAt,
    );
  }
}
