// 코드 조사 연동(Think ↔ Cursor) 모델. 설계: docs/architecture/ai-code-bridge.md

enum ThinkCodeStatus {
  draft('draft', '초안'),
  queued('queued', '대기'),
  running('running', '조사 중'),
  followupQueued('followup_queued', '추가 질문 대기'),
  ready('ready', '결과 도착'),
  needsReview('needs_review', '확인 필요'),
  failed('failed', '실패'),
  cancelled('cancelled', '취소됨'),
  applyQueued('apply_queued', '적용 대기'),
  applying('applying', '적용 중'),
  applied('applied', '적용됨'),
  applyFailed('apply_failed', '적용 실패'),
  revertQueued('revert_queued', '되돌리기 대기'),
  reverting('reverting', '되돌리는 중'),
  reverted('reverted', '되돌림'),
  revertFailed('revert_failed', '되돌리기 실패');

  const ThinkCodeStatus(this.db, this.label);
  final String db;
  final String label;

  static ThinkCodeStatus parse(String? raw) =>
      values.firstWhere((s) => s.db == raw, orElse: () => ThinkCodeStatus.draft);

  bool get inProgress =>
      this == queued ||
      this == running ||
      this == followupQueued ||
      this == applyQueued ||
      this == applying ||
      this == revertQueued ||
      this == reverting;

  /// 작업자가 Cursor를 돌리는 단계(조사·수정). 적용·되돌리기는 뺀다.
  bool get cursorRunning => this == queued || this == running || this == followupQueued;
  bool get finished =>
      this == ready ||
      this == needsReview ||
      this == failed ||
      this == cancelled ||
      this == applied ||
      this == applyFailed ||
      this == reverted ||
      this == revertFailed;
  bool get decidable => this == ready || this == needsReview;
  bool get deletable => this == draft || finished;

  /// 수정 모드에서 작업 폴더에 적용할 수 있는 상태.
  bool get appliable => this == ready || this == applyFailed;
  bool get revertable => this == applied || this == revertFailed;
}

enum ThinkCodeMode {
  investigate('investigate', '조사'),
  change('change', '수정'),

  /// Think의 계획을 Cursor가 코드에 비춰 검토한다(읽기 전용, 최대 3회). 끝나면 조율본이 승인 카드로 올라온다.
  plan('plan', '조율');

  const ThinkCodeMode(this.db, this.label);
  final String db;
  final String label;

  static ThinkCodeMode parse(String? raw) =>
      values.firstWhere((m) => m.db == raw, orElse: () => ThinkCodeMode.investigate);
}

/// Think가 조사 결과를 읽고 대화에 답을 다는 단계.
enum ThinkReviewStatus {
  pending('pending'),
  done('done'),
  skipped('skipped'),
  error('error');

  const ThinkReviewStatus(this.db);
  final String db;

  static ThinkReviewStatus? parse(String? raw) {
    for (final s in values) {
      if (s.db == raw) return s;
    }
    return null;
  }
}

enum ThinkCodeOutcome {
  adopted('adopted', '채택'),
  rejected('rejected', '반려'),
  deferred('deferred', '보류');

  const ThinkCodeOutcome(this.db, this.label);
  final String db;
  final String label;

  static ThinkCodeOutcome? parse(String? raw) {
    for (final o in values) {
      if (o.db == raw) return o;
    }
    return null;
  }
}

const Map<String, String> kThinkFeasibilityLabels = {
  'possible': '지금 구조로 가능',
  'possible_with_changes': '구조를 조금 바꾸면 가능',
  'not_recommended': '권하지 않음',
  'unclear': '판단 보류',
};

const Map<String, String> kThinkRiskLabels = {'low': '낮음', 'medium': '보통', 'high': '높음'};

