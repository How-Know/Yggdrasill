import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../widgets/latex_text_renderer.dart';
import 'think_style.dart';

Future<void> openThinkLink(BuildContext context, String? href) async {
  final uri = href == null ? null : Uri.tryParse(href);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showThinkSnack(context, '링크를 열지 못했습니다: $href', error: true);
}

class _DollarMathSyntax extends md.InlineSyntax {
  _DollarMathSyntax()
      : super(r'\$\$([\s\S]+?)\$\$|\$(?![\s$])([^$\n]+?)(?<!\s)\$', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match.group(1);
    parser.addNode(_math(display ?? match.group(2) ?? '', display: display != null));
    return true;
  }
}

class _BackslashMathSyntax extends md.InlineSyntax {
  _BackslashMathSyntax() : super(r'\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)', startCharacter: 0x5C);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match.group(1);
    parser.addNode(_math(display ?? match.group(2) ?? '', display: display != null));
    return true;
  }
}

md.Element _math(String tex, {required bool display}) =>
    md.Element.text('math', tex.trim())..attributes['display'] = display ? '1' : '0';

class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder(this.baseStyle);

  final TextStyle baseStyle;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.textContent;
    if (tex.isEmpty) return null;
    final display = element.attributes['display'] == '1';
    final style = baseStyle.merge(parentStyle);
    return Text.rich(
      WidgetSpan(
        alignment: display ? PlaceholderAlignment.bottom : PlaceholderAlignment.middle,
        child: display
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: LatexTextRenderer('\$\$$tex\$\$', style: style),
              )
            : LatexTextRenderer('\\($tex\\)', style: style),
      ),
    );
  }
}

MarkdownStyleSheet thinkMarkdownStyle(BuildContext context, {double fontSize = 14}) {
  final theme = Theme.of(context);
  final text = theme.textTheme;
  final body = TextStyle(color: kThinkText, fontSize: fontSize, height: 1.6);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    listBullet: body,
    tableBody: body,
    tableHead: body.copyWith(fontWeight: FontWeight.w700),
    tableBorder: TableBorder.all(color: kThinkBorder),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    h1: text.titleLarge?.copyWith(color: kThinkText, fontWeight: FontWeight.w800),
    h2: text.titleMedium?.copyWith(color: kThinkText, fontWeight: FontWeight.w800, fontSize: fontSize + 3),
    h3: text.titleSmall?.copyWith(color: kThinkText, fontWeight: FontWeight.w700, fontSize: fontSize + 1),
    h4: body.copyWith(fontWeight: FontWeight.w700),
    strong: const TextStyle(fontWeight: FontWeight.w700),
    code: body.copyWith(fontFamily: 'monospace', fontSize: fontSize - 1, backgroundColor: kThinkField),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(color: kThinkField, borderRadius: BorderRadius.circular(8)),
    blockquote: body.copyWith(color: kThinkSub),
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    blockquoteDecoration: BoxDecoration(color: kThinkQuote, borderRadius: BorderRadius.circular(8)),
    horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: kThinkBorder))),
    a: const TextStyle(color: kThinkLink, decoration: TextDecoration.underline),
  );
}

/// 선택·복사는 바깥의 [SelectionArea]가 맡는다. SelectableText는 수식(WidgetSpan)을 담지 못한다.
class ThinkMarkdown extends StatelessWidget {
  const ThinkMarkdown(this.data, {super.key, this.fontSize = 14});

  final String data;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = thinkMarkdownStyle(context, fontSize: fontSize);
    return MarkdownBody(
      data: data,
      styleSheet: style,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      inlineSyntaxes: [_DollarMathSyntax(), _BackslashMathSyntax()],
      builders: {'math': _MathBuilder(style.p ?? const TextStyle(color: kThinkText))},
      onTapLink: (text, href, title) => openThinkLink(context, href),
    );
  }
}
