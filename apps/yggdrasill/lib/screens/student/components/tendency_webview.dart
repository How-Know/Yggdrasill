import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../../models/education_level.dart';
import '../../../models/student.dart';
import '../../../models/student_payment_info.dart';
import '../../../services/app_config.dart';
import '../../../services/data_manager.dart';
import '../../../services/tag_preset_service.dart';
import '../../../widgets/app_snackbar.dart';

// ✅ 학생 탭(앱) 톤과 통일
const Color _bg = Color(0xFF0B1112);
const Color _border = Color(0xFF223131);
const Color _text = Color(0xFFEAF2F2);
const Color _sub = Color(0xFF9FB3B3);

class TendencyWebView extends StatefulWidget {
  final String? studentId;
  const TendencyWebView({super.key, this.studentId});

  @override
  State<TendencyWebView> createState() => _TendencyWebViewState();
}

class _TendencyWebViewState extends State<TendencyWebView> {
  final WebviewController _controller = WebviewController();
  StreamSubscription? _webMessageSub;
  StreamSubscription? _urlSub;
  bool _initialized = false;
  String? _baseUrl;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _controller.initialize();

    // ✅ 앱 안에서는 .env 없이도 설문이 항상 동작하도록 Supabase 설정을 WebView에 주입한다.
    // Survey web은 window.__YGG_SUPABASE_URL / window.__YGG_SUPABASE_ANON_KEY 를 우선 사용한다.
    try {
      await _controller.addScriptToExecuteOnDocumentCreated(
        "try { window.__YGG_SUPABASE_URL = ${jsonEncode(kDefaultSupabaseUrl)}; window.__YGG_SUPABASE_ANON_KEY = ${jsonEncode(kDefaultSupabaseAnonKey)}; } catch(e) {}",
      );
    } catch (_) {
      // ignore
    }
    _webMessageSub?.cancel();
    _webMessageSub = _controller.webMessage.listen((message) async {
      await _handleWebMessage(message);
    });