DateTime? _date(dynamic v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

String _str(dynamic v) => v == null ? '' : v.toString().trim();

int _int(dynamic v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

List<String> _strList(dynamic v) =>
    v is List ? v.map((e) => e?.toString().trim() ?? '').where((e) => e.isNotEmpty).toList() : const <String>[];

List<Map<String, dynamic>> _maps(dynamic v) =>
    v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];

/// 요청 내용. DB의 `ai_code_requests.request` jsonb와 같은 모양이다.
class ThinkCodeSpec {
  const ThinkCodeSpec({
    required this.goal,
    this.background = '',
    this.questions = const [],
    this.focusPaths = const [],
    this.constraints = const [],
    this.doNot = const [],
    this.instructions = const [],
  });

  final String goal;

  /// 요청이 나온 Think 대화의 맥락(답변 일부 등). 비어 있어도 된다.
  final String background;
  final List<String> questions;
  final List<String> focusPaths;
  final List<String> constraints;
  final List<String> doNot;

  /// 수정 모드에서 Cursor가 할 일. 조사 모드에서는 비어 있다.
  final List<String> instructions;

  factory ThinkCodeSpec.fromJson(dynamic raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return ThinkCodeSpec(
      goal: _str(j['goal']),
      background: _str(j['background']),
      questions: _strList(j['questions']),
      focusPaths: _strList(j['focus_paths']),
      constraints: _strList(j['constraints']),
      doNot: _strList(j['do_not']),
      instructions: _strList(j['instructions']),
    );
  }

  Map<String, dynamic> toJson() => {
        'goal': goal.trim(),
        'background': background.trim(),
        'questions': questions,
        'focus_paths': focusPaths,
        'constraints': constraints,
        'do_not': doNot,
        if (instructions.isNotEmpty) 'instructions': instructions,
      };

  /// 여러 줄 입력을 목록으로. 빈 줄과 앞쪽 글머리("-", "1.")는 뺀다.
  static List<String> lines(String text) => text
      .split('\n')
      .map((l) => l.trim().replaceFirst(RegExp(r'^(?:[-*•]|\d+[.)])\s*'), '').trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

class ThinkCodeRequest {
  const ThinkCodeRequest({
    required this.id,
    required this.title,
    required this.spec,
    required this.status,
    required this.createdAt,
    this.conversationId,
    this.sourceMessageIds = const [],
    this.round = 0,
    this.maxRounds = 2,
    this.attempts = 0,
    this.lastError,
    this.outcome,
    this.outcomeNote,
    this.decidedAt,
    this.cancelRequested = false,
    this.workerId,
    this.heartbeatAt,
    this.submittedAt,
    this.startedAt,
    this.finishedAt,
    this.mode = ThinkCodeMode.investigate,
    this.reviewStatus,
    this.reviewMessageId,
    this.reviewError,
    this.applyResult = const {},
  });

  final String id;
  final String title;
  final ThinkCodeSpec spec;
  final ThinkCodeStatus status;
  final ThinkCodeMode mode;
  final ThinkReviewStatus? reviewStatus;

  /// Think가 결과를 검토하고 대화에 남긴 답변.
  final String? reviewMessageId;
  final String? reviewError;

  /// 작업자가 적용·되돌리기 뒤 남긴 기록: {apply: {ok, error, conflicts, backup_ref, files}, revert: {...}}
  final Map<String, dynamic> applyResult;
  final DateTime createdAt;
  final String? conversationId;
  final List<String> sourceMessageIds;
  final int round;
  final int maxRounds;
  final int attempts;
  final String? lastError;
  final ThinkCodeOutcome? outcome;
  final String? outcomeNote;
  final DateTime? decidedAt;
  final bool cancelRequested;
  final String? workerId;
  final DateTime? heartbeatAt;
  final DateTime? submittedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  static const String columns =
      'id,title,request,status,conversation_id,source_message_ids,round,max_rounds,attempts,last_error,'
      'outcome,outcome_note,decided_at,cancel_requested,worker_id,heartbeat_at,submitted_at,started_at,'
      'finished_at,created_at,mode,review_status,review_message_id,review_error,apply_result';

  factory ThinkCodeRequest.fromRow(Map<String, dynamic> r) {
    final error = _str(r['last_error']);
    final note = _str(r['outcome_note']);
    final conv = _str(r['conversation_id']);
    final worker = _str(r['worker_id']);
    final reviewMessage = _str(r['review_message_id']);
    final reviewError = _str(r['review_error']);
    return ThinkCodeRequest(
      mode: ThinkCodeMode.parse(r['mode']?.toString()),
      reviewStatus: ThinkReviewStatus.parse(r['review_status']?.toString()),
      reviewMessageId: reviewMessage.isEmpty ? null : reviewMessage,
      reviewError: reviewError.isEmpty ? null : reviewError,
      applyResult: r['apply_result'] is Map ? Map<String, dynamic>.from(r['apply_result'] as Map) : const {},
      id: _str(r['id']),
      title: _str(r['title']),
      spec: ThinkCodeSpec.fromJson(r['request']),
      status: ThinkCodeStatus.parse(r['status']?.toString()),
      createdAt: _date(r['created_at']) ?? DateTime.now(),
      conversationId: conv.isEmpty ? null : conv,
      sourceMessageIds: _strList(r['source_message_ids']),
      round: _int(r['round']),
      maxRounds: r['max_rounds'] == null ? 2 : _int(r['max_rounds']),
      attempts: _int(r['attempts']),
      lastError: error.isEmpty ? null : error,
      outcome: ThinkCodeOutcome.parse(r['outcome']?.toString()),
      outcomeNote: note.isEmpty ? null : note,
      decidedAt: _date(r['decided_at']),
      cancelRequested: r['cancel_requested'] == true,
      workerId: worker.isEmpty ? null : worker,
      heartbeatAt: _date(r['heartbeat_at']),
      submittedAt: _date(r['submitted_at']),
      startedAt: _date(r['started_at']),
      finishedAt: _date(r['finished_at']),
    );
  }

  /// 목록에 보일 상태 문구. 진행 중 취소 요청은 따로 표시한다.
  String get statusLabel {
    if (status == ThinkCodeStatus.running && cancelRequested) return '취소 중';
    if (status == ThinkCodeStatus.running && mode == ThinkCodeMode.change) return '수정 중';
    if (status == ThinkCodeStatus.running && mode == ThinkCodeMode.plan) return '조율 중';
    if (status == ThinkCodeStatus.followupQueued && mode == ThinkCodeMode.plan) return '다음 회차 대기';
    if (mode == ThinkCodeMode.plan && status == ThinkCodeStatus.ready && reviewStatus == ThinkReviewStatus.pending) {
      return '조율본 작성 중';
    }
    return status.label;
  }

  /// 서버 ai_code_request_cancel이 받는 상태.
  bool get cancellable =>
      !cancelRequested &&
      (status.cursorRunning || status == ThinkCodeStatus.applyQueued || status == ThinkCodeStatus.revertQueued);

  ThinkApplyOutcome? get lastApply => ThinkApplyOutcome.fromJson(applyResult['apply']);
  ThinkApplyOutcome? get lastRevert => ThinkApplyOutcome.fromJson(applyResult['revert']);
}

/// 작업 폴더에 diff를 적용하거나 되돌린 결과.
class ThinkApplyOutcome {
  const ThinkApplyOutcome({required this.ok, this.error, this.conflicts = const [], this.backupRef, this.files = 0});

  final bool ok;
  final String? error;
  final List<String> conflicts;

  /// 적용 직전 작업 폴더 스냅샷(git ref). 되돌리기가 어긋나면 이걸로 직접 복구한다.
  final String? backupRef;
  final int files;

  static ThinkApplyOutcome? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final error = _str(j['error']);
    final ref = _str(j['backup_ref']);
    return ThinkApplyOutcome(
      ok: j['ok'] == true,
      error: error.isEmpty ? null : error,
      conflicts: _strList(j['conflicts']),
      backupRef: ref.isEmpty ? null : ref,
      files: _int(j['files']),
    );
  }
}

class ThinkCodeEvidence {
  const ThinkCodeEvidence(this.path, this.lines);
  final String path;
  final String lines;

  String get label => lines.isEmpty ? path : '$path:$lines';
}

class ThinkCodeFinding {
  const ThinkCodeFinding(this.point, this.evidence);
  final String point;
  final List<ThinkCodeEvidence> evidence;
}

class ThinkCodeProposal {
  const ThinkCodeProposal({required this.title, required this.change, required this.files, required this.risk});
  final String title;
  final String change;
  final List<String> files;
  final String risk;
}

/// Cursor 답변 끝의 JSON을 작업자가 정리한 결과. 형식이 안 맞으면 null이고 원문만 있다.
class ThinkCodeResult {
  const ThinkCodeResult({
    required this.summary,
    required this.feasibility,
    this.answers = const [],
    this.findings = const [],
    this.proposals = const [],
    this.risks = const [],
    this.questionsForThink = const [],
    this.changes = const [],
    this.checks = const [],
    this.issues = const [],
    this.suggestedSteps = const [],
    this.questionsForOwner = const [],
  });

  final String summary;
  final String feasibility;
  final List<({String question, String answer})> answers;
  final List<ThinkCodeFinding> findings;
  final List<ThinkCodeProposal> proposals;
  final List<String> risks;
  final List<String> questionsForThink;

  /// 수정 모드: Cursor가 설명한 파일별 변경과 적용 뒤 돌려 볼 검사.
  final List<({String path, String what})> changes;
  final List<String> checks;

  /// 조율 모드: 계획 초안의 문제점, Cursor가 고쳐 쓴 단계, 운영자에게 물을 것.
  final List<({String step, String problem, String suggestion})> issues;
  final List<String> suggestedSteps;
  final List<String> questionsForOwner;

  static ThinkCodeResult? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final summary = _str(j['summary']);
    if (summary.isEmpty) return null;
    return ThinkCodeResult(
      summary: summary,
      feasibility: kThinkFeasibilityLabels.containsKey(_str(j['feasibility'])) ? _str(j['feasibility']) : 'unclear',
      answers: [
        for (final a in _maps(j['answers']))
          if (_str(a['answer']).isNotEmpty) (question: _str(a['question']), answer: _str(a['answer'])),
      ],
      findings: [
        for (final f in _maps(j['findings']))
          if (_str(f['point']).isNotEmpty)
            ThinkCodeFinding(_str(f['point']), [
              for (final e in _maps(f['evidence']))
                if (_str(e['path']).isNotEmpty) ThinkCodeEvidence(_str(e['path']), _str(e['lines'])),
            ]),
      ],
      proposals: [
        for (final p in _maps(j['proposals']))
          if (_str(p['title']).isNotEmpty || _str(p['change']).isNotEmpty)
            ThinkCodeProposal(
              title: _str(p['title']),
              change: _str(p['change']),
              files: _strList(p['files']),
              risk: kThinkRiskLabels.containsKey(_str(p['risk'])) ? _str(p['risk']) : 'medium',
            ),
      ],
      risks: _strList(j['risks']),
      questionsForThink: _strList(j['questions_for_think']),
      changes: [
        for (final c in _maps(j['changes']))
          if (_str(c['path']).isNotEmpty || _str(c['what']).isNotEmpty) (path: _str(c['path']), what: _str(c['what'])),
      ],
      checks: _strList(j['checks']),
      issues: [
        for (final i in _maps(j['issues']))
          if (_str(i['problem']).isNotEmpty)
            (step: _str(i['step']), problem: _str(i['problem']), suggestion: _str(i['suggestion'])),
      ],
      suggestedSteps: _strList(j['suggested_steps']),
      questionsForOwner: _strList(j['questions_for_owner']),
    );
  }
}

class ThinkDiffFileStat {
  const ThinkDiffFileStat(this.path, this.additions, this.deletions);
  final String path;

  /// 바이너리 파일이면 -1.
  final int additions;
  final int deletions;

  bool get binary => additions < 0 || deletions < 0;
}

class ThinkDiffStats {
  const ThinkDiffStats({required this.files, required this.additions, required this.deletions, this.list = const []});
  final int files;
  final int additions;
  final int deletions;
  final List<ThinkDiffFileStat> list;

  static ThinkDiffStats? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    return ThinkDiffStats(
      files: _int(j['files']),
      additions: _int(j['additions']),
      deletions: _int(j['deletions']),
      list: [
        for (final f in _maps(j['list']))
          if (_str(f['path']).isNotEmpty)
            ThinkDiffFileStat(_str(f['path']), _int(f['additions']), _int(f['deletions'])),
      ],
    );
  }
}

