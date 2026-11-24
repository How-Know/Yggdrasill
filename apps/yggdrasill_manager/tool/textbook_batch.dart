// 수력충전 1-1·1-2 운영 스크립트: 새 흐름으로 확정한 소단원에 코드 정합성 점검과 메타 보충을 돌리고 다시 확정한다.
// 매니저앱 서비스를 그대로 써서 앱과 같은 경로·기준(준비됨 판정, 확정 직전 정합성 점검, 일괄 반영)으로 돈다.
// 화면 없이 돌리려고 flutter test 로 실행한다. 로그인은 `tool/textbook_batch.ps1 login`(메일 인증번호).
//
//   flutter test tool/textbook_batch.dart -r expanded --dart-define=BATCH_STEP=<단계> [--dart-define=BATCH_ONLY=1-1/0-0,1-2/0-1/W5]
// BATCH_ONLY 는 중단원(학년/대-중) 또는 소단원(학년/대-중/작업 키)을 쉼표로 고른다.
// BATCH_OPEN=true 면 크롭을 확정해 작업 지시가 있지만 아직 확정하지 않은 소단원도 고른다.
//
// 단계
//   send_otp, verify_otp  로그인(BATCH_EMAIL 필수, BATCH_OTP). 세션은 저장소 밖 %LOCALAPPDATA%\Yggdrasill 에 둔다.
//   status       소단원별 준비됨 수와 막힌 이유
//   preview      정합성 점검 미리보기(아무것도 쓰지 않는다)
//   consistency  정합성 점검(수정안·지적을 저장)
//   meta         정합성 점검 + 메타 보충(AI). 앱의 "메타 보충"과 같다
//   dismiss      사장님이 "문제 없음"으로 정한 문항(BATCH_CROPS, 크롭 id 쉼표 구분)의 정합성 지적을 닫는다
//   render       V2 렌더 이상이 남은 문항과 BATCH_CROPS 문항을 다시 검수한다(작업 화면의 "V2 렌더 검수 다시"). 교재 원본을
//                찍으려고 매니저앱 Windows 빌드 폴더의 pdfium 을 쓴다(그 폴더를 PATH 에 넣고 실행한다).
//                BATCH_VALUE=unchecked 면 렌더 검수 기록이 비어 있는 문항(검수 뒤 내용이 바뀐 문항)과
//                교재 원본과 대조하지 않고 검수된 문항도 고른다
//   finish       V2 렌더 이상이 남은 문항과 BATCH_CROPS 문항에만 작업 화면의 "이어서 마무리"와 같은 검수를 돌린다
//                (원본 대조 수정안 → V2 재렌더·원본 재대조 최대 2회 → 정합성 점검 → 메타 보충, AI).
//                BATCH_VALUE=rerun 이면 AI 풀이·해설 전사·품질 검수부터 다시 한다(해설 위치를 고친 뒤)
//   page         BATCH_VALUE=종류:쪽(sol:32) 한 쪽 전체를 PNG 로 남긴다(쓰기 없음)
//   solref       해설 위치를 사람이 고친 값으로 저장한다. BATCH_VALUE 한 줄: crop id|쪽|번호 영역|본문 영역(위,왼,아래,오)
//   solfig       BATCH_CROPS 문항의 해설 그림을 지금 해설 위치에서 다시 찾고 V2 렌더를 다시 대조한다(AI)
//   solfig_arrange BATCH_CROPS 문항의 해설 그림 정렬·가로 묶음을 원본 자리에서 다시 계산하고 V2 렌더를 다시 대조한다.
//                BATCH_VALUE 가 있으면 {"<crop id>": {"<그림 순번 0부터>": {"placement": "left"}}} 값을 먼저 덮어쓴다
//   solfig_width BATCH_CROPS 문항의 해설 그림 폭만 지금 규칙으로 다시 계산하고(AI·다시 자르기 없음) 바뀐 문항의 V2 렌더를 다시 대조한다.
//                예전 계산값 그대로인 폭만 바꾼다(렌더 검수가 맞춘 폭 등은 둔다)
//   solfig_recrop BATCH_CROPS 문항 하나의 해설 그림 하나를 해설 PDF 같은 쪽에서 다시 자르고 V2 렌더를 다시 대조한다.
//                BATCH_VALUE=그림 순번(0부터)|위,왼,아래,오(해설 쪽 0~1000)
//   solfig_drop  BATCH_CROPS 문항 하나의 해설 그림 하나(BATCH_VALUE=순번, 0부터)를 빼고 V2 렌더를 다시 대조한다
//   snapshot     BATCH_CROPS 문항의 V2 문항 카드·정답 해설 카드·교재 원본을 build/textbook_batch/snap 에 PNG 로 남긴다(쓰기 없음).
//                BATCH_VALUE 가 있으면 그 줄마다 그 정답으로 정답 카드를 더 찍는다(정답 표기 비교)
// 사장님이 승인한 문항 하나(BATCH_CROPS)를 고치는 단계. 값은 BATCH_VALUE(`@경로`면 그 UTF-8 파일 내용)
//   answer          정답을 사장님 수정으로 반영 대기에 넣는다(작업 화면의 정답 저장과 같다)
//   stem            본문을 사장님 수정으로 반영 대기에 넣는다(작업 화면의 본문 저장과 같다)
//   solution        원본 해설 전사본을 사장님 수정으로 반영 대기에 넣는다
//   layout          그림 배치(figure_layout JSON)를 사장님 수정으로 반영 대기에 넣는다
//   recrop          그림 1을 원본에서 다시 잘라 반영 대기에 넣는다. 값은 snapshot 의 _original.png 기준 위,왼쪽,아래,오른쪽(0~1000).
//                   자른 영역의 빈칸도 원본 모양이라 엔진이 흰 여백을 자르지 않게 keep_margins 를 붙인다
//   pb_figure_width 문제은행의 그림 1 폭(em)을 바로 고친다(문제은행 화면의 그림 크기 편집과 같다, 확정을 거치지 않는다)
//   pb_choice_rows  문제은행의 그림 선지 줄 수(2: ①②③/④⑤, 3: ①②/③④/⑤)를 바로 고친다(문제은행 화면의 선지 배치와 같다)
//   reconfirm    모든 카드가 준비됨인 소단원을 다시 확정(수정안 일괄 반영)
// 모의고사(교재 메뉴 > 모의고사). BATCH_VALUE=회차 id(쉼표 구분)
//   mock         매니저앱의 "검수 시작"과 같은 서비스·실행기로 회차의 구간들을 돌린다: 구간 문서·작업 지시 →
//                (아직 뽑지 않았으면) 추출 → 문항·정답·해설 위치 준비 → AI 검수 → 준비됨 판정. 멈췄거나 실패한 구간은
//                그 단계부터 잇는다. 확정은 하지 않는다. 끝나면 mock_status 와 같은 표를 남긴다
//   mock_continue 확정하지 않은 구간을 AI 검수 단계부터 다시 돌린다(엔진·데이터를 고친 뒤: 손볼 문항만 다시 검수한다)
//   mock_restart 확정하지 않은 구간을 처음부터 다시 검수한다: AI 가 쌓은 반영 대기 값을 버리고(사람이 고친 값은 둔다)
//                준비 단계부터 모든 문항을 다시 풀고 해설을 다시 옮긴다. 추출은 다시 하지 않는다
//                mock_continue·mock_restart 는 BATCH_ONLY=구간(common,probstats,calculus,geometry 쉼표 구분)으로 구간을 고를 수 있다
//   mock_stem    BATCH_CROPS 문항 하나의 본문(BATCH_VALUE=@경로)을 사장님 수정으로 반영 대기에 넣는다(검수는 돌리지 않는다)
//   mock_engine_recheck 확정하지 않은 구간의 "코드 수정 필요"(렌더 엔진 보류) 문항만 V2 로 다시 찍어 원본과 대조한다
//                (앱의 "코드 수정 후 재확인"과 같다. 렌더 엔진을 고친 뒤)
//   mock_status  회차의 구간별 준비됨 수와 막힌 이유, 반영 대기 값(쓰기 없음). BATCH_VALUE 가 없으면 검수 중인 모든 회차.
//                준비됨이 아닌 문항은 막힌 이유와 카드 오류·렌더·문항·정답·해설 오류 지적을 한 줄씩 찍는다
//   mock_unstage BATCH_CROPS 문항의 AI 반영 대기 값(BATCH_VALUE=필드 쉼표 구분, 예: solution_transcribed)을 버린다.
//                사람이 고친 값은 그대로다. 저장된 값(해설 전사 단계가 옮긴 해설 등)이 다시 쓰인다
//   mock_prepare 검수는 돌리지 않고 구간 준비만 다시 한다(BATCH_VALUE=회차 id, BATCH_ONLY=구간). 해설 위치가 게이트웨이
//                계산값과 달라진 문항만 계산값으로 다시 쓴다(사람이 고친 위치는 둔다). 옮긴 해설은 다시 옮기지 않는다
//   mock_slot_check 가형·나형에 같이 실린 문항을 합친 회차(BATCH_VALUE=회차 id)에서, 다른 구간의 문항을 가리키는 자리마다
//                그 시험지 원본(_original.png)과 자리 값으로 찍은 카드(_slot_card.png)를 build/textbook_batch/slot 에 둔다(쓰기 없음)
//   mock_solref_preview 해설 위치를 지금 규칙으로 다시 계산해 달라지는 문항만 적는다(BATCH_VALUE=회차 id, BATCH_ONLY=구간).
//                아무것도 쓰지 않으므로 확정된 구간도 본다
//   logout       세션 폐기
// 결과는 build/textbook_batch/ 에 JSON 으로 남는다.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yggdrasill_manager/services/mock_exam_review_service.dart';
import 'package:yggdrasill_manager/services/problem_bank_service.dart';
import 'package:yggdrasill_manager/services/textbook_book_registry.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_review_pipeline.dart';
import 'package:yggdrasill_manager/services/textbook_review_solution_image_service.dart';
import 'package:yggdrasill_manager/services/textbook_stage_batch_service.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_solution_ref_service.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_runner.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_service.dart';

const _step = String.fromEnvironment('BATCH_STEP');
const _only = String.fromEnvironment('BATCH_ONLY');
const _email = String.fromEnvironment('BATCH_EMAIL');
const _otp = String.fromEnvironment('BATCH_OTP');
const _crops = String.fromEnvironment('BATCH_CROPS');
const _open = bool.fromEnvironment('BATCH_OPEN');
const _value = String.fromEnvironment('BATCH_VALUE');

/// 한글 값은 명령줄을 거치며 깨질 수 있어 `@경로`(UTF-8 파일)로도 받는다.
String get _valueText {
  final v = _value.trim();
  return v.startsWith('@') ? File(v.substring(1)).readAsStringSync().trim() : v;
}

const _academyId = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
// 다른 교재·시험지는 BATCH_BOOK(교재 id)과 BATCH_GRADES(학년 쉼표 구분)로 고른다.
const _bookId = String.fromEnvironment('BATCH_BOOK', defaultValue: '09d8c890-a69f-4814-b57d-e16b0bf88432');
const _gradesText = String.fromEnvironment('BATCH_GRADES', defaultValue: '1-1,1-2');
final _grades = [for (final g in _gradesText.split(',')) if (g.trim().isNotEmpty) g.trim()];

