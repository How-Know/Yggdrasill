// 수력충전 1-1·1-2 운영 스크립트: 새 흐름으로 확정한 소단원에 코드 정합성 점검과 메타 보충을 돌리고 다시 확정한다.
// 매니저앱 서비스를 그대로 써서 앱과 같은 경로·기준(준비됨 판정, 확정 직전 정합성 점검, 일괄 반영)으로 돈다.
// 화면 없이 돌리려고 flutter test 로 실행한다. 로그인은 `tool/textbook_batch.ps1 login`(메일 인증번호).
//
//   flutter test tool/textbook_batch.dart -r expanded --dart-define=BATCH_STEP=<단계> [--dart-define=BATCH_ONLY=1-1/0-0,1-2/0-1/W5]
// BATCH_ONLY 는 중단원(학년/대-중) 또는 소단원(학년/대-중/작업 키)을 쉼표로 고른다.
//
// 단계
//   send_otp, verify_otp  로그인(BATCH_EMAIL 필수, BATCH_OTP). 세션은 저장소 밖 %LOCALAPPDATA%\Yggdrasill 에 둔다.
//   status       소단원별 준비됨 수와 막힌 이유
//   preview      정합성 점검 미리보기(아무것도 쓰지 않는다)
//   consistency  정합성 점검(수정안·지적을 저장)
//   meta         정합성 점검 + 메타 보충(AI). 앱의 "메타 보충"과 같다
//   dismiss      사장님이 "문제 없음"으로 정한 문항(BATCH_CROPS, 크롭 id 쉼표 구분)의 정합성 지적을 닫는다
//   render       V2 렌더 이상이 남은 문항과 BATCH_CROPS 문항을 다시 검수한다(작업 화면의 "V2 렌더 검수 다시"). 교재 원본을
//                찍으려고 매니저앱 Windows 빌드 폴더의 pdfium 을 쓴다(그 폴더를 PATH 에 넣고 실행한다)
//   snapshot     BATCH_CROPS 문항의 V2 문항 카드·정답 해설 카드·교재 원본을 build/textbook_batch/snap 에 PNG 로 남긴다(쓰기 없음).
//                BATCH_VALUE 가 있으면 그 줄마다 그 정답으로 정답 카드를 더 찍는다(정답 표기 비교)
// 사장님이 승인한 문항 하나(BATCH_CROPS)를 고치는 단계. 값은 BATCH_VALUE(`@경로`면 그 UTF-8 파일 내용)
//   answer          정답을 사장님 수정으로 반영 대기에 넣는다(작업 화면의 정답 저장과 같다)
//   recrop          그림 1을 원본에서 다시 잘라 반영 대기에 넣는다. 값은 snapshot 의 _original.png 기준 위,왼쪽,아래,오른쪽(0~1000).
//                   자른 영역의 빈칸도 원본 모양이라 엔진이 흰 여백을 자르지 않게 keep_margins 를 붙인다
//   pb_figure_width 문제은행의 그림 1 폭(em)을 바로 고친다(문제은행 화면의 그림 크기 편집과 같다, 확정을 거치지 않는다)
//   reconfirm    모든 카드가 준비됨인 소단원을 다시 확정(수정안 일괄 반영)
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
import 'package:yggdrasill_manager/services/problem_bank_service.dart';
import 'package:yggdrasill_manager/services/textbook_book_registry.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_review_pipeline.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_service.dart';

const _step = String.fromEnvironment('BATCH_STEP');
const _only = String.fromEnvironment('BATCH_ONLY');
const _email = String.fromEnvironment('BATCH_EMAIL');
const _otp = String.fromEnvironment('BATCH_OTP');
const _crops = String.fromEnvironment('BATCH_CROPS');
const _value = String.fromEnvironment('BATCH_VALUE');

/// 한글 값은 명령줄을 거치며 깨질 수 있어 `@경로`(UTF-8 파일)로도 받는다.
String get _valueText {
  final v = _value.trim();
  return v.startsWith('@') ? File(v.substring(1)).readAsStringSync().trim() : v;
}

const _academyId = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
const _bookId = '09d8c890-a69f-4814-b57d-e16b0bf88432';
const _grades = ['1-1', '1-2'];

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
    final mids = await _loadMids();
    print('대상: 중단원 ${mids.length}개 · 확정한 소단원 ${mids.fold<int>(0, (n, m) => n + m.workflows.length)}개');
    switch (step) {
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
      case 'snapshot':
        await _snapshot(mids);
      case 'answer':
        await _answer(mids);
      case 'recrop':
        await _recrop(mids);
      case 'pb_figure_width':
        await _pbFigureWidth(mids);
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
        if (!wf.isConfirmed) continue;
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
    final rows = <Map<String, dynamic>>[];
    for (final mid in mids) {
      await _load(mid);
      final ids = mid.targetIds;
      final targets = {
        for (final it in mid.all)
          if (ids.contains(it.cropId) && (it.readyBlockers.contains('V2 렌더 이상') || picked.contains(it.cropId)))
            it.cropId,
      };
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
        final rc = it.renderChecks;
        final row = {
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
        rows.add(row);
        print('${mid.key} p.${it.displayPage} ${it.problemNumber}번: '
            '${it.isWorkflowReady ? '준비됨' : '막힘(${it.readyBlockers.join(', ')})'}'
            '${rc['figure_size_ratio'] == null ? '' : ' · 그림 크기 ${rc['figure_size_ratio']}배'}'
            '${rc['issue_title'] == null ? '' : ' · ${rc['issue_title']}'}');
      }
      out[mid.key] = {'errors': pipeline.errors};
    }
    out['items'] = rows;
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