/// git diff 한 파일 분량. [path]는 새 경로(삭제면 옛 경로).
class ThinkDiffFile {
  const ThinkDiffFile({required this.path, required this.lines, this.oldPath, this.binary = false});
  final String path;
  final String? oldPath;
  final List<String> lines;
  final bool binary;

  int get additions => lines.where((l) => l.startsWith('+') && !l.startsWith('+++')).length;
  int get deletions => lines.where((l) => l.startsWith('-') && !l.startsWith('---')).length;
}

/// `git diff --binary` 결과를 파일별로 나눈다. 머리줄(diff --git, index, ---, +++)은 [ThinkDiffFile.lines]에서 뺀다.
List<ThinkDiffFile> parseThinkDiff(String diff) {
  final out = <ThinkDiffFile>[];
  String? path;
  String? oldPath;
  var binary = false;
  var lines = <String>[];
  var inHunk = false;
  void flush() {
    final p = path;
    if (p != null) out.add(ThinkDiffFile(path: p, oldPath: oldPath, lines: lines, binary: binary));
  }

  final header = RegExp(r'^diff --git "?a/(.+?)"? "?b/(.+?)"?$');
  for (final line in diff.split('\n')) {
    final m = header.firstMatch(line);
    if (m != null) {
      flush();
      oldPath = m.group(1);
      path = m.group(2);
      if (oldPath == path) oldPath = null;
      binary = false;
      lines = [];
      inHunk = false;
      continue;
    }
    if (path == null) continue;
    if (!inHunk) {
      if (line.startsWith('GIT binary patch') || line.startsWith('Binary files')) {
        binary = true;
      } else if (line.startsWith('@@')) {
        inHunk = true;
        lines.add(line);
      }
      continue;
    }
    if (binary) continue;
    lines.add(line);
  }
  flush();
  for (var i = 0; i < out.length; i++) {
    final f = out[i];
    if (f.lines.isNotEmpty && f.lines.last.isEmpty) {
      out[i] = ThinkDiffFile(
          path: f.path, oldPath: f.oldPath, lines: f.lines.sublist(0, f.lines.length - 1), binary: f.binary);
    }
  }
  return out;
}