    // ✅ WebMessage가 환경에 따라 막힐 수 있어, URL hash 브릿지를 함께 사용한다.
    // 웹에서 window.location.hash = "__ygg__<nonce>__<encodedJson>" 로 보내면 여기서 잡는다.
    _urlSub?.cancel();
    _urlSub = _controller.url.listen((u) async {
      try {
        final uri = Uri.tryParse(u);
        final frag = uri?.fragment ?? '';
        if (!frag.startsWith('__ygg__')) return;

        // 형식: "__ygg__<nonce>__<encodedJson>"
        final idx = frag.indexOf('__', '__ygg__'.length);
        if (idx < 0) return;
        final encoded = frag.substring(idx + 2);
        final jsonStr = Uri.decodeComponent(encoded);
        final decoded = jsonDecode(jsonStr);
        await _handleWebMessage(decoded);

        // 처리 후 hash 제거(반복 트리거 방지)
        try {
          await _controller.executeScript(
            "try { history.replaceState(null,'',location.pathname+location.search); } catch(e) {}",
          );
        } catch (_) {}
      } catch (_) {}
    });
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString('survey_base_url') ?? 'http://localhost:5173';
    setState(() {
      _baseUrl = base;
      _initialized = true;
    });
    final sid = widget.studentId ?? '';
    // ✅ 앱에서도 첫 진입은 Landing(기존학생/신규학생 2버튼)으로 통일
    final url = Uri.parse('$base/?theme=dark&sid=$sid').toString();
    await _controller.loadUrl(url);
  }

  String? _digitsOnlyOrNull(String? s) {
    if (s == null) return null;
    final v = s.replaceAll(RegExp(r'[^0-9]'), '').trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _replyToWeb({
    required String requestId,
    required bool ok,
    String? studentId,
    String? error,
  }) async {
    try {
      final payload = jsonEncode({
        'type': 'new_student_result',
        'requestId': requestId,
        'ok': ok,
        'studentId': studentId,
        'error': error,
      });

      // 1) 가능한 경우 WebMessage로 응답
      try {
        await _controller.postWebMessage(payload);
      } catch (_) {
        // ignore
      }
      // 2) ✅ 항상 CustomEvent로도 응답(웹이 이 이벤트를 듣는다)
      final js = "try { window.dispatchEvent(new CustomEvent('ygg_result', { detail: JSON.parse(${jsonEncode(payload)}) })); } catch(e) {}";
      await _controller.executeScript(js);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _progressToWeb(String requestId, String stage) async {
    try {
      final payload = jsonEncode({
        'type': 'new_student_progress',
        'requestId': requestId,
        'stage': stage, // received|saving|done|...
      });
      try {
        await _controller.postWebMessage(payload);
      } catch (_) {}
      final js = "try { window.dispatchEvent(new CustomEvent('ygg_result', { detail: JSON.parse(${jsonEncode(payload)}) })); } catch(e) {}";
      await _controller.executeScript(js);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _handleWebMessage(dynamic message) async {
    // webview_windows 플러그인이 한 번 json.decode를 수행하므로,
    // 웹에서 문자열(JSON.stringify)로 보내면 여기엔 "String"이 들어올 수 있다.
    dynamic msg = message;
    if (msg is String) {
      try {
        msg = jsonDecode(msg);
      } catch (_) {
        return;
      }
    }
    if (msg is! Map) return;
    final type = msg['type'];
    final requestId = (msg['requestId'] ?? '').toString();
    if (requestId.trim().isEmpty) return;

    // ✅ 기존학생 리스트 요청
    if (type == 'existing_students_request') {
      try {
        final students = DataManager.instance.students;
        String levelToStr(EducationLevel lv) {
          switch (lv) {
            case EducationLevel.elementary:
              return 'elementary';
            case EducationLevel.middle:
              return 'middle';
            case EducationLevel.high:
              return 'high';
          }
        }

        String gradeToStr(Student s) {
          if (s.educationLevel == EducationLevel.high && s.grade == 4) return 'N수';
          return s.grade.toString();
        }

        final list = students.map((si) {
          final s = si.student;
          return {
            'id': s.id,
            'name': s.name,
            'school': s.school,
            'level': levelToStr(s.educationLevel),
            'grade': gradeToStr(s),
          };
        }).toList();

        final payload = jsonEncode({
          'type': 'existing_students_result',
          'requestId': requestId,
          'ok': true,
          'students': list,
        });
        // WebMessage(가능하면) + CustomEvent(항상)
        try {
          await _controller.postWebMessage(payload);
        } catch (_) {}
        await _controller.executeScript(
          "try { window.dispatchEvent(new CustomEvent('ygg_result', { detail: JSON.parse(${jsonEncode(payload)}) })); } catch(e) {}",
        );
      } catch (e) {
        final payload = jsonEncode({
          'type': 'existing_students_result',
          'requestId': requestId,
          'ok': false,
          'error': e.toString(),
        });
        try {
          await _controller.postWebMessage(payload);
        } catch (_) {}
        await _controller.executeScript(
          "try { window.dispatchEvent(new CustomEvent('ygg_result', { detail: JSON.parse(${jsonEncode(payload)}) })); } catch(e) {}",
        );
      }
      return;
    }

    if (type != 'new_student_submit') return;

    await _progressToWeb(requestId, 'received');

    try {
      final payloadRaw = msg['payload'];
      if (payloadRaw is! Map) {
        await _replyToWeb(requestId: requestId, ok: false, error: 'payload 형식이 올바르지 않습니다.');
        return;
      }

      final name = (payloadRaw['name'] ?? '').toString().trim();
      final school = (payloadRaw['school'] ?? '').toString().trim();
      final levelStr = (payloadRaw['level'] ?? '').toString().trim();
      final gradeStr = (payloadRaw['grade'] ?? '').toString().trim();
      final studentPhone = _digitsOnlyOrNull(payloadRaw['studentPhone']?.toString());
      final parentPhone = _digitsOnlyOrNull(payloadRaw['parentPhone']?.toString());

      if (name.isEmpty || school.isEmpty || levelStr.isEmpty || gradeStr.isEmpty) {
        await _replyToWeb(requestId: requestId, ok: false, error: '필수 값(name/school/level/grade)이 비어 있습니다.');
        return;
      }

      EducationLevel level;
      switch (levelStr) {
        case 'elementary':
          level = EducationLevel.elementary;
          break;
        case 'middle':
          level = EducationLevel.middle;
          break;
        case 'high':
          level = EducationLevel.high;
          break;
        default:
          await _replyToWeb(requestId: requestId, ok: false, error: '과정(level) 값이 올바르지 않습니다.');
          return;
      }

      int grade;
      if (gradeStr == 'N수') {
        grade = 4; // 앱 내부 규칙(고등 N수 = 4)
      } else {
        grade = int.tryParse(gradeStr) ?? -1;
      }
      if (grade <= 0) {
        await _replyToWeb(requestId: requestId, ok: false, error: '학년(grade) 값이 올바르지 않습니다.');
        return;
      }

      // ✅ 진도/시험/성적은 요약해서 학생 메모(StudentBasicInfo.memo)에 저장
      final List<String> memoLines = <String>['[성향조사 신규등록]'];
      final progress = payloadRaw['progress'];
      if (progress is Map) {
        final cur = (progress['current'] ?? '').toString().trim();
        final prev = (progress['previous'] ?? '').toString().trim();
        if (cur.isNotEmpty || prev.isNotEmpty) {
          memoLines.add('진도: 현재=${cur.isEmpty ? '-' : cur} / 이전=${prev.isEmpty ? '-' : prev}');
        }
      }
      final exam = payloadRaw['exam'];
      if (exam is Map) {
        final book = (exam['book'] ?? '').toString().trim();
        final rate = (exam['approxCorrectRate'] ?? '').toString().trim();
        if (book.isNotEmpty || rate.isNotEmpty) {
          memoLines.add('시험: 교재=${book.isEmpty ? '-' : book} / 정답률≈${rate.isEmpty ? '-' : '$rate%'}');
        }
      }
      final score = payloadRaw['score'];
      if (score is Map) {
        final latest = (score['latest'] ?? '').toString().trim();
        final max4 = (score['recent4Max'] ?? '').toString().trim();
        final min4 = (score['recent4Min'] ?? '').toString().trim();
        if (latest.isNotEmpty || max4.isNotEmpty || min4.isNotEmpty) {
          memoLines.add('성적: 최근=${latest.isEmpty ? '-' : latest} / 최근4회 최대=${max4.isEmpty ? '-' : max4} / 최소=${min4.isEmpty ? '-' : min4}');
        }
      }
      final memo = memoLines.length > 1 ? memoLines.join('\n') : null;

      final now = DateTime.now();
      final studentId = const Uuid().v4();
      await _progressToWeb(requestId, 'saving');
      final student = Student(
        id: studentId,
        name: name,
        school: school,
        grade: grade,
        educationLevel: level,
        phoneNumber: studentPhone,
        parentPhoneNumber: parentPhone,
      );
      final basicInfo = StudentBasicInfo(
        studentId: studentId,
        phoneNumber: studentPhone,
        parentPhoneNumber: parentPhone,
        registrationDate: now, // ✅ 제출 시점
        memo: memo,
      );

      await DataManager.instance.addStudent(student, basicInfo);

      // 로컬 모드에서는 registration_date를 student_payment_info에 별도로 남겨야 화면/정렬에 반영됨
      if (!TagPresetService.preferSupabaseRead) {
        await DataManager.instance.addStudentPaymentInfo(
          StudentPaymentInfo(
            id: const Uuid().v4(),
            studentId: studentId,
            registrationDate: now,
            paymentMethod: 'monthly',
            tuitionFee: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }

      if (mounted) {
        showAppSnackBar(context, '학생 등록 완료: $name', useRoot: true);
      }
      await _progressToWeb(requestId, 'done');
      await _replyToWeb(requestId: requestId, ok: true, studentId: studentId);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '학생 등록 실패: $e', useRoot: true);
      }
      await _replyToWeb(requestId: requestId, ok: false, error: e.toString());
    }
  }

  @override
  void dispose() {
    _webMessageSub?.cancel();
    _webMessageSub = null;
    _urlSub?.cancel();
    _urlSub = null;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(color: _bg),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Text(
                '설문(웹) · ${_baseUrl}',
                style: const TextStyle(color: _sub, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                tooltip: '새로고침',
                onPressed: () => _controller.reload(),
                icon: const Icon(Icons.refresh, color: _sub, size: 18),
              ),
            ],
          ),
        ),
        // WebView(플랫폼 컨트롤) 상단에 얇은 경계선이 생길 수 있어 1px 마스킹
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                // ✅ 일부 환경(특히 Windows)에서 WebView가 마우스 휠 스크롤을 못 받는 케이스가 있어,
                // Flutter 쪽에서 휠 이벤트를 감지해 JS로 스크롤을 전달한다.
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerSignal: (signal) async {
                    if (signal is PointerScrollEvent) {
                      final dy = signal.scrollDelta.dy.round();
                      if (dy == 0) return;
                      // NOTE: scrollingElement가 있으면 그쪽으로, 없으면 window로 fallback
                      final js = 'try { (document.scrollingElement || document.documentElement || document.body).scrollBy(0, $dy); } catch (e) { window.scrollBy(0, $dy); }';
                      try {
                        await _controller.executeScript(js);
                      } catch (_) {
                        // ignore
                      }
                    }
                  },
                  child: Webview(_controller),
                ),
              ),
              const Positioned(left: 0, right: 0, top: 0, height: 1, child: ColoredBox(color: _bg)),
            ],
          ),
        ),
      ],
    );
  }
}