void main() {
  test('textbook batch $_step', () async {
    final env = jsonDecode(File('env.local.json').readAsStringSync()) as Map<String, dynamic>;
    // 메일 인증번호를 직접 확인하므로 PKCE(확인용 값을 저장소에 둠)가 필요 없다. 이 연결에는 저장소가 없다.
    final db = SupabaseClient(
      '${env['SUPABASE_URL']}',
      '${env['SUPABASE_ANON_KEY']}',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    final email = _email.trim();
    try {
      switch (_step) {
        case 'send_otp':
          if (email.isEmpty) fail('BATCH_EMAIL 이 비어 있습니다.');
          await db.auth.signInWithOtp(email: email, shouldCreateUser: false);
          print('인증번호를 $email 로 보냈습니다.');
          return;
        case 'verify_otp':
          if (email.isEmpty || _otp.trim().isEmpty) fail('BATCH_EMAIL 또는 BATCH_OTP 가 비어 있습니다.');
          final res = await db.auth.verifyOTP(email: email, token: _otp.trim(), type: OtpType.email);
          _saveSession(res.session);
          print('로그인했습니다: ${res.user?.email}');
          return;
        case 'logout':
          if (await _restoreSession(db)) await db.auth.signOut();
          if (_sessionFile.existsSync()) _sessionFile.deleteSync();
          print('세션을 폐기했습니다.');
          return;
      }
      if (!await _restoreSession(db)) fail('로그인 세션이 없습니다. tool/textbook_batch.ps1 login 을 먼저 실행하세요.');
      print('로그인: ${db.auth.currentUser?.email}');
      try {
        await _Batch(db).run(_step);
      } finally {
        _saveSession(db.auth.currentSession);
      }
    } finally {
      await db.dispose();
    }
  }, timeout: Timeout.none);
}

File get _sessionFile => File(p.join(
      Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
      'Yggdrasill',
      'textbook_batch_session.json',
    ));

void _saveSession(Session? s) {
  final token = s?.refreshToken ?? '';
  if (token.isEmpty) return;
  _sessionFile.parent.createSync(recursive: true);
  _sessionFile.writeAsStringSync(jsonEncode({'refresh_token': token}));
}

/// 저장한 세션을 되살린다. 갱신 토큰은 쓸 때마다 바뀌므로 새 토큰을 다시 저장한다.
Future<bool> _restoreSession(SupabaseClient db) async {
  if (!_sessionFile.existsSync()) return false;
  final saved = jsonDecode(_sessionFile.readAsStringSync());
  final token = saved is Map ? '${saved['refresh_token'] ?? ''}' : '';
  if (token.isEmpty) return false;
  final res = await db.auth.setSession(token);
  _saveSession(res.session);
  return res.session != null;
}

/// 확정한 소단원이 있는 중단원 하나
class _Mid {
  _Mid(this.key, this.scope, this.workflows);

  /// `학년/대-중` (예: 1-1/0-0)
  final String key;
  final TextbookReviewUnitScope scope;
  final List<TextbookSubunitWorkflow> workflows;
  List<TextbookProblemReviewItem> all = const [];

  List<TextbookProblemReviewItem> itemsOf(TextbookSubunitWorkflow wf) => [
        for (final it in all)
          if (wf.workOrder!.matches(it)) it,
      ];

  Set<String> get targetIds => {
        for (final wf in workflows)
          for (final it in itemsOf(wf)) it.cropId,
      };
}

class _Batch {
  _Batch(this.db) : pb = ProblemBankService(client: db) {
    review = TextbookProblemReviewService(client: db, pbService: pb);
    workflows = TextbookWorkflowService(client: db);
    registry = TextbookBookRegistry(supabase: db);
  }

  final SupabaseClient db;
  final ProblemBankService pb;
  late final TextbookProblemReviewService review;
  late final TextbookWorkflowService workflows;
  late final TextbookBookRegistry registry;
  final Map<String, dynamic> out = {};

  Future<void> run(String step) async {
    // fig_only 는 작업 지시가 없는 교재에도 쓰므로 중단원을 BATCH_ONLY 에서 직접 받는다. 모의고사 단계는 회차 id 로 고른다.
    final mids = step == 'fig_only' || step.startsWith('mock') ? <_Mid>[] : await _loadMids();
    if (!step.startsWith('mock')) {
      print('대상: 중단원 ${mids.length}개 · 확정한 소단원 ${mids.fold<int>(0, (n, m) => n + m.workflows.length)}개');
    }
    switch (step) {
      case 'mock':
        await _mock(run: true);
      case 'mock_continue':
        await _mock(run: true, again: 'continue');
      case 'mock_restart':
        await _mock(run: true, again: 'restart');
      case 'mock_engine_recheck':
        await _mock(run: true, again: 'engine');
      case 'mock_status':
        await _mock(run: false);
      case 'mock_unstage':
        await _mockUnstage();
      case 'mock_stem':
        await _mockStem();
      case 'mock_prepare':
        await _mockPrepare();
      case 'mock_slot_check':
        await _mockSlotCheck();
      case 'mock_solref_preview':
        await _mockSolrefPreview();
      case 'fig_only':
        await _figOnly();
      case 'status':
        await _status(mids);
      case 'preview':
        await _consistency(mids, dryRun: true);
      case 'consistency':
        await _consistency(mids, dryRun: false);
      case 'meta':
        await _meta(mids);
      case 'dismiss':
        await _dismiss(mids);
      case 'render':
        await _render(mids);
      case 'finish':
        await _finish(mids);
      case 'match':
        await _match(mids);
      case 'sol_blocks':
        await _solBlocks(mids);
      case 'snapshot':
        await _snapshot(mids);
      case 'answer':
        await _answer(mids);
      case 'stem':
        await _stem(mids);
      case 'solution':
        await _solution(mids);
      case 'layout':
        await _layout(mids);
      case 'page':
        await _page(mids);
      case 'solref':
        await _solref(mids);
      case 'solfig':
        await _solfig(mids);
      case 'solfig_arrange':
        await _solfigArrange(mids);
      case 'solfig_width':
        await _solfigWidth(mids);
      case 'solfig_recrop':
        await _solfigRecrop(mids);
      case 'solfig_drop':
        await _solfigDrop(mids);
      case 'recrop':
        await _recrop(mids);
      case 'pb_figure_width':
        await _pbFigureWidth(mids);
      case 'fig_drop':
        await _figDrop(mids);
      case 'fig_upload':
        await _figUpload(mids);
      case 'meta_force':
        // BATCH_CROPS 문항 하나의 개념·사고를 이미 골랐어도 다시 고른다(개념 후보 규칙을 고친 뒤). 사람이 고친 값은 그대로다.
        // BATCH_VALUE=empty 면 범위에서 개념 연결이 빈 문항을 모두 고른다.
        final results = <Map<String, dynamic>>[];
        if (_valueText.trim() == 'empty') {
          for (final mid in mids) {
            await _load(mid);
            final scoped = mid.targetIds;
            final ids = [
              for (final x in mid.all)
                if (scoped.contains(x.cropId) && x.concepts.isEmpty && x.conceptProposals.isEmpty) x.cropId,
            ];
            for (var i = 0; i < ids.length; i += 8) {
              final chunk = ids.sublist(i, (i + 8).clamp(0, ids.length));
              final res = await review.runMetaChunk(mid.scope, cropIds: chunk, forceRerun: true);
              print('${mid.key} 개념 빈 ${chunk.length}문항 메타 다시 고름: ${jsonEncode(res)}');
              results.add({'mid': mid.key, 'crop_ids': chunk, 'result': res});
            }
          }
        } else {
          final (mid, it) = await _one(mids);
          final res = await review.runMetaChunk(mid.scope, cropIds: [it.cropId], forceRerun: true);
          print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 메타 다시 고름: ${jsonEncode(res)}');
          results.add({'mid': mid.key, 'crop_ids': [it.cropId], 'result': res});
        }
        out['meta_force'] = results;
      case 'sol_correct':
        await _solCorrect(mids);
      case 'note':
        await _note(mids);
      case 'fig_anchor':
        await _figAnchor(mids);
      case 'pb_choice_rows':
        await _pbChoiceRows(mids);
      case 'reconfirm':
        await _reconfirm(mids);
      default:
        fail('알 수 없는 단계: $step');
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join('build', 'textbook_batch', '$step-$stamp.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
    print('결과 파일: ${file.absolute.path}');
  }

  Future<List<_Mid>> _loadMids() async {
    final only = {for (final k in _only.split(',')) if (k.trim().isNotEmpty) k.trim()};
    final mids = <_Mid>[];
    for (final grade in _grades) {
      final byMid = <String, List<TextbookSubunitWorkflow>>{};
      for (final wf in await workflows.fetchForBook(academyId: _academyId, bookId: _bookId, gradeLabel: grade)) {
        if (!wf.isConfirmed && !(_open && wf.workOrder != null)) continue;
        if (wf.workOrder == null) {
          print('작업 지시가 없어 건너뜀: $grade ${wf.stateKey}');
          continue;
        }
        byMid.putIfAbsent('$grade/${wf.bigOrder}-${wf.midOrder}', () => []).add(wf);
      }
      for (final e in byMid.entries) {
        final wfs = [
          for (final wf in e.value)
            if (only.isEmpty || only.contains(e.key) || only.contains('${e.key}/${wf.scopeKey}')) wf,
        ];
        if (wfs.isEmpty) continue;
        wfs.sort((a, b) => a.scopeKey.length != b.scopeKey.length
            ? a.scopeKey.length.compareTo(b.scopeKey.length)
            : a.scopeKey.compareTo(b.scopeKey));
        mids.add(_Mid(e.key, wfs.first.workOrder!.reviewScope, wfs));
      }
    }
    mids.sort((a, b) {
      final g = a.scope.gradeLabel.compareTo(b.scope.gradeLabel);
      if (g != 0) return g;
      final big = a.scope.bigOrder.compareTo(b.scope.bigOrder);
      return big != 0 ? big : a.scope.midOrder.compareTo(b.scope.midOrder);
    });
    return mids;
  }

  Future<void> _load(_Mid mid) async {
    mid.all = await review.fetchUnitItems(mid.scope);
  }

  /// 막힌 이유 머리말(`메타 누락: …` → `메타 누락`)별 문항 수
  static Map<String, int> _blockerCounts(Iterable<TextbookProblemReviewItem> items) {
    final out = <String, int>{};
    for (final it in items) {
      for (final b in it.readyBlockers) {
        final head = b.split(':').first.trim();
        out[head] = (out[head] ?? 0) + 1;
      }
    }
    return out;
  }

  Future<void> _status(List<_Mid> mids) async {
    var total = 0;
    var ready = 0;
    final blockers = <String, int>{};
    for (final mid in mids) {
      await _load(mid);
      final ids = mid.targetIds;
      final outside = mid.all.where((x) => x.pbQuestionId.isNotEmpty && !ids.contains(x.cropId)).length;
      print('${mid.key} · 문항 ${ids.length}${outside > 0 ? ' · 확정 소단원 밖 $outside' : ''}');
      final rows = <Map<String, dynamic>>[];
      for (final wf in mid.workflows) {
        final items = mid.itemsOf(wf);
        final ok = items.where((x) => x.isWorkflowReady).length;
        final counts = _blockerCounts(items);
        final noRender = items.where((x) => x.renderCheckedAt == null).length;
        if (noRender > 0) counts['렌더 검수 기록 없음'] = noRender;
        final noOriginal = items.where((x) => x.renderCheckedAt != null && !x.originalCompared).length;
        if (noOriginal > 0) counts['원본 대조 없는 렌더 검수'] = noOriginal;
        total += items.length;
        ready += ok;
        counts.forEach((k, v) => blockers[k] = (blockers[k] ?? 0) + v);
        print('  ${wf.scopeKey} 준비됨 $ok/${items.length}'
            '${counts.isEmpty ? '' : ' · ${[for (final e in counts.entries) '${e.key} ${e.value}'].join(', ')}'}');
        rows.add({
          'scope_key': wf.scopeKey,
          'ready': ok,
          'total': items.length,
          'blocked': [
            for (final it in items)
              if (!it.isWorkflowReady)
                {'page': it.displayPage, 'number': it.problemNumber, 'crop_id': it.cropId, 'blockers': it.readyBlockers},
          ],
        });
      }
      out[mid.key] = {'outside_confirmed': outside, 'subunits': rows};
    }
    print('합계 준비됨 $ready/$total'
        '${blockers.isEmpty ? '' : ' · ${[for (final e in blockers.entries) '${e.key} ${e.value}'].join(', ')}'}');
  }

  /// 모의고사 회차(BATCH_VALUE)의 구간 검수를 매니저앱과 같은 서비스·실행기로 돌리고([run]), 구간별 상태를 남긴다.
  /// 확정은 하지 않는다.
  ///
  /// [again] 'continue' 면 확정하지 않은 구간을 AI 검수 단계부터 다시 돌리고(손볼 문항만), 'restart' 면 AI 가 쌓은
  /// 반영 대기 값을 버린 뒤 준비 단계부터 모든 문항을 다시 검수한다. 둘 다 추출은 다시 하지 않는다.
  Future<void> _mock({required bool run, String again = ''}) async {
    final examIds = {for (final x in _valueText.split(',')) if (x.trim().isNotEmpty) x.trim()};
    if (examIds.isEmpty && run) fail('BATCH_VALUE 에 모의고사 회차 id 를 넣으세요(쉼표 구분).');
    final runner = TextbookWorkflowRunner.withClient(db);
    final service = MockExamReviewService(client: db, problemBank: pb, workflows: workflows, runner: runner);
    String clock() => DateTime.now().toIso8601String().substring(11, 19);
    // 다시 돌릴 구간(BATCH_ONLY=common,geometry). 비우면 확정하지 않은 구간 모두.
    final onlySections = {for (final k in _only.split(',')) if (k.trim().isNotEmpty) k.trim()};
    if (run) {
      _usePdfium();
      for (final id in examIds) {
        final res = await service.startReview(academyId: _academyId, examId: id);
        print('[${clock()}] ${res.title}: 새로 시작한 구간 ${res.started}개'
            '${res.extractionRequested ? ' · 회차 추출 요청' : ''}');
      }
      for (final exam in await service.fetchExams(_academyId)) {
        if (!examIds.contains(exam.id)) continue;
        for (final s in exam.sections) {
          final stage = s.stage;
          final order = s.workflow?.workOrder;
          if (again.isNotEmpty && order != null && stage != MockExamReviewStage.confirmed) {
            if (onlySections.isNotEmpty && !onlySections.contains(s.section)) continue;
            if (runner.isActive(order.workflowKey)) continue;
            if (again == 'engine') {
              // 앱의 "코드 수정 후 재확인"과 같다: 렌더 엔진 보류(코드 수정 필요) 문항만 V2 로 다시 찍어 대조한다.
              final held = {
                for (final it in await review.fetchUnitItems(order.reviewScope))
                  if (order.matches(it) && it.isEngineHeld) it.cropId,
              };
              if (held.isEmpty) continue;
              runner.enqueue(order, fromPhase: TextbookWorkflowPhase.review, onlyCropIds: held, forceRenderCheck: true);
              print('[${clock()}] ${exam.title} ${s.label}: 코드 수정 필요 ${held.length}문항 다시 대조');
              continue;
            }
            if (again == 'restart') {
              // AI 가 쌓은 반영 대기 값을 버린다(사람이 고친 값은 RPC 가 건드리지 않는다).
              var cleared = 0;
              final items = [for (final it in await review.fetchUnitItems(order.reviewScope)) if (order.matches(it)) it];
              for (final it in items) {
                final keys = [for (final f in it.stagedFields) if (!it.stagedByOwner(f)) f];
                if (keys.isEmpty) continue;
                await review.stageChanges(cropId: it.cropId, patch: {for (final k in keys) k: null}, note: '검수 다시 시작');
                cleared += 1;
              }
              runner.enqueue(order, fromPhase: TextbookWorkflowPhase.extract, forceRerun: true, forceRenderCheck: true);
              print('[${clock()}] ${exam.title} ${s.label}: 처음부터 다시 검수(AI 반영 대기 값 $cleared문항 버림)');
            } else {
              runner.enqueue(order, fromPhase: TextbookWorkflowPhase.review);
              print('[${clock()}] ${exam.title} ${s.label}: AI 검수 단계부터 다시');
            }
            continue;
          }
          // 멈췄거나 실패한 구간은 그 단계부터 잇는다(앱의 "이어서 진행").
          final stalled = stage == MockExamReviewStage.running ||
              stage == MockExamReviewStage.failed ||
              stage == MockExamReviewStage.stopped;
          if (stalled && service.retry(s)) {
            print('[${clock()}] ${exam.title} ${s.label}: '
                '${TextbookWorkflowPhase.label(s.workflow?.pipelinePhase ?? '')} 단계부터 이어서');
          }
        }
      }
      // 실행기가 끝날 때까지 기다린다. 진행 글은 단계가 바뀔 때와 2분마다 한 번만 찍는다.
      final phases = <String, String>{};
      final printed = <String, DateTime>{};
      while (runner.activeCount > 0) {
        final now = DateTime.now();
        for (final s in runner.states) {
          final last = printed[s.key];
          final quiet = !s.active || s.phase == TextbookWorkflowPhase.queued;
          if (phases[s.key] == s.phase && (quiet || (last != null && now.difference(last) < const Duration(minutes: 2)))) {
            continue;
          }
          phases[s.key] = s.phase;
          printed[s.key] = now;
          print('[${clock()}] ${s.order.label}: ${TextbookWorkflowPhase.label(s.phase)} · ${s.detail}');
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      out['runs'] = [
        for (final s in runner.states)
          {
            'label': s.order.label,
            'document_id': s.order.bookId,
            'phase': s.phase,
            'detail': s.detail,
            'prepare': s.matchDetail,
            'error': s.error,
            'notes': s.notes,
            'seconds': s.startedAt == null || s.finishedAt == null
                ? null
                : s.finishedAt!.difference(s.startedAt!).inSeconds,
          },
      ];
      for (final s in runner.states) {
        print('[${clock()}] ${s.order.label}: ${TextbookWorkflowPhase.label(s.phase)} · ${s.summaryText}'
            '${s.matchDetail.isEmpty ? '' : ' · 준비: ${s.matchDetail}'}'
            '${s.error.isEmpty ? '' : '\n  오류: ${s.error}'}');
        for (final n in s.notes) {
          print('  $n');
        }
      }
    }

    final rows = <Map<String, dynamic>>[];
    final sections = <Map<String, dynamic>>[];
    String short(Object? v, [int max = 220]) {
      final s = '${v ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
      return s.length > max ? '${s.substring(0, max)}…' : s;
    }

    for (final exam in await service.fetchExams(_academyId)) {
      // 회차를 고르지 않았으면 검수를 시작한 회차를 모두 본다.
      if (examIds.isEmpty ? exam.workflows.isEmpty : !examIds.contains(exam.id)) continue;
      print('${exam.title} (회차 상태 ${exam.exam.status})');
      for (final s in exam.sections) {
        final wf = s.workflow;
        final order = wf?.workOrder;
        if (order == null) {
          print('  ${s.label}: 검수 전');
          continue;
        }
        final items = [for (final it in await review.fetchUnitItems(order.reviewScope)) if (order.matches(it)) it];
        final ok = items.where((x) => x.isWorkflowReady).length;
        final counts = _blockerCounts(items);
        final error = (wf?.pipelineError ?? '').trim();
        print('  ${s.label} [${s.stage.name}${s.publishOnConfirm ? ' · 확정 때 공개' : ''}] 준비됨 $ok/${items.length}'
            '${counts.isEmpty ? '' : ' · ${[for (final e in counts.entries) '${e.key} ${e.value}'].join(', ')}'}'
            '${error.isEmpty ? '' : '\n    오류: $error'}');
        sections.add({
          'exam': exam.title,
          'section': s.section,
          'document_id': s.documentId,
          'stage': s.stage.name,
          'publish_on_confirm': s.publishOnConfirm,
          'ready': ok,
          'total': items.length,
          'blockers': counts,
          'pipeline_detail': wf?.pipelineDetail,
          'pipeline_error': error,
        });
        for (final it in items) {
          final rc = it.renderChecks;
          final qc = it.qualityChecks;
          // 준비됨이 아닌 문항: 막힌 이유와 지적·카드 오류를 한 줄로 찍는다(고칠 문항과 이유를 바로 찾게).
          if (!it.isWorkflowReady) {
            final why = [
              if (it.solutionCardError.isNotEmpty) '해설 카드 오류: ${short(it.solutionCardError, 300)}',
              if ('${rc['issue_title'] ?? ''}'.trim().isNotEmpty)
                '렌더: ${short(rc['issue_title'], 80)}${'${rc['issue_detail'] ?? ''}'.trim().isEmpty ? '' : ' — ${short(rc['issue_detail'])}'}',
              if ('${qc['issue_title'] ?? ''}'.trim().isNotEmpty && !it.stage2Superseded)
                '문항: ${short(qc['issue_title'], 80)}${'${qc['issue_detail'] ?? ''}'.trim().isEmpty ? '' : ' — ${short(qc['issue_detail'])}'}',
              if (it.mathStatus == 'issue' && (it.mismatchReason ?? '').trim().isNotEmpty) '정답: ${short(it.mismatchReason)}',
              if (it.isEngineHeld && (it.engineHoldNote ?? '').trim().isNotEmpty) '보류: ${short(it.engineHoldNote)}',
              if (it.openSolutionLogicFinding != null)
                '해설 오류${it.solutionLogicFix.isEmpty ? '' : '(교정본 있음)'}: ${short(it.openSolutionLogicFinding!['detail'])}',
              for (final f in it.openCorrectionNotes) '교정 의견: ${short(f['detail'])}',
            ];
            print('    - ${it.problemNumber}번 [${it.readyBlockers.join(' / ')}]${why.isEmpty ? '' : ' ${why.join(' | ')}'}');
          }
          rows.add({
            'exam': exam.title,
            'section': s.section,
            'number': it.problemNumber,
            'page': it.displayPage,
            'crop_id': it.cropId,
            'ready': it.isWorkflowReady,
            'blockers': it.readyBlockers,
            'staged': it.stagedFields,
            'figure_size_ratio': rc['figure_size_ratio'],
            for (final k in const ['problem_ok', 'answer_ok', 'solution_ok', 'fidelity_ok', 'figure_position_ok'])
              if (rc[k] == false) k: false,
            'issue_kind': rc['issue_kind'],
            'issue_title': rc['issue_title'],
            'issue_detail': rc['issue_detail'],
            'engine_symptom': rc['engine_symptom'],
            if (it.solutionCardError.isNotEmpty) 'answer_solution_error': it.solutionCardError,
            'quality_status': it.qualityStatus,
            'math_status': it.mathStatus,
            if ('${qc['issue_title'] ?? ''}'.trim().isNotEmpty) 'quality_issue': '${qc['issue_title']}: ${qc['issue_detail'] ?? ''}',
            if ((it.mismatchReason ?? '').trim().isNotEmpty) 'mismatch_reason': it.mismatchReason,
            if (it.openSolutionLogicFinding != null) ...{
              'solution_logic': '${it.openSolutionLogicFinding!['detail'] ?? ''}',
              'solution_logic_fix': it.solutionLogicFix.isNotEmpty,
            },
            if (it.openCorrectionNotes.isNotEmpty)
              'correction_notes': [for (final f in it.openCorrectionNotes) '${f['detail'] ?? ''}'],
            'solution_kind': it.primarySolutionKind,
          });
        }
      }
    }
    out['sections'] = sections;
    out['items'] = rows;
  }

  /// 해설 위치를 지금 규칙으로 다시 계산해 달라지는 문항만 적는다(BATCH_VALUE=회차 id 쉼표, BATCH_ONLY=구간).
  /// 아무것도 쓰지 않으므로 확정된 구간도 본다.
  Future<void> _mockSolrefPreview() async {
    final examIds = {for (final x in _valueText.split(',')) if (x.trim().isNotEmpty) x.trim()};
    if (examIds.isEmpty) fail('BATCH_VALUE 에 모의고사 회차 id 를 넣으세요(쉼표 구분).');
    final onlySections = {for (final k in _only.split(',')) if (k.trim().isNotEmpty) k.trim()};
    final runner = TextbookWorkflowRunner.withClient(db);
    final service = MockExamReviewService(client: db, problemBank: pb, workflows: workflows, runner: runner);
    final done = <Map<String, dynamic>>[];
    for (final exam in await service.fetchExams(_academyId)) {
      if (!examIds.contains(exam.id)) continue;
      for (final s in exam.sections) {
        final documentId = s.documentId ?? '';
        if (onlySections.isNotEmpty && !onlySections.contains(s.section)) continue;
        if (documentId.isEmpty) {
          print('${exam.title} ${s.label}: 구간 문서 없음');
          continue;
        }
        try {
          final res = await pb.previewMockSolutionRefs(academyId: _academyId, documentId: documentId);
          final changes = [for (final c in (res['changes'] as List?) ?? const []) if (c is Map) Map<String, dynamic>.from(c)];
          print('${exam.title} ${s.label} [${s.stage.name}]: 해설 ${res['solutionCount'] ?? 0}/${res['cropCount'] ?? 0}'
              ' · 사람이 고친 위치 ${res['solutionProtected'] ?? 0} · 달라지는 문항 ${changes.length}');
          for (final c in changes) {
            String at(Object? r) {
              if (r is! Map) return '없음';
              final cont = [
                for (final x in (r['continuation_regions'] as List?) ?? const [])
                  if (x is Map) 'p${x['raw_page']} ${x['region_1k']}',
              ];
              return 'p${r['raw_page']} ${r['content_region_1k']}${cont.isEmpty ? '' : ' + ${cont.join(' + ')}'}';
            }

            print('  - ${c['number']}번: ${at(c['before'])} → ${at(c['after'])}');
          }
          done.add({'exam': exam.title, 'section': s.section, 'stage': s.stage.name, 'document_id': documentId, ...res});
        } catch (e) {
          print('${exam.title} ${s.label}: 오류 $e');
          done.add({'exam': exam.title, 'section': s.section, 'document_id': documentId, 'error': '$e'});
        }
      }
    }
    out['preview'] = done;
  }

  /// 검수는 돌리지 않고 구간 준비만 다시 한다(BATCH_VALUE=회차 id 쉼표, BATCH_ONLY=구간). 추출과 정답 다시 읽기는 하지 않는다.
  /// 해설 위치가 게이트웨이 계산값과 달라진 문항(사람이 고친 위치는 빼고)만 계산값으로 다시 쓴다. 옮긴 해설은 그대로다.
  Future<void> _mockPrepare() async {
    final examIds = {for (final x in _valueText.split(',')) if (x.trim().isNotEmpty) x.trim()};
    if (examIds.isEmpty) fail('BATCH_VALUE 에 모의고사 회차 id 를 넣으세요(쉼표 구분).');
    final onlySections = {for (final k in _only.split(',')) if (k.trim().isNotEmpty) k.trim()};
    final runner = TextbookWorkflowRunner.withClient(db);
    final service = MockExamReviewService(client: db, problemBank: pb, workflows: workflows, runner: runner);
    final done = <Map<String, dynamic>>[];
    for (final exam in await service.fetchExams(_academyId)) {
      if (!examIds.contains(exam.id)) continue;
      for (final s in exam.sections) {
        final documentId = s.documentId ?? '';
        if (onlySections.isNotEmpty && !onlySections.contains(s.section)) continue;
        if (documentId.isEmpty || s.workflow?.workOrder == null) {
          print('${exam.title} ${s.label}: 검수 전이라 건너뜀');
          continue;
        }
        if (s.stage == MockExamReviewStage.confirmed || s.stage == MockExamReviewStage.running) {
          print('${exam.title} ${s.label}: ${s.stage.name} 상태라 건너뜀');
          continue;
        }
        final res = await pb.prepareMockReview(academyId: _academyId, documentId: documentId);
        final written = (res['solutionsWritten'] as num?)?.toInt() ?? 0;
        final detail = '문항 ${res['cropCount'] ?? 0}개 · 해설 ${res['solutionCount'] ?? 0}'
            ' · 이어진 해설 ${res['solutionContinued'] ?? 0}';
        final waiting = '${res['state'] ?? ''}' == 'waiting';
        print('${exam.title} ${s.label}: ${waiting ? '준비 안 됨(${res['reason'] ?? ''})' : detail}'
            ' · 해설 위치 다시 씀 $written');
        done.add({'exam': exam.title, 'section': s.section, 'document_id': documentId, 'solutions_written': written, ...res});
      }
    }
    out['prepared'] = done;
  }

  /// 다른 구간의 문항을 가리키는 자리(mock_exam_items.merged_at)에는 검수 크롭이 없다. 자리마다 그 시험지의
  /// 원본 영역과, 자리 값(본문·선지 순서·배점·형식)으로 찍은 카드를 파일로 남겨 눈으로 견줄 수 있게 한다.
  Future<void> _mockSlotCheck() async {
    final examIds = {for (final x in _valueText.split(',')) if (x.trim().isNotEmpty) x.trim()};
    if (examIds.isEmpty) fail('BATCH_VALUE 에 모의고사 회차 id 를 넣으세요(쉼표 구분).');
    _usePdfium();
    final dir = Directory(p.join('build', 'textbook_batch', 'slot'))..createSync(recursive: true);
    final service = MockExamReviewService(
      client: db,
      problemBank: pb,
      workflows: workflows,
      runner: TextbookWorkflowRunner.withClient(db),
    );
    Future<String> save(String name, List<int>? bytes) async {
      if (bytes == null || bytes.isEmpty) return '';
      final f = File(p.join(dir.path, name));
      await f.writeAsBytes(bytes);
      return f.absolute.path;
    }

    Future<List<int>?> download(String url) async {
      if (url.isEmpty) return null;
      final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
      if (res.statusCode != 200) return null;
      return [for (final chunk in await res.toList()) ...chunk];
    }

    final rows = <Map<String, dynamic>>[];
    for (final exam in await service.fetchExams(_academyId)) {
      if (!examIds.contains(exam.id)) continue;
      // 문항의 반영 대기 값(검수가 고쳐 둔 본문 등)도 넣어 찍는다. 확정하면 문항에 쓰일 값이다.
      final stagedByQuestion = <String, Map<String, dynamic>>{};
      for (final s in exam.sections) {
        final order = s.workflow?.workOrder;
        if (order == null) continue;
        for (final it in await review.fetchUnitItems(order.reviewScope)) {
          final staged = it.previewOverride;
          if (order.matches(it) && staged != null && it.pbQuestionId.isNotEmpty) stagedByQuestion[it.pbQuestionId] = staged;
        }
      }
      final items = await db
          .from('mock_exam_items')
          .select('id, section, problem_number, raw_page, item_region_1k, pb_question_id, answer_kind')
          .eq('exam_id', exam.id)
          .not('merged_at', 'is', null)
          .order('problem_number');
      for (final raw in items as List<dynamic>) {
        final it = Map<String, dynamic>.from(raw as Map);
        final section = '${it['section']}';
        final number = (it['problem_number'] as num).toInt();
        final questionId = '${it['pb_question_id'] ?? ''}'.trim();
        final sections = exam.sections.where((x) => x.section == section).toList();
        final scope = sections.isEmpty ? null : sections.first.workflow?.workOrder?.reviewScope;
        final label = sections.isEmpty ? section : sections.first.label;
        final tag = '${exam.id.substring(0, 8)}_${section}_$number';
        final region = [for (final v in (it['item_region_1k'] as List<dynamic>? ?? const [])) (v as num).toInt()];
        var original = '';
        if (scope != null) {
          final image = await review.bodyRegionImage(scope, (it['raw_page'] as num?)?.toInt() ?? 0, region);
          original = await save('${tag}_original.png', image?.bytes);
        }
        var card = '';
        if (questionId.isNotEmpty) {
          final urls = await pb.batchRenderThumbnails(
            academyId: _academyId,
            questionIds: [questionId],
            renderConfig: const {'includeQuestionScore': true},
            mockSlotItemByQuestionId: {questionId: '${it['id']}'},
            questionOverrides: {
              if (stagedByQuestion[questionId] != null) questionId: stagedByQuestion[questionId]!,
            },
            questionModeByQuestionUid: {
              questionId: '${it['answer_kind']}' == 'objective' ? 'objective' : 'subjective',
            },
          );
          card = await save('${tag}_slot_card.png', await download(urls[questionId] ?? ''));
        }
        print('${exam.title} $label $number번 자리: 원본 ${original.isEmpty ? '없음' : original} · 카드 ${card.isEmpty ? '없음' : card}');
        rows.add({'exam': exam.title, 'section': section, 'number': number, 'question_id': questionId, 'original': original, 'card': card});
      }
    }
    out['slots'] = rows;
  }

  /// BATCH_CROPS 문항의 AI 반영 대기 값 가운데 BATCH_VALUE 의 필드만 버린다(사람이 고친 값은 그대로).
  /// 버리면 저장된 값(해설 전사 단계가 옮긴 해설 등)이 다시 쓰인다. 그 뒤 mock_continue 로 카드를 다시 대조한다.
  /// 모의고사 문항 하나(BATCH_CROPS)의 본문을 사장님 수정으로 반영 대기에 넣는다(BATCH_VALUE=`@경로`).
  /// 교재의 stem 단계와 같은 저장이다. 검수는 돌리지 않는다(뒤에 mock_continue).
  Future<void> _mockStem() async {
    final crops = [for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()];
    final value = _valueText;
    if (crops.length != 1 || value.trim().isEmpty) fail('BATCH_CROPS(크롭 id 하나)와 BATCH_VALUE(본문)를 주세요.');
    final changed = await review.stageChanges(
      cropId: crops.single,
      patch: {'stem': value},
      source: 'owner',
      note: '사장님 수정',
    );
    print('${crops.single} 본문 반영 대기 · 바뀜 ${changed.join(', ')}');
    out['mock_stem'] = {'crop_id': crops.single, 'stem': value, 'changed': changed};
  }

  Future<void> _mockUnstage() async {
    final crops = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    final fields = {for (final f in _valueText.split(',')) if (f.trim().isNotEmpty) f.trim()};
    if (crops.isEmpty || fields.isEmpty) fail('BATCH_CROPS(크롭 id)와 BATCH_VALUE(필드)를 주세요.');
    final service = MockExamReviewService(
      client: db,
      problemBank: pb,
      workflows: workflows,
      runner: TextbookWorkflowRunner.withClient(db),
    );
    final rows = <Map<String, dynamic>>[];
    for (final exam in await service.fetchExams(_academyId)) {
      for (final s in exam.sections) {
        final order = s.workflow?.workOrder;
        if (order == null) continue;
        for (final it in await review.fetchUnitItems(order.reviewScope)) {
          if (!crops.contains(it.cropId)) continue;
          final keys = [for (final f in it.stagedFields) if (fields.contains(f) && !it.stagedByOwner(f)) f];
          if (keys.isNotEmpty) {
            await review.stageChanges(cropId: it.cropId, patch: {for (final k in keys) k: null}, note: 'AI 반영 대기 값 버림');
          }
          print('${exam.title} ${s.label} ${it.problemNumber}번: ${keys.isEmpty ? '버릴 값 없음' : '${keys.join(', ')} 버림'}');
          rows.add({'exam': exam.title, 'section': s.section, 'number': it.problemNumber, 'crop_id': it.cropId, 'cleared': keys});
        }
      }
    }
    if (rows.length != crops.length) print('찾지 못한 문항 ${crops.length - rows.length}개');
    out['items'] = rows;
  }

  Future<void> _consistency(List<_Mid> mids, {required bool dryRun}) async {
    var total = TextbookConsistencyReport.empty;
    for (final mid in mids) {
      await _load(mid);
      final ids = mid.targetIds.toList();
      TextbookConsistencyReport r;
      try {
        r = await review.runConsistencyCheck(mid.scope, cropIds: ids, dryRun: dryRun);
      } catch (e) {
        r = TextbookConsistencyReport(checked: 0, fixed: const [], flagged: const [], resolved: 0, errors: ['$e']);
      }
      print('${mid.key}: ${r.summary}${r.errors.isEmpty ? '' : ' (${r.errors.first})'}');
      out[mid.key] = {'checked': r.checked, 'fixed': r.fixed, 'flagged': r.flagged, 'resolved': r.resolved, 'errors': r.errors};
      total = total + r;
    }
    final fixes = <String, int>{};
    for (final f in total.fixed) {
      for (final t in (f['fixes'] is List ? f['fixes'] as List : const [])) {
        fixes['$t'] = (fixes['$t'] ?? 0) + 1;
      }
    }
    print('합계: ${total.summary}');
    if (fixes.isNotEmpty) print('수정안 종류: ${[for (final e in fixes.entries) '${e.key} ${e.value}'].join(', ')}');
  }

  Future<void> _meta(List<_Mid> mids) async {
    for (final mid in mids) {
      await _load(mid);
      final ids = mid.targetIds;
      final pipeline = TextbookReviewPipeline(
        service: review,
        scope: mid.scope,
        matches: (it) => ids.contains(it.cropId),
        onProgress: (m) => print('  ${mid.key} $m'),
      );
      final filled = await pipeline.runMetaOnly();
      final missing = pipeline.items.where((x) => x.missingMeta.isNotEmpty).toList();
      print('${mid.key}: ${pipeline.consistency.summary} · 메타 보충 $filled문항'
          '${missing.isEmpty ? '' : ' · 메타 누락 남음 ${missing.length}'}'
          '${pipeline.errors.isEmpty ? '' : ' · 실패 ${pipeline.errors.length}건(${pipeline.errors.first})'}');
      out[mid.key] = {
        'consistency': pipeline.consistency.summary,
        'meta_filled': filled,
        'missing_meta': [
          for (final it in missing) {'page': it.displayPage, 'number': it.problemNumber, 'missing': it.missingMeta},
        ],
        'errors': pipeline.errors,
      };
    }
  }

  /// 작업 화면의 정합성 지적 "문제 없음" 버튼과 같다. 문항 내용이 그대로면 다시 점검해도 열리지 않는다.
  Future<void> _dismiss(List<_Mid> mids) async {
    final crops = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    if (crops.isEmpty) fail('BATCH_CROPS 가 비어 있습니다.');
    final closed = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final hits = mid.all.where((x) => crops.contains(x.cropId)).toList();
      for (final it in hits) {
        crops.remove(it.cropId);
        for (final f in it.consistencyIssues) {
          await review.dismissConsistencyIssue(findingId: '${f['id']}', note: '사장님 확인: 문제 없음');
          closed.add({'mid': mid.key, 'page': it.displayPage, 'number': it.problemNumber, 'title': f['title']});
          print('${mid.key} p.${it.displayPage} ${it.problemNumber}번: ${f['title']} → 문제 없음');
        }
      }
    }
    if (crops.isNotEmpty) print('찾지 못한 문항: ${crops.join(', ')}');
    out['dismissed'] = closed;
    out['not_found'] = crops.toList();
  }

  /// 교재 원본 PDF 를 찍을 준비(앱 빌드의 pdfium, 앱과 같은 임시 폴더의 PDF 캐시)
  static void _usePdfium() {
    final pdfium = File(p.join('build', 'windows', 'x64', 'runner', 'Debug', 'pdfium.dll'));
    if (!pdfium.existsSync()) fail('pdfium 이 없습니다. 매니저앱을 Windows 로 한 번 빌드하세요.');
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    PathProviderPlatform.instance = PathProviderWindows();
  }

  /// 사장님이 보는 것과 같은 카드(반영 대기 값을 얹은 V2 문항 카드, 정답·해설 카드)와 교재 원본을 파일로 남긴다.
  Future<void> _snapshot(List<_Mid> mids) async {
    final crops = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    if (crops.isEmpty) fail('BATCH_CROPS 가 비어 있습니다.');
    _usePdfium();
    final dir = Directory(p.join('build', 'textbook_batch', 'snap'))..createSync(recursive: true);
    final saved = <String>[];
    Future<void> save(String name, List<int>? bytes) async {
      if (bytes == null || bytes.isEmpty) return;
      final f = File(p.join(dir.path, name));
      await f.writeAsBytes(bytes);
      saved.add(f.absolute.path);
    }

    Future<List<int>?> download(String url) async {
      if (url.isEmpty) return null;
      final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
      if (res.statusCode != 200) return null;
      return [for (final chunk in await res.toList()) ...chunk];
    }

    for (final mid in mids) {
      await _load(mid);
      for (final it in mid.all.where((x) => crops.contains(x.cropId))) {
        final tag = '${mid.key.replaceAll('/', '_')}_p${it.displayPage}_${it.problemNumber}';
        final urls = await review.fetchEnginePreviewUrls(academyId: mid.scope.academyId, items: [it]);
        await save('${tag}_v2.png', await download(urls[it.cropId] ?? ''));
        final answerUrl = await review.renderAnswerSolutionCard(
          academyId: mid.scope.academyId,
          item: it,
          solutionText: it.primarySolutionText,
          solutionKind: it.primarySolutionKind,
        );
        await save('${tag}_answer.png', await download(answerUrl));
        final variants = [for (final l in _valueText.split('\n')) if (l.trim().isNotEmpty) l.trim()];
        for (var i = 0; i < variants.length; i++) {
          final url = await review.renderAnswerSolutionCard(
            academyId: mid.scope.academyId,
            item: it,
            solutionText: it.primarySolutionText,
            solutionKind: it.primarySolutionKind,
            answerText: variants[i],
          );
          await save('${tag}_answer_v${i + 1}.png', await download(url));
        }
        await save('${tag}_original.png', (await review.originalImage(mid.scope, it))?.bytes);
        await save('${tag}_set_header.png', (await review.setHeaderImage(mid.scope, it))?.bytes);
        final sol = await review.solutionOriginalJson(mid.scope, it);
        final solB64 = '${sol['solution_original_image_base64'] ?? ''}';
        if (solB64.isNotEmpty) await save('${tag}_solution_original.png', base64Decode(solB64));
      }
    }
    for (final f in saved) {
      print(f);
    }
    out['saved'] = saved;
  }

  /// 작업 화면의 "V2 렌더 검수 다시"와 같다. 원본 없이 보내면 대조 없이 통과할 수 있어서,
  /// 원본을 못 찍는 문항이 하나라도 있으면 그 중단원은 보내지 않는다.
  Future<void> _render(List<_Mid> mids) async {
    _usePdfium();
    final picked = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    final unchecked = _valueText == 'unchecked';
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final ids = mid.targetIds;
      final targets = {
        for (final it in mid.all)
          if (ids.contains(it.cropId) &&
              (it.readyBlockers.contains('V2 렌더 이상') ||
                  picked.contains(it.cropId) ||
                  (unchecked && (it.renderCheckedAt == null || !it.originalCompared))))
            it.cropId,
      };
      print('${mid.key}: 렌더 재검수 ${targets.length}문항');
      if (targets.isEmpty) continue;
      final noOriginal = [
        for (final it in mid.all)
          if (targets.contains(it.cropId) && await review.originalImage(mid.scope, it) == null) '${it.problemNumber}번',
      ];
      if (noOriginal.isNotEmpty) {
        print('${mid.key}: 원본을 찍지 못해 보내지 않음 (${noOriginal.join(', ')})');
        out[mid.key] = {'error': '원본 없음', 'items': noOriginal};
        continue;
      }
      final pipeline = TextbookReviewPipeline(
        service: review,
        scope: mid.scope,
        matches: (it) => targets.contains(it.cropId),
        onProgress: (m) => print('  ${mid.key} $m'),
      );
      await pipeline.recheckRender();
      for (final e in pipeline.errors) {
        print('  ${mid.key} 오류: $e');
      }
      for (final it in pipeline.items) {
        rows.add(_renderRow(mid, it));
      }
      out[mid.key] = {'errors': pipeline.errors};
    }
    out['items'] = rows;
  }

  /// 그림만 검수(시험용). 본문에 그림이 있는 문항만 골라 원본 대조 수정 단계의 그림 배치 제안만 반영 대기에 넣고,
  /// 문항 카드만 원본과 대조한다(정답·해설 카드는 보내지 않는다). 글자 수정안과 그림 다시 자르기 제안은 쓰지 않는다.
  /// 작업 지시 없이 `BATCH_ONLY=학년/대-중` 하나를 직접 받는다. `BATCH_VALUE=숫자` 면 앞에서 그 수만큼만,
  /// `BATCH_CROPS` 가 있으면 그 문항만 한다. 문제은행은 바꾸지 않는다.
  Future<void> _figOnly() async {
    _usePdfium();
    // 한글·공백이 든 학년 이름은 명령줄에서 깨질 수 있어 `@경로`(UTF-8 파일)로도 받는다.
    final key = _only.trim().startsWith('@')
        ? File(_only.trim().substring(1)).readAsStringSync().replaceAll('\uFEFF', '').trim()
        : _only.trim();
    final m = RegExp(r'^(.+)/(\d+)-(\d+)$').firstMatch(key);
    if (m == null) fail('BATCH_ONLY 에 학년/대-중 하나를 주세요 (예: 2-2/3-0).');
    final scope = TextbookReviewUnitScope(
      academyId: _academyId,
      bookId: _bookId,
      bookName: '',
      gradeLabel: m.group(1)!,
      bigOrder: int.parse(m.group(2)!),
      midOrder: int.parse(m.group(3)!),
      bigName: '',
      midName: '',
      problemCount: 0,
      analyzedCount: 0,
      mathCleanCount: 0,
      mathIssueCount: 0,
      mathApprovedCount: 0,
      qualityCleanCount: 0,
      qualityIssueCount: 0,
      qualityApprovedCount: 0,
    );
    final mid = _Mid(key, scope, const []);
    final picked = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    final limit = int.tryParse(_valueText) ?? 0;

    var all = await review.fetchUnitItems(scope);
    var targets = [
      for (final it in all)
        if (it.hasFigures && it.canRenderOriginal && it.previewLookupKey.isNotEmpty && (picked.isEmpty || picked.contains(it.cropId)))
          it,
    ];
    // BATCH_SUB=B 처럼 단계(sub_key)를 주면 그 단계 문항만 한다.
    const sub = String.fromEnvironment('BATCH_SUB');
    if (sub.isNotEmpty) targets = [for (final it in targets) if (it.subKey == sub) it];
    if (limit > 0 && targets.length > limit) targets = targets.sublist(0, limit);
    bool passed(TextbookProblemReviewItem it) =>
        it.originalCompared &&
        it.renderChecks['figure_position_ok'] != false &&
        !it.figureNeedsResize &&
        it.renderChecks['problem_ok'] != false;

    // BATCH_VALUE=apply: 대조를 통과한 문항의 반영 대기 그림 배치·그림 자산만 문제은행에 쓴다(승인 처리 없음, AI 호출 없음).
    // 세트 공통 그림 배치는 이 경로로 쓸 수 없어 남긴다.
    if (_valueText == 'apply') {
      final rows = <Map<String, dynamic>>[];
      var applied = 0;
      for (final it in targets) {
        final st = it.stagedChanges;
        final layout = st['figure_layout'] is Map ? Map<String, dynamic>.from(st['figure_layout'] as Map) : null;
        final assets = st['figure_assets'] is List
            ? [for (final a in st['figure_assets'] as List) if (a is Map) Map<String, dynamic>.from(a)]
            : null;
        final common = st['common_figure_layout'] != null;
        if (layout == null && assets == null && !common) continue;
        var state = '';
        if (!passed(it)) {
          state = '확인 필요라 남김';
        } else if (layout == null && assets == null) {
          state = '세트 공통 그림 배치라 남김';
        } else {
          try {
            final res = await review.applyProblemFix(
              cropId: it.cropId,
              figureLayout: layout,
              figureAssets: assets,
              note: '그림만 검수 반영',
            );
            await review.stageChanges(
              cropId: it.cropId,
              patch: {if (layout != null) 'figure_layout': null, if (assets != null) 'figure_assets': null},
              note: '그림만 검수 반영',
            );
            applied += 1;
            state = '반영 ${(res['changed'] as List?)?.join(',') ?? ''}${common ? ' (공통 그림 배치는 남김)' : ''}';
          } catch (e) {
            state = '실패: $e';
          }
        }
        print('$key ${it.subKey} p.${it.displayPage} ${it.problemNumber}번: $state');
        rows.add({'number': it.problemNumber, 'crop_id': it.cropId, 'sub_key': it.subKey, 'state': state});
      }
      print('$key: 문제은행 반영 $applied문항 / 반영 대기 그림이 있던 ${rows.length}문항');
      out[key] = {'applied': applied};
      out['items'] = rows;
      return;
    }
    // BATCH_VALUE=recrop: 수정안을 다시 만들지 않고, 이미 나온 그림 다시 자르기 제안만 반영 대기에 넣고 다시 대조한다.
    // BATCH_VALUE=view: 지금 카드와 원본을 build/textbook_batch/figonly 에 저장만 한다(AI 호출 없음).
    final recrop = _valueText == 'recrop';
    if (recrop) targets = [for (final it in targets) if (it.proposedFigureCrops.isNotEmpty) it];
    final ids = {for (final it in targets) it.cropId};
    print('$key: 전체 ${all.length}문항 · 그림 문항 대상 ${targets.length}');
    if (targets.isEmpty) return;
    List<TextbookProblemReviewItem> pick() => [for (final it in all) if (ids.contains(it.cropId)) it];
    final errors = <String>[];

    final urls = await review.fetchEnginePreviewUrls(academyId: _academyId, items: targets);
    final noCard = [for (final it in targets) if ((urls[it.cropId] ?? '').isEmpty) '${it.problemNumber}번'];
    if (noCard.isNotEmpty) errors.add('문항 카드를 찍지 못함: ${noCard.join(', ')}');

    if (_valueText == 'view') {
      final dir = Directory(p.join('build', 'textbook_batch', 'figonly'))..createSync(recursive: true);
      for (final it in targets) {
        final url = urls[it.cropId] ?? '';
        if (url.isNotEmpty) {
          final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
          if (res.statusCode == 200) {
            await File(p.join(dir.path, '${it.problemNumber}_v2.png'))
                .writeAsBytes([for (final chunk in await res.toList()) ...chunk]);
          }
        }
        final orig = await review.originalImage(scope, it);
        if (orig != null) await File(p.join(dir.path, '${it.problemNumber}_original.png')).writeAsBytes(orig.bytes);
      }
      print('저장: ${dir.absolute.path} (${targets.length}문항)');
      return;
    }

    // 검수 기록 행이 없으면 수정안·대조 결과가 저장되지 않는다. 빈 반영 대기 호출로 행을 만든다.
    if (!recrop) {
      for (final it in targets) {
        await review.stageChanges(cropId: it.cropId);
      }
    }

    // 1) 원본 대조 수정안(해설 이미지는 보내지 않는다)
    var fixed = 0;
    for (var i = 0; !recrop && i < targets.length; i += 6) {
      final pair = [
        for (var j = i; j < i + 6 && j < targets.length; j += 3) targets.sublist(j, (j + 3).clamp(0, targets.length)),
      ];
      final counts = await Future.wait([
        for (final chunk in pair)
          () async {
            try {
              final images = await review.prepareChunkImages(
                scope: scope,
                items: chunk,
                previewUrlsByCropId: urls,
                includeSolution: false,
                allItems: all,
              );
              final ok = [
                for (final it in chunk)
                  if (images[it.cropId]?.original != null) it.cropId,
              ];
              for (final it in chunk) {
                if (!ok.contains(it.cropId)) errors.add('${it.problemNumber}번: 본문 PDF 원본을 찍지 못함');
              }
              if (ok.isEmpty) return 0;
              final res = await review.runFixPass(scope, cropIds: ok, images: {for (final id in ok) id: images[id]!});
              return (res['processed'] as num?)?.toInt() ?? 0;
            } catch (e) {
              errors.add('${chunk.map((x) => x.problemNumber).join(',')}번 원본 대조: $e');
              return 0;
            }
          }(),
      ]);
      fixed += counts.fold<int>(0, (s, c) => s + c);
      print('  $key 수정안 ${(i + 6).clamp(0, targets.length)}/${targets.length}');
    }

    // 2) 그림 배치 제안만 반영 대기에 넣는다
    all = await review.fetchUnitItems(scope);
    var staged = 0;
    final recropProposed = <String>[];
    final textProposed = <String>[];
    for (final it in pick()) {
      if (it.proposedFigureCrops.isNotEmpty) recropProposed.add('${it.problemNumber}번');
      if (it.hasPendingFixProposal) textProposed.add('${it.problemNumber}번');
      if (recrop) {
        try {
          final changed = await review.stageProblemFix(
            scope: scope,
            item: it,
            figureCrops: it.proposedFigureCrops,
            note: '그림만 검수: 그림 다시 자르기',
          );
          if (changed.isNotEmpty) staged += 1;
        } catch (e) {
          errors.add('${it.problemNumber}번 그림 다시 자르기: $e');
        }
        continue;
      }
      final layout = it.proposedFigureLayout;
      if (layout == null || !it.hasPendingFigureProposal) continue;
      try {
        final changed = await review.stageProblemFix(scope: scope, item: it, figureLayout: layout, note: '그림만 검수');
        if (changed.isNotEmpty) staged += 1;
      } catch (e) {
        errors.add('${it.problemNumber}번 그림 배치: $e');
      }
    }
    print('  $key 수정안 $fixed문항 · 그림 배치 반영 대기 $staged문항');

    // 3) 문항 카드만 원본과 대조, 크기가 어긋나면 잰 비율로 고쳐 한 번 더
    all = await review.fetchUnitItems(scope);
    var checked = await review.recheckProblemCards(
      scope: scope,
      items: pick(),
      onProgress: (d, t) => print('  $key 원본 대조 $d/$t'),
    );
    all = await review.fetchUnitItems(scope);
    final sized = (await review.resizeFiguresFromMeasuredRatio(pick())).toSet();
    if (sized.isNotEmpty) {
      all = await review.fetchUnitItems(scope);
      checked += await review.recheckProblemCards(
        scope: scope,
        items: [for (final it in all) if (sized.contains(it.cropId)) it],
        onProgress: (d, t) => print('  $key 크기 고친 뒤 다시 대조 $d/$t'),
      );
      all = await review.fetchUnitItems(scope);
    }

    final rows = <Map<String, dynamic>>[];
    var pass = 0;
    for (final it in pick()) {
      final rc = it.renderChecks;
      final ok = it.originalCompared && rc['figure_position_ok'] != false && !it.figureNeedsResize && rc['problem_ok'] != false;
      if (ok) pass += 1;
      print('$key p.${it.displayPage} ${it.problemNumber}번: ${ok ? '통과' : '확인 필요'}'
          '${rc['figure_size_ratio'] == null ? '' : ' · 그림 크기 ${rc['figure_size_ratio']}배'}'
          '${rc['figure_position_ok'] == false ? ' · 위치 다름' : ''}'
          '${sized.contains(it.cropId) ? ' · 크기 고침' : ''}'
          '${rc['issue_title'] == null ? '' : ' · ${rc['issue_title']}'}');
      rows.add({
        'page': it.displayPage,
        'number': it.problemNumber,
        'crop_id': it.cropId,
        'pass': ok,
        'original_compared': it.originalCompared,
        'figure_size_ratio': rc['figure_size_ratio'],
        'figure_position_ok': rc['figure_position_ok'],
        'problem_ok': rc['problem_ok'],
        'fidelity_ok': rc['fidelity_ok'],
        'resized': sized.contains(it.cropId),
        'staged': it.stagedFields,
        'issue_kind': rc['issue_kind'],
        'issue_title': rc['issue_title'],
        'issue_detail': rc['issue_detail'],
      });
    }
    for (final e in errors) {
      print('  $key 오류: $e');
    }
    print('$key: 대상 ${targets.length} · 대조 $checked회 · 통과 $pass · 확인 필요 ${targets.length - pass}'
        ' · 크기 고침 ${sized.length} · 그림 다시 자르기 제안(미적용) ${recropProposed.length}'
        ' · 글자 수정안(미적용) ${textProposed.length}');
    out[mid.key] = {
      'targets': targets.length,
      'fixed': fixed,
      'layout_staged': staged,
      'checked': checked,
      'pass': pass,
      'resized': sized.length,
      'recrop_proposed_not_applied': recropProposed,
      'text_proposed_not_applied': textProposed,
      'errors': errors,
    };
    out['items'] = rows;
  }

  Map<String, dynamic> _renderRow(_Mid mid, TextbookProblemReviewItem it) {
    final rc = it.renderChecks;
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번: '
        '${it.isWorkflowReady ? '준비됨' : '막힘(${it.readyBlockers.join(', ')})'}'
        '${it.stagedFields.isEmpty ? '' : ' · 반영 대기 ${it.stagedFields.join(',')}'}'
        '${rc['figure_size_ratio'] == null ? '' : ' · 그림 크기 ${rc['figure_size_ratio']}배'}'
        '${rc['issue_title'] == null ? '' : ' · ${rc['issue_title']}'}');
    return {
      'mid': mid.key,
      'page': it.displayPage,
      'number': it.problemNumber,
      'crop_id': it.cropId,
      'ready': it.isWorkflowReady,
      'blockers': it.readyBlockers,
      'figure_size_ratio': rc['figure_size_ratio'],
      'staged': it.stagedFields,
      for (final k in const ['problem_ok', 'answer_ok', 'solution_ok', 'fidelity_ok', 'figure_position_ok'])
        if (rc[k] == false) k: false,
      'issue_kind': rc['issue_kind'],
      'issue_title': rc['issue_title'],
      'issue_detail': rc['issue_detail'],
      'engine_symptom': rc['engine_symptom'],
    };
  }

  /// 작업 화면의 "이어서 마무리"와 같은 검수 파이프라인을 막힌 문항(V2 렌더 이상)과 BATCH_CROPS 문항에만 돌린다.
  /// 원본 대조 수정안 → 반영 대기 값으로 V2 재렌더·원본 재대조(최대 2회) → 정합성 점검 → 메타 보충.
  Future<void> _finish(List<_Mid> mids) async {
    _usePdfium();
    final picked = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    final rerun = _valueText == 'rerun';
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final ids = mid.targetIds;
      final targets = {
        for (final it in mid.all)
          if (ids.contains(it.cropId) &&
              (picked.contains(it.cropId) || (!rerun && it.readyBlockers.contains('V2 렌더 이상'))))
            it.cropId,
      };
      print('${mid.key}: 이어서 마무리 ${targets.length}문항');
      if (targets.isEmpty) continue;
      final pipeline = TextbookReviewPipeline(
        service: review,
        scope: mid.scope,
        matches: (it) => targets.contains(it.cropId),
        onProgress: (m) => print('  ${mid.key} $m'),
      );
      final summary = await pipeline.runAll(forceRerun: rerun);
      for (final n in summary.notes) {
        print('  ${mid.key} $n');
      }
      for (final e in summary.errors) {
        print('  ${mid.key} 오류: $e');
      }
      for (final it in pipeline.items) {
        rows.add(_renderRow(mid, it));
      }
      out[mid.key] = {'notes': summary.notes, 'errors': summary.errors};
    }
    out['items'] = rows;
  }

  /// 고른 소단원의 정답·해설 위치를 앱 2단계와 같은 경로로 다시 찾는다(소단원 전체).
  Future<void> _match(List<_Mid> mids) async {
    _usePdfium();
    final stage = TextbookStageBatchService(supabase: db);
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      for (final wf in mid.workflows) {
        final order = wf.workOrder!;
        for (final r in order.stageRuns) {
          final label = '${mid.key} ${wf.scopeKey} ${r.subKey}';
          try {
            final res = await stage.runStage23ForSubunit(
              academyId: order.academyId,
              bookId: order.bookId,
              gradeLabel: order.gradeLabel,
              bigOrder: order.bigOrder,
              midOrder: order.midOrder,
              subKey: r.subKey,
              subIndex: r.subIndex,
              seriesKey: order.seriesKey,
              answerStartPage: r.answerStartPage,
              answerEndPage: r.answerEndPage,
              solutionStartPage: r.solutionStartPage,
              solutionEndPage: r.solutionEndPage,
              bodyPageFrom: r.bodyPageFrom,
              bodyPageTo: r.bodyPageTo,
              onStatus: (s) {
                if (s.contains('머리') || s.contains('실패')) print('  $s');
              },
            );
            print('$label 정답 ${res.answerSaved} · 해설 위치 ${res.solutionRefSaved}'
                '${res.answerMissing.isEmpty ? '' : ' · 정답 못 찾음 ${res.answerMissing.join(', ')}'}'
                '${res.solutionMissing.isEmpty ? '' : ' · 해설 못 찾음 ${res.solutionMissing.join(', ')}'}');
            rows.add({
              'scope': label,
              'answers': res.answerSaved,
              'solution_refs': res.solutionRefSaved,
              'answer_missing': res.answerMissing,
              'solution_missing': res.solutionMissing,
            });
          } catch (e) {
            print('$label 실패: $e');
            rows.add({'scope': label, 'error': '$e'});
          }
        }
      }
    }
    out['match'] = rows;
  }

  /// BATCH_CROPS 로 고른 문항 하나
  Future<(_Mid, TextbookProblemReviewItem)> _one(List<_Mid> mids) async {
    final crops = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    if (crops.length != 1) fail('BATCH_CROPS 에 크롭 id 하나를 주세요.');
    for (final mid in mids) {
      await _load(mid);
      for (final it in mid.all) {
        if (crops.contains(it.cropId)) return (mid, it);
      }
    }
    fail('문항을 찾지 못했습니다: ${crops.first}');
  }

  Future<void> _answer(List<_Mid> mids) async {
    final value = _valueText;
    if (value.isEmpty) fail('BATCH_VALUE(정답)가 비어 있습니다.');
    final (mid, it) = await _one(mids);
    final changed = await review.stageChanges(
      cropId: it.cropId,
      patch: {'answer': value},
      source: 'owner',
      note: '사장님 수정',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 정답 반영 대기: $value · 바뀜 ${changed.join(', ')}');
    out['answer'] = {'mid': mid.key, 'crop_id': it.cropId, 'before': it.existingAnswer, 'answer': value, 'changed': changed};
  }

  /// BATCH_VALUE=`종류:쪽`(종류는 body·sol, 쪽은 PDF 쪽 번호) 한 쪽 전체를 PNG 로 남긴다(쓰기 없음).
  Future<void> _page(List<_Mid> mids) async {
    final parts = _valueText.split(':');
    final rawPage = parts.length == 2 ? int.tryParse(parts[1].trim()) : null;
    if (rawPage == null || mids.isEmpty) fail('BATCH_VALUE 는 종류:쪽(예: sol:32)이고 BATCH_ONLY 로 학년을 고릅니다.');
    _usePdfium();
    final scope = mids.first.scope;
    final images = TextbookReviewSolutionImageService();
    final kind = parts[0].trim();
    await images.ensureSourcePdf(academyId: _academyId, bookId: _bookId, gradeLabel: scope.gradeLabel, sourceKind: kind);
    final shot = await images.renderFullPage(
      academyId: _academyId,
      bookId: _bookId,
      gradeLabel: scope.gradeLabel,
      sourceKind: kind,
      rawPage: rawPage,
      targetWidthPx: 2000,
    );
    if (shot == null) fail('$kind $rawPage쪽을 찍지 못했습니다.');
    final dir = Directory(p.join('build', 'textbook_batch', 'snap'))..createSync(recursive: true);
    final file = File(p.join(dir.path, '${scope.gradeLabel}_${kind}_p$rawPage.png'))..writeAsBytesSync(shot.bytes);
    print(file.path);
  }

  /// 해설 지면 구조 판독 결과를 그대로 보여 준다(저장 없음). BATCH_VALUE: `시작쪽-끝쪽`
  Future<void> _solBlocks(List<_Mid> mids) async {
    final spec = _valueText.split('@');
    final width = spec.length > 1 ? int.parse(spec[1].trim()) : 1800;
    final parts = [for (final x in spec.first.split('-')) int.tryParse(x.trim())];
    if (parts.isEmpty || parts.any((x) => x == null) || mids.isEmpty) fail('BATCH_VALUE 는 시작쪽-끝쪽 입니다.');
    _usePdfium();
    final scope = mids.first.scope;
    final images = TextbookReviewSolutionImageService();
    await images.ensureSourcePdf(academyId: _academyId, bookId: _bookId, gradeLabel: scope.gradeLabel, sourceKind: 'sol');
    final refs = TextbookVlmSolutionRefService();
    final rows = <Map<String, dynamic>>[];
    for (var page = parts.first!; page <= parts.last!; page += 1) {
      final shot = await images.renderFullPage(
        academyId: _academyId,
        bookId: _bookId,
        gradeLabel: scope.gradeLabel,
        sourceKind: 'sol',
        rawPage: page,
        targetWidthPx: width,
      );
      if (shot == null) fail('sol $page쪽을 찍지 못했습니다.');
      final res = await refs.detectBlocksOnPage(imageBytes: shot.bytes, rawPage: page);
      final line = [
        for (final e in res.sequence)
          e.isHeader ? '[${e.title} p.${e.pageStart}~${e.pageEnd}]' : e.text,
      ].join(' ');
      print('p$page 이어짐=${res.leadingContinuation} $line');
      rows.add({'page': page, 'leading': res.leadingContinuation, 'sequence': line});
    }
    out['sol_blocks'] = rows;
  }

  /// 해설 위치를 사람이 고친 값으로 저장한다(작업 화면의 해설 위치 다시 지정과 같다).
  /// BATCH_VALUE 한 줄: `crop id|해설 쪽|번호 영역 위,왼,아래,오|본문 영역 위,왼,아래,오`
  Future<void> _solref(List<_Mid> mids) async {
    List<int> box(String s) => [for (final x in s.split(',')) int.parse(x.trim())];
    final refs = [
      for (final line in _valueText.split('\n'))
        if (line.trim().isNotEmpty)
          () {
            final f = line.trim().split('|');
            if (f.length != 4) fail('줄 형식이 틀렸습니다: $line');
            final page = int.parse(f[1].trim());
            return TextbookSolutionRefUpload(
              cropId: f[0].trim(),
              rawPage: page,
              displayPage: page,
              numberRegion1k: box(f[2]),
              contentRegion1k: box(f[3]),
              source: 'manual',
            );
          }(),
    ];
    if (refs.isEmpty) fail('BATCH_VALUE 가 비어 있습니다.');
    for (final m in mids) {
      await _load(m);
    }
    final known = {for (final m in mids) for (final id in m.targetIds) id};
    final unknown = [for (final r in refs) if (!known.contains(r.cropId)) r.cropId];
    if (unknown.isNotEmpty) fail('BATCH_ONLY 범위에 없는 문항: ${unknown.join(', ')}');
    final n = await TextbookVlmSolutionRefService().batchUpsertSolutionRefs(academyId: _academyId, refs: refs);
    print('해설 위치 저장 $n건');
    out['solref'] = [for (final r in refs) r.toJson()];
  }

  /// BATCH_CROPS 문항의 해설 그림을 지금 해설 위치에서 다시 찾고(해설 위치를 고친 뒤) V2 렌더를 다시 대조한다.
  Future<void> _solfig(List<_Mid> mids) async {
    _usePdfium();
    final picked = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final targets = [for (final it in mid.all) if (mid.targetIds.contains(it.cropId) && picked.contains(it.cropId)) it];
      if (targets.isEmpty) continue;
      await review.ensureSourcePdfs(mid.scope, targets);
      final res = await review.extractSolutionFigures(mid.scope, targets);
      for (final e in res.errors) {
        print('  ${mid.key} 오류: $e');
      }
      print('${mid.key}: 해설 그림 다시 찾기 ${targets.length}문항 · 그림 있음 ${res.withFigures.length}');
      final ids = {for (final it in targets) it.cropId};
      final pipeline = TextbookReviewPipeline(
        service: review,
        scope: mid.scope,
        matches: (it) => ids.contains(it.cropId),
        onProgress: (m) => print('  ${mid.key} $m'),
      );
      await pipeline.recheckRender();
      for (final it in pipeline.items) {
        rows.add(_renderRow(mid, it));
      }
    }
    out['items'] = rows;
  }

  /// BATCH_CROPS 문항의 해설 그림 폭만 지금 규칙으로 다시 계산하고(AI·다시 자르기 없음), 바뀐 문항만 V2 렌더를 다시 대조한다.
  Future<void> _solfigWidth(List<_Mid> mids) async {
    final picked = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    if (picked.isEmpty) fail('BATCH_CROPS 가 비어 있습니다.');
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final targets = [for (final it in mid.all) if (mid.targetIds.contains(it.cropId) && picked.contains(it.cropId)) it];
      if (targets.isEmpty) continue;
      final ids = <String>{};
      for (final it in targets) {
        final before = [for (final a in it.solutionFigureAssets) a['width_em']];
        final res = await review.recomputeSolutionFigureWidthsOf(it);
        if (res.changed > 0) ids.add(it.cropId);
        print('  ${mid.key} ${it.problemNumber}번: 그림 ${before.length} · 폭 바꿈 ${res.changed} · 둠 ${res.kept} · 이전 폭 $before');
      }
      print('${mid.key}: 해설 그림 폭 다시 계산 ${targets.length}문항 · 바뀐 문항 ${ids.length}');
      if (ids.isEmpty) continue;
      _usePdfium();
      final pipeline = TextbookReviewPipeline(
        service: review,
        scope: mid.scope,
        matches: (it) => ids.contains(it.cropId),
        onProgress: (m) => print('  ${mid.key} $m'),
      );
      await pipeline.recheckRender();
      for (final it in pipeline.items) {
        rows.add({
          ..._renderRow(mid, it),
          'width_em': [for (final a in it.solutionFigureAssets) a['width_em']],
        });
        print('  ${mid.key} ${it.problemNumber}번: 새 폭 ${[for (final a in it.solutionFigureAssets) a['width_em']]}');
      }
    }
    out['items'] = rows;
  }

  Future<void> _solfigArrange(List<_Mid> mids) async {
    final picked = {for (final c in _crops.split(',')) if (c.trim().isNotEmpty) c.trim()};
    if (picked.isEmpty) fail('BATCH_CROPS 가 비어 있습니다.');
    final decoded = _valueText.trim().isEmpty ? const <String, dynamic>{} : jsonDecode(_valueText);
    if (decoded is! Map) fail('BATCH_VALUE 는 {"<crop id>": {"<그림 순번>": {...}}} JSON 입니다.');
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final targets = [for (final it in mid.all) if (mid.targetIds.contains(it.cropId) && picked.contains(it.cropId)) it];
      if (targets.isEmpty) continue;
      var changed = 0;
      for (final it in targets) {
        final raw = decoded[it.cropId];
        final overrides = <int, Map<String, dynamic>>{
          if (raw is Map)
            for (final e in raw.entries)
              if (int.tryParse('${e.key}') != null && e.value is Map) int.parse('${e.key}'): Map<String, dynamic>.from(e.value as Map),
        };
        if (await review.rearrangeSolutionFigures(it, overrides: overrides)) changed++;
      }
      print('${mid.key}: 해설 그림 정렬 다시 계산 ${targets.length}문항 · 바뀜 $changed');
      _usePdfium();
      final ids = {for (final it in targets) it.cropId};
      final pipeline = TextbookReviewPipeline(
        service: review,
        scope: mid.scope,
        matches: (it) => ids.contains(it.cropId),
        onProgress: (m) => print('  ${mid.key} $m'),
      );
      await pipeline.recheckRender();
      for (final it in pipeline.items) {
        rows.add(_renderRow(mid, it));
      }
    }
    out['items'] = rows;
  }

  Future<void> _solfigRecrop(List<_Mid> mids) async {
    final parts = _valueText.trim().split('|');
    final box = parts.length == 2 ? [for (final x in parts[1].split(',')) int.tryParse(x.trim())] : const <int?>[];
    final index = parts.isEmpty ? null : int.tryParse(parts[0].trim());
    if (index == null || box.length != 4 || box.contains(null)) fail('BATCH_VALUE 는 그림 순번|위,왼,아래,오(해설 쪽 0~1000)입니다.');
    final (mid, it) = await _one(mids);
    final region = [for (final x in box) x!];
    _usePdfium();
    await review.ensureSourcePdfs(mid.scope, [it]);
    await review.recropSolutionFigure(mid.scope, it, index, region);
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 해설 그림 ${index + 1} 다시 자름 $region');
    final pipeline = TextbookReviewPipeline(
      service: review,
      scope: mid.scope,
      matches: (x) => x.cropId == it.cropId,
      onProgress: (m) => print('  ${mid.key} $m'),
    );
    await pipeline.recheckRender();
    out['items'] = [for (final x in pipeline.items) _renderRow(mid, x)];
  }

  Future<void> _solfigDrop(List<_Mid> mids) async {
    final index = int.tryParse(_valueText.trim());
    if (index == null) fail('BATCH_VALUE 는 뺄 해설 그림 순번(0부터)입니다.');
    _usePdfium();
    final (mid, it) = await _one(mids);
    if (index < 0 || index >= it.solutionFigureAssets.length) {
      fail('해설 그림은 ${it.solutionFigureAssets.length}개입니다.');
    }
    final rest = [
      for (var k = 0; k < it.solutionFigureAssets.length; k++)
        if (k != index) it.solutionFigureAssets[k],
    ];
    await db.rpc('textbook_review_set_solution_figures', params: {
      'p_crop_id': it.cropId,
      'p_assets': arrangeSolutionFigures(rest, it.solutionSegments),
    });
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 해설 그림 ${index + 1} 뺌 (남은 ${rest.length}개)');
    final pipeline = TextbookReviewPipeline(
      service: review,
      scope: mid.scope,
      matches: (x) => x.cropId == it.cropId,
      onProgress: (m) => print('  ${mid.key} $m'),
    );
    await pipeline.recheckRender();
    out['items'] = [for (final x in pipeline.items) _renderRow(mid, x)];
  }

  Future<void> _stem(List<_Mid> mids) async {
    final value = _valueText;
    if (value.trim().isEmpty) fail('BATCH_VALUE(본문)가 비어 있습니다.');
    final (mid, it) = await _one(mids);
    final changed = await review.stageChanges(
      cropId: it.cropId,
      patch: {'stem': value},
      source: 'owner',
      note: '사장님 수정',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 본문 반영 대기 · 바뀜 ${changed.join(', ')}');
    out['stem'] = {'mid': mid.key, 'crop_id': it.cropId, 'before': it.stem, 'stem': value, 'changed': changed};
  }

  Future<void> _layout(List<_Mid> mids) async {
    final decoded = jsonDecode(_valueText);
    if (decoded is! Map || decoded['items'] is! List) fail('BATCH_VALUE 는 figure_layout JSON({"version":1,"items":[...]})입니다.');
    final (mid, it) = await _one(mids);
    final changed = await review.stageChanges(
      cropId: it.cropId,
      patch: {'figure_layout': decoded},
      source: 'owner',
      note: '사장님 수정',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 그림 배치 반영 대기 · 바뀜 ${changed.join(', ')}');
    out['layout'] = {'mid': mid.key, 'crop_id': it.cropId, 'layout': decoded, 'changed': changed};
  }

  Future<void> _solution(List<_Mid> mids) async {
    final value = _valueText;
    if (value.trim().isEmpty) fail('BATCH_VALUE(해설)가 비어 있습니다.');
    final (mid, it) = await _one(mids);
    final changed = await review.stageChanges(
      cropId: it.cropId,
      patch: {'solution_transcribed': value},
      source: 'owner',
      note: '사장님 수정',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 해설 반영 대기 · 바뀜 ${changed.join(', ')}');
    out['solution'] = {
      'mid': mid.key,
      'crop_id': it.cropId,
      'before': it.solutionTranscribed,
      'solution': value,
      'changed': changed,
    };
  }

  Future<void> _recrop(List<_Mid> mids) async {
    final box = [for (final x in _valueText.split(',')) if (int.tryParse(x.trim()) != null) int.parse(x.trim())];
    if (box.length != 4) fail('BATCH_VALUE 는 위,왼쪽,아래,오른쪽(0~1000) 네 수입니다.');
    _usePdfium();
    final (mid, it) = await _one(mids);
    final orig = await review.originalImage(mid.scope, it);
    if (orig == null) fail('원본 문항을 찍지 못했습니다.');
    final page = cropBoxToPageRegion(orig.region1k, box, margin: 0);
    if (page == null) fail('영역이 올바르지 않습니다: $box');
    // cropAndUploadFigures 는 수정 단계에 보낸 원본 영역(있으면)을 기준으로 받고 바깥 여백 12 를 붙인다.
    final measure = it.fixProposal['figure_measure'];
    final measured = [
      for (final x in (measure is Map && measure['region_1k'] is List ? measure['region_1k'] as List : const []))
        if (x is num) x.toInt(),
    ];
    final base = measured.length == 4 ? measured : orig.region1k;
    int rel(int v, int from, int to) => ((v - from) * 1000 / (to - from)).round();
    final relBox = [
      rel(page[0], base[0], base[2]) + 12,
      rel(page[1], base[1], base[3]) + 12,
      rel(page[2], base[0], base[2]) - 12,
      rel(page[3], base[1], base[3]) - 12,
    ];
    final added = await review.cropAndUploadFigures(scope: mid.scope, item: it, crops: [
      {'figure_index': 1, 'bbox_1k': relBox},
    ]);
    if (added.isEmpty) fail('그림을 잘라 올리지 못했습니다.');
    final changed = await review.stageProblemFix(
      scope: mid.scope,
      item: it,
      figureAssets: [
        for (final a in it.pbFigureAssets)
          if ('${a['figure_index']}' != '1') a,
        for (final a in added) {...a, 'keep_margins': true},
      ],
      source: 'owner',
      note: '사장님 수정: 그림 다시 자르기',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 그림 1 다시 자름: 원본 ${orig.region1k} 의 $box → 지면 $page'
        ' · 바뀜 ${changed.join(', ')}');
    out['recrop'] = {'mid': mid.key, 'crop_id': it.cropId, 'box': box, 'page_region_1k': page, 'changed': changed};
  }

  Future<void> _pbFigureWidth(List<_Mid> mids) async {
    final width = double.tryParse(_valueText);
    if (width == null || width <= 0) fail('BATCH_VALUE 는 그림 폭(em)입니다.');
    final (mid, it) = await _one(mids);
    if (it.pbQuestionId.isEmpty) fail('문제은행 문항이 없습니다.');
    final row = await db.from('pb_questions').select('document_id, meta').eq('id', it.pbQuestionId).single();
    final meta = Map<String, dynamic>.from(row['meta'] as Map);
    final layout = meta['figure_layout'] is Map ? Map<String, dynamic>.from(meta['figure_layout'] as Map) : null;
    final items = [
      for (final x in (layout != null && layout['items'] is List ? layout['items'] as List : const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];
    final i = items.indexWhere((x) => x['assetKey'] == 'idx:1');
    if (layout == null || i < 0) fail('그림 1 배치가 없습니다.');
    final before = items[i]['widthEm'];
    items[i]['widthEm'] = width;
    meta['figure_layout'] = {...layout, 'items': items};
    await pb.updateQuestionMeta(questionId: it.pbQuestionId, meta: meta);
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 문제은행 그림 1 폭: $before → $width em');

    List<String> paths(Object? assets) => [
          for (final a in (assets is List ? assets : const []))
            if (a is Map) '${a['path'] ?? ''}',
        ];
    final mine = paths(meta['figure_assets']);
    final set = <Map<String, dynamic>>[];
    for (final r in await db.from('pb_questions').select('question_number, meta').eq('document_id', '${row['document_id']}')) {
      final sm = r['meta'] is Map ? (r['meta'] as Map)['set_model'] : null;
      if (sm is! Map || mine.isEmpty || paths(sm['common_figure_assets']).join('|') != mine.join('|')) continue;
      set.add({'number': r['question_number'], 'common_figure_layout': sm['common_figure_layout']});
      print('  세트 ${r['question_number']}번 공통 그림 배치: ${jsonEncode(sm['common_figure_layout'])}');
    }
    out['pb_figure_width'] = {'mid': mid.key, 'crop_id': it.cropId, 'before': before, 'width_em': width, 'set': set};
  }

  /// 문항 그림 하나를 뺀다('해' 풀이 안내 그림이 문항 그림으로 잡힌 경우). BATCH_VALUE: 뺄 그림 번호(1부터)
  Future<void> _figDrop(List<_Mid> mids) async {
    final drop = int.tryParse(_valueText.trim());
    if (drop == null || drop < 1) fail('BATCH_VALUE 는 뺄 그림 번호(1부터)입니다.');
    final (mid, it) = await _one(mids);
    final assets = [for (final a in it.pbFigureAssets) Map<String, dynamic>.from(a)]
      ..sort((a, b) => '${a['figure_index']}'.compareTo('${b['figure_index']}'));
    if (drop > assets.length || assets.length < 2) fail('그림이 ${assets.length}개라 $drop번을 뺄 수 없습니다.');
    int renum(int i) => i > drop ? i - 1 : i;
    final kept = [
      for (final a in assets)
        if ((a['figure_index'] as num?)?.toInt() != drop)
          {...a, 'figure_index': renum((a['figure_index'] as num).toInt())},
    ];
    final layout = Map<String, dynamic>.from(it.pbFigureLayout);
    final items = <Map<String, dynamic>>[];
    for (final x in (layout['items'] is List ? layout['items'] as List : const [])) {
      if (x is! Map) continue;
      final m = RegExp(r'^idx:(\d+)$').firstMatch('${x['assetKey']}');
      final idx = m == null ? null : int.parse(m.group(1)!);
      if (idx == drop) continue;
      items.add({...Map<String, dynamic>.from(x), if (idx != null) 'assetKey': 'idx:${renum(idx)}'});
    }
    final changed = await review.stageProblemFix(
      scope: mid.scope,
      item: it,
      figureAssets: kept,
      figureLayout: {...layout, 'items': items, 'groups': const [], 'horizontalPairs': const []},
      source: 'owner',
      note: '풀이 안내 그림 제외',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 그림 $drop 제외 · 남은 ${kept.length}개 · 바뀜 ${changed.join(', ')}');
    out['fig_drop'] = {'mid': mid.key, 'crop_id': it.cropId, 'dropped': drop, 'changed': changed};
  }

  /// 사장님이 준 그림 파일로 문항 그림을 바꿔 반영 대기에 넣는다(작업 화면의 "N번 그림 직접 올리기"와 같은 저장소·출처).
  /// BATCH_VALUE: 줄마다 `그림 번호=파일 경로`. `bogi2` 줄이 있으면 보기 2단도 함께 넣는다.
  Future<void> _figUpload(List<_Mid> mids) async {
    final files = <int, String>{};
    var bogi2 = false;
    for (final raw in _valueText.split(RegExp(r'[\r\n;]+'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line == 'bogi2') {
        bogi2 = true;
        continue;
      }
      final cut = line.indexOf('=');
      final index = cut > 0 ? int.tryParse(line.substring(0, cut).trim()) : null;
      if (index == null || index < 1) fail('BATCH_VALUE 줄은 그림 번호=파일 경로 입니다: $line');
      files[index] = line.substring(cut + 1).trim();
    }
    if (files.isEmpty) fail('BATCH_VALUE 에 그림 번호=파일 경로 줄이 없습니다.');
    final (mid, it) = await _one(mids);
    final stagedAssets = it.stagedChanges['figure_assets'];
    final assets = <Map<String, dynamic>>[
      for (final a in (stagedAssets is List ? stagedAssets : it.pbFigureAssets))
        if (a is Map && !files.containsKey(int.tryParse('${a['figure_index']}'))) Map<String, dynamic>.from(a),
    ];
    for (final e in files.entries) {
      final file = File(e.value);
      if (!file.existsSync()) fail('파일이 없습니다: ${e.value}');
      final asset = await pb.uploadManualFigureAsset(
        academyId: mid.scope.academyId,
        documentId: it.documentId,
        questionNumber: it.problemNumber,
        bytes: file.readAsBytesSync(),
        fileName: p.basename(e.value),
      );
      assets.add({...asset, 'figure_index': e.key});
    }
    assets.sort((a, b) => (int.tryParse('${a['figure_index']}') ?? 0).compareTo(int.tryParse('${b['figure_index']}') ?? 0));
    final stagedLayout = it.stagedChanges['figure_layout'];
    final layout = Map<String, dynamic>.from(stagedLayout is Map ? stagedLayout : it.pbFigureLayout);
    final missing = [
      for (final i in files.keys)
        if (!(layout['items'] is List && (layout['items'] as List).any((x) => x is Map && '${x['assetKey']}' == 'idx:$i'))) i,
    ];
    if (missing.isNotEmpty) fail('그림 배치에 없는 번호: ${missing.join(', ')}');
    final changed = await review.stageProblemFix(
      scope: mid.scope,
      item: it,
      figureAssets: assets,
      figureLayout: bogi2 ? {...layout, 'bogiColumns': 2} : null,
      source: 'owner',
      note: '그림 직접 올림(${files.keys.join(', ')}번)',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 그림 ${files.keys.join(', ')} 교체${bogi2 ? ' · 보기 2단' : ''} · 바뀜 ${changed.join(', ')}');
    out['fig_upload'] = {'mid': mid.key, 'crop_id': it.cropId, 'figures': files.keys.toList(), 'bogi2': bogi2, 'changed': changed};
  }

  /// 사장님 판정으로 교정 의견을 처리하고 해설 논리 오류 지적을 닫는다. BATCH_VALUE: adopt(교재 오류로 확인) | dismiss(기각)
  Future<void> _note(List<_Mid> mids) async {
    final value = _valueText.trim();
    if (value != 'adopt' && value != 'dismiss') fail('BATCH_VALUE 는 adopt 또는 dismiss 입니다.');
    final (mid, it) = await _one(mids);
    final notes = it.openCorrectionNotes;
    for (final f in notes) {
      await review.closeCorrectionNote(findingId: '${f['id']}', dismiss: value == 'dismiss', note: '사장님 판정');
    }
    final logic = it.openSolutionLogicFinding != null;
    await review.stageChanges(cropId: it.cropId, source: 'owner', note: '사장님 판정', mathStatus: 'clean');
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 교정 의견 ${notes.length}건 ${value == 'adopt' ? '채택' : '기각'}'
        '${logic ? ' · 해설 논리 오류 지적 닫음' : ''}');
    out['note'] = {'mid': mid.key, 'crop_id': it.cropId, 'notes': notes.length, 'action': value, 'logic_closed': logic};
  }

  /// 해설 오류를 사장님 판정으로 처리한다. BATCH_VALUE: 교정한 해설 전문(@파일) | keep(교재 그대로 둠)
  /// 교정하면 교정 전 원본 해설을 따로 남긴다(확정 때 원본·교정본 둘 다 저장).
  Future<void> _solCorrect(List<_Mid> mids) async {
    final value = _valueText;
    if (value.trim().isEmpty) fail('BATCH_VALUE 는 교정한 해설 전문(@파일) 또는 keep 입니다.');
    final keep = value.trim() == 'keep';
    final (mid, it) = await _one(mids);
    await review.closeSolutionLogic(cropId: it.cropId, correctedSolution: keep ? null : value);
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 해설 ${keep ? '그대로 둠' : '교정(원본 해설 따로 남김)'}');
    out['sol_correct'] = {'mid': mid.key, 'crop_id': it.cropId, 'keep': keep, 'before': it.solutionTranscribed};
  }

  /// 본문 아래 문항 그림의 정렬을 바꾼다. BATCH_VALUE: left | center | right
  Future<void> _figAnchor(List<_Mid> mids) async {
    final anchor = _valueText.trim();
    if (!const {'left', 'center', 'right'}.contains(anchor)) fail('BATCH_VALUE 는 left, center, right 중 하나입니다.');
    final (mid, it) = await _one(mids);
    final layout = Map<String, dynamic>.from(it.pbFigureLayout);
    final items = [
      for (final x in (layout['items'] is List ? layout['items'] as List : const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];
    if (items.isEmpty) fail('그림 배치가 없습니다.');
    final before = [for (final x in items) '${x['position']}/${x['anchor']}'];
    for (final x in items) {
      if ('${x['position'] ?? 'below-stem'}' == 'below-stem') x['anchor'] = anchor;
    }
    final changed = await review.stageChanges(
      cropId: it.cropId,
      patch: {
        'figure_layout': {...layout, 'items': items},
      },
      source: 'owner',
      note: '그림 정렬을 원본에 맞춤',
    );
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 그림 정렬 ${before.join(', ')} → $anchor · 바뀜 ${changed.join(', ')}');
    out['fig_anchor'] = {'mid': mid.key, 'crop_id': it.cropId, 'before': before, 'anchor': anchor, 'changed': changed};
  }

  Future<void> _pbChoiceRows(List<_Mid> mids) async {
    final rows = _valueText.trim();
    if (rows != '2' && rows != '3') fail('BATCH_VALUE 는 그림 선지 줄 수(2 또는 3)입니다.');
    final (mid, it) = await _one(mids);
    if (it.pbQuestionId.isEmpty) fail('문제은행 문항이 없습니다.');
    final row = await db.from('pb_questions').select('meta, choices').eq('id', it.pbQuestionId).single();
    final meta = Map<String, dynamic>.from(row['meta'] as Map);
    final choices = row['choices'] is List ? row['choices'] as List : const [];
    final allFigures = choices.length == 5 &&
        choices.every((c) => c is Map && RegExp(r'^\s*\[(?:그림|도형|도표)\]\s*$').hasMatch('${c['text'] ?? ''}'));
    if (!allFigures) fail('선지 다섯 개가 모두 그림인 문항이 아닙니다.');
    final before = meta['image_choice_layout'];
    meta['is_image_choice_question'] = true;
    meta['choice_layout'] = 'image_table';
    meta['image_choice_count'] = 5;
    meta['image_choice_layout'] = <String, dynamic>{'version': 1, 'rows': rows};
    await pb.updateQuestionMeta(questionId: it.pbQuestionId, meta: meta);
    print('${mid.key} p.${it.displayPage} ${it.problemNumber}번 그림 선지 줄 수: ${jsonEncode(before)} → $rows');
    out['pb_choice_rows'] = {'mid': mid.key, 'crop_id': it.cropId, 'before': before, 'rows': rows};
  }

  /// 교재 메뉴의 일괄 확정과 같은 순서: 준비됨 확인 → 확정 직전 정합성 점검 → 수정안 일괄 반영 → 확정 표시.
  Future<void> _reconfirm(List<_Mid> mids) async {
    final done = <String>[];
    final problems = <String>[];
    for (final mid in mids) {
      var stale = true;
      for (final wf in mid.workflows) {
        final label = '${mid.key} ${wf.scopeKey}';
        try {
          if (stale) await _load(mid);
          stale = false;
          final items = mid.itemsOf(wf);
          final ready = items.where((x) => x.isWorkflowReady).length;
          if (items.isEmpty || ready < items.length) {
            problems.add('$label: 준비됨 $ready/${items.length}');
            print('$label 건너뜀: 준비됨 $ready/${items.length}');
            continue;
          }
          final order = wf.workOrder!;
          final stop = await review.consistencyGateForConfirm(order.reviewScope, items);
          if (stop != null) {
            stale = true;
            problems.add('$label: $stop');
            print('$label 건너뜀: $stop');
            continue;
          }
          final applied = await review.applyForConfirm(items);
          stale = true;
          problems.addAll([for (final e in applied.errors) '$label: $e']);
          await workflows.confirmSubunit(wf, confirmed: true);
          await registry.setScopeConfirmed(
            academyId: wf.academyId,
            bookId: wf.bookId,
            gradeLabel: wf.gradeLabel,
            scopeKey: wf.stateKey,
            confirmed: true,
          );
          done.add(label);
          print('$label 확정 · ${items.length}문항'
              '${applied.applied > 0 ? ' · 수정안 ${applied.applied}문항 반영' : ''}'
              '${applied.generated > 0 ? ' · 객관식 보기 ${applied.generated}문항 생성' : ''}');
        } catch (e) {
          stale = true;
          problems.add('$label: $e');
          print('$label 실패: $e');
        }
      }
    }
    out['done'] = done;
    out['problems'] = problems;
    print('다시 확정 ${done.length}개 · 못 함 ${problems.length}건');
  }
}