class ThinkCodeRound {
  const ThinkCodeRound({
    required this.round,
    required this.status,
    this.resultText,
    this.result,
    this.parseOk = false,
    this.model,
    this.durationMs,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.toolCalls = const [],
    this.repoHead,
    this.repoBranch,
    this.repoDirtyFiles,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.diff,
    this.diffStats,
    this.thinkQuestions = const [],
  });

  final int round;
  final String status;

  /// 2회차부터: 이 회차를 시작하며 Think가 Cursor에게 보낸 질문·반론.
  final List<String> thinkQuestions;
  final String? resultText;
  final ThinkCodeResult? result;

  /// 수정 모드: 격리 작업 폴더에서 만든 변경(git diff). 적용 전에 사람이 확인한다.
  final String? diff;
  final ThinkDiffStats? diffStats;
  final bool parseOk;
  final String? model;
  final int? durationMs;
  final int inputTokens;
  final int outputTokens;
  final List<({String name, int count})> toolCalls;
  final String? repoHead;
  final String? repoBranch;
  final int? repoDirtyFiles;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  static const String columns =
      'round,status,result_text,result,parse_ok,model,duration_ms,usage,tool_calls,repo_state,error,started_at,finished_at,'
      'think_questions';

  factory ThinkCodeRound.fromRow(Map<String, dynamic> r) {
    final usage = r['usage'] is Map ? Map<String, dynamic>.from(r['usage'] as Map) : const <String, dynamic>{};
    final repo = r['repo_state'] is Map ? Map<String, dynamic>.from(r['repo_state'] as Map) : const <String, dynamic>{};
    final text = _str(r['result_text']);
    final model = _str(r['model']);
    final error = _str(r['error']);
    final raw = r['result'] is Map ? Map<String, dynamic>.from(r['result'] as Map) : const <String, dynamic>{};
    final diff = raw['diff'] is String ? raw['diff'] as String : '';
    return ThinkCodeRound(
      diff: diff.isEmpty ? null : diff,
      diffStats: ThinkDiffStats.fromJson(raw['diff_stats']),
      thinkQuestions: _strList(r['think_questions']),
      round: _int(r['round']),
      status: _str(r['status']),
      resultText: text.isEmpty ? null : text,
      result: ThinkCodeResult.fromJson(r['result']),
      parseOk: r['parse_ok'] == true,
      model: model.isEmpty ? null : model,
      durationMs: r['duration_ms'] == null ? null : _int(r['duration_ms']),
      inputTokens: _int(usage['inputTokens']) + _int(usage['cacheReadTokens']),
      outputTokens: _int(usage['outputTokens']),
      toolCalls: [for (final t in _maps(r['tool_calls'])) (name: _str(t['name']), count: _int(t['count']))],
      repoHead: _str(repo['head']).isEmpty ? null : _str(repo['head']),
      repoBranch: _str(repo['branch']).isEmpty ? null : _str(repo['branch']),
      repoDirtyFiles: repo['dirty_files'] == null ? null : _int(repo['dirty_files']),
      error: error.isEmpty ? null : error,
      startedAt: _date(r['started_at']),
      finishedAt: _date(r['finished_at']),
    );
  }
}

