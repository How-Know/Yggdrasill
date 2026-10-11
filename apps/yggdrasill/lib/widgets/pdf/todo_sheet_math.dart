import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../latex_text_renderer.dart';

/// 알림장 제목의 수식을 학습 화면 [LatexTextRenderer] 와 같은 조판으로 바꾼다.
///
/// `\(…\)`, `$$…$$` 는 그대로 둔다. `$…$` 와 구분 기호 없는 `\frac` 같은
/// 명령은 `\(` `\)` 로 감싸 같은 렌더러가 2차원으로 그리게 한다.
String normalizeTodoSheetMath(String raw) {
  if (raw.isEmpty) return raw;
  var built = '';
  var i = 0;
  while (i < raw.length) {
    if (raw.startsWith(r'$$', i)) {
      final end = raw.indexOf(r'$$', i + 2);
      if (end < 0) {
        built += raw.substring(i);
        break;
      }
      built += raw.substring(i, end + 2);
      i = end + 2;
      continue;
    }
    if (raw.startsWith(r'\(', i)) {
      final end = raw.indexOf(r'\)', i + 2);
      if (end < 0) {
        built += raw.substring(i);
        break;
      }
      built += raw.substring(i, end + 2);
      i = end + 2;
      continue;
    }
    if (raw[i] == r'$') {
      final end = raw.indexOf(r'$', i + 1);
      if (end < 0) {
        built += raw.substring(i);
        break;
      }
      built += r'\(';
      built += raw.substring(i + 1, end);
      built += r'\)';
      i = end + 1;
      continue;
    }
    if (raw[i] == r'\' &&
        !raw.startsWith(r'\(', i) &&
        !raw.startsWith(r'\)', i)) {
      final start = _mathRunStart(raw, i);
      final end = _mathRunEnd(raw, i);
      final already = i - start;
      if (already > 0 && already <= built.length) {
        built = built.substring(0, built.length - already);
      }
      built += r'\(';
      built += raw.substring(start, end).trim();
      built += r'\)';
      i = end;
      continue;
    }
    built += raw[i];
    i += 1;
  }
  return built;
}

bool todoSheetMathNeedsPaint(String normalized) {
  return normalized.contains(r'\(') || normalized.contains(r'$$');
}

class TodoSheetMathImage {
  const TodoSheetMathImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final double width;
  final double height;
}

/// [LatexTextRenderer] 한 줄을 비트맵으로 그린다. 실패하면 null.
Future<TodoSheetMathImage?> rasterizeTodoSheetMath({
  required String text,
  required double fontSize,
  required bool bold,
  required Color color,
  required double maxWidth,
}) async {
  if (text.trim().isEmpty || maxWidth <= 1 || fontSize <= 0) return null;
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return null;
  RenderObjectToWidgetElement<RenderBox>? root;
  PipelineOwner? pipelineOwner;
  BuildOwner? buildOwner;
  try {
    final view = views.first;
    final dpr = view.devicePixelRatio <= 0 ? 1.0 : view.devicePixelRatio;
    final logical = Size(maxWidth, mathMax(fontSize * 6, 48));
    final boundary = RenderRepaintBoundary();
    final renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(logical),
        physicalConstraints: BoxConstraints.tight(logical * dpr),
        devicePixelRatio: dpr,
      ),
      child: RenderPositionedBox(
        alignment: Alignment.topLeft,
        child: boundary,
      ),
    );
    pipelineOwner = PipelineOwner();
    buildOwner = BuildOwner(focusManager: FocusManager());
    pipelineOwner.rootNode = renderView;
    renderView.prepareInitialFrame();
    root = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTextStyle(
          style: TextStyle(
            fontFamily: _sheetFontFamily,
            fontFamilyFallback: const ['KakaoSmallSans'],
            fontSize: fontSize,
            color: color,
            height: 1.0,
          ),
          child: LatexTextRenderer(
            text,
            style: TextStyle(
              fontFamily: _sheetFontFamily,
              fontFamilyFallback: const ['KakaoSmallSans'],
              fontSize: fontSize,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              color: color,
              height: 1.0,
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            displayMathOverflow: DisplayMathOverflow.scaleDown,
          ),
        ),
      ),
    ).attachToRenderTree(buildOwner);
    buildOwner.buildScope(root);
    buildOwner.finalizeTree();
    pipelineOwner.flushLayout();
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();
    final size = boundary.size;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return null;
    }
    final image = await boundary.toImage(pixelRatio: 4);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return TodoSheetMathImage(
      bytes: data.buffer.asUint8List(),
      width: size.width,
      height: size.height,
    );
  } catch (_) {
    return null;
  } finally {
    final built = root;
    final owner = buildOwner;
    final pipeline = pipelineOwner;
    if (built != null && owner != null && pipeline != null) {
      _releaseOffscreen(owner, built, pipeline);
    }
  }
}