class ThinkPlanOption {
  const ThinkPlanOption({required this.id, required this.label, this.detail = '', this.recommended = false});
  final String id;
  final String label;

  /// 고르면 무엇이 달라지는지, 장단점, 영향 범위.
  final String detail;
  final bool recommended;
}

/// 조율로 풀리지 않아 운영자가 고를 객관식 질문(조율본 spec.decisions). 추천 보기가 있으면 맨 앞이다.
class ThinkPlanDecision {
  const ThinkPlanDecision({
    required this.id,
    required this.question,
    required this.options,
    this.context = '',
    this.disagreement = false,
  });

  final String id;
  final String question;
  final String context;

  /// Think와 Cursor 의견이 끝까지 갈린 점. 아니면 운영자만 정할 수 있는 것.
  final bool disagreement;
  final List<ThinkPlanOption> options;

  static List<ThinkPlanDecision> listFrom(dynamic raw) => [
        for (final d in _maps(raw))
          if (_str(d['id']).isNotEmpty && _str(d['question']).isNotEmpty)
            ThinkPlanDecision(
              id: _str(d['id']),
              question: _str(d['question']),
              context: _str(d['context']),
              disagreement: d['kind'] == 'disagreement',
              options: [
                for (final o in _maps(d['options']))
                  if (_str(o['id']).isNotEmpty && _str(o['label']).isNotEmpty)
                    ThinkPlanOption(
                      id: _str(o['id']),
                      label: _str(o['label']),
                      detail: _str(o['detail']),
                      recommended: o['recommended'] == true,
                    ),
              ],
            ),
      ];
}

class ThinkCodeWorker {
  const ThinkCodeWorker(
      {required this.workerId, required this.lastSeenAt, this.model, this.version, this.currentRequestId});

  final String workerId;
  final DateTime lastSeenAt;
  final String? model;
  final String? version;
  final String? currentRequestId;

  /// 작업자는 10초마다 대기열을 확인하고 30초마다 진행 신호를 보낸다. 2분 넘게 소식이 없으면 꺼진 것으로 본다.
  static const Duration offlineAfter = Duration(minutes: 2);

  bool onlineAt(DateTime now) => now.difference(lastSeenAt) < offlineAfter;

  factory ThinkCodeWorker.fromRow(Map<String, dynamic> r) {
    final model = _str(r['model']);
    final version = _str(r['version']);
    final current = _str(r['current_request_id']);
    return ThinkCodeWorker(
      workerId: _str(r['worker_id']),
      lastSeenAt: _date(r['last_seen_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      model: model.isEmpty ? null : model,
      version: version.isEmpty ? null : version,
      currentRequestId: current.isEmpty ? null : current,
    );
  }
}

/// 오늘(한국 시간) 보낸 요청 수. 서버 한도(`ai_code_request_submit`)와 같은 기준이다.
int thinkCodeSubmittedToday(Iterable<ThinkCodeRequest> requests, DateTime now) {
  final kst = now.toUtc().add(const Duration(hours: 9));
  final startUtc = DateTime.utc(kst.year, kst.month, kst.day).subtract(const Duration(hours: 9));
  return requests.where((r) => r.submittedAt != null && !r.submittedAt!.toUtc().isBefore(startUtc)).length;
}