void _releaseOffscreen(
  BuildOwner buildOwner,
  RenderObjectToWidgetElement<RenderBox> root,
  PipelineOwner pipelineOwner,
) {
  try {
    buildOwner.lockState(() {
      // ignore: invalid_use_of_visible_for_overriding_member
      root.deactivate();
    });
    buildOwner.finalizeTree();
    // ignore: invalid_use_of_visible_for_overriding_member
    root.unmount();
    pipelineOwner.rootNode = null;
  } catch (_) {}
}

double mathMax(double a, double b) => a > b ? a : b;

// 알림장 PDF 본문과 같은 맑은 고딕. 없는 기기에서는 앱 글꼴로 대신한다.
String get _sheetFontFamily =>
    Platform.isWindows ? 'Malgun Gothic' : 'KakaoSmallSans';

int _mathRunStart(String s, int commandAt) {
  var start = commandAt;
  while (start > 0) {
    final prev = s[start - 1];
    if (prev == ' ') {
      if (start >= 2 && _isMathTokenChar(s[start - 2])) {
        start -= 1;
        continue;
      }
      break;
    }
    if (_isMathTokenChar(prev)) {
      start -= 1;
      continue;
    }
    break;
  }
  return start;
}

int _mathRunEnd(String s, int commandAt) {
  var j = commandAt;
  while (j < s.length) {
    if (s[j] == r'\' && !s.startsWith(r'\(', j) && !s.startsWith(r'\)', j)) {
      j = _skipLatexAtom(s, j);
      continue;
    }
    if (s[j] == '{') {
      final end = _matchBrace(s, j);
      if (end == null) break;
      j = end + 1;
      continue;
    }
    if (s[j] == ' ') {
      final next = j + 1;
      if (next < s.length &&
          (s[next] == r'\' || (s[next] != ' ' && _isMathTokenChar(s[next])))) {
        j += 1;
        continue;
      }
      break;
    }
    if (_isMathTokenChar(s[j])) {
      j += 1;
      continue;
    }
    break;
  }
  return j;
}

int _skipLatexAtom(String s, int i) {
  var j = i + 1;
  if (j >= s.length) return s.length;
  if (_isAsciiLetter(s[j])) {
    while (j < s.length && _isAsciiLetter(s[j])) {
      j += 1;
    }
  } else {
    j += 1;
  }
  if (j < s.length && s[j] == '[') {
    final end = s.indexOf(']', j + 1);
    if (end > 0) j = end + 1;
  }
  while (j < s.length && s[j] == '{') {
    final end = _matchBrace(s, j);
    if (end == null) break;
    j = end + 1;
  }
  return j;
}

int? _matchBrace(String s, int open) {
  if (open >= s.length || s[open] != '{') return null;
  var depth = 0;
  for (var i = open; i < s.length; i += 1) {
    if (s[i] == '{') depth += 1;
    if (s[i] == '}') {
      depth -= 1;
      if (depth == 0) return i;
    }
  }
  return null;
}

bool _isAsciiLetter(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

bool _isMathTokenChar(String ch) {
  if (ch.isEmpty) return false;
  final c = ch.codeUnitAt(0);
  if (c < 128) {
    return (c >= 48 && c <= 57) ||
        _isAsciiLetter(ch) ||
        '()[]+-*=<>^_,.'.contains(ch);
  }
  return '±×÷·√∞≤≥≠πθαβγ'.contains(ch);
}
