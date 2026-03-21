import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mathlive_editor_dialog.dart';

class InsertInlineMathIntent extends Intent {
  const InsertInlineMathIntent();
}

class InsertBlockMathIntent extends Intent {
  const InsertBlockMathIntent();
}

class MathShortcuts {
  static Widget wrap({
    required BuildContext context,
    required TextEditingController controller,
    required Widget child,
    bool enabled = true,
  }) {
    if (!enabled) return child;
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const InsertInlineMathIntent(),
        const SingleActivator(LogicalKeyboardKey.keyM, control: true):
            const InsertBlockMathIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          InsertInlineMathIntent: CallbackAction<InsertInlineMathIntent>(
            onInvoke: (_) {
              openInsertDialog(
                context: context,
                controller: controller,
                block: false,
              );
              return null;
            },
          ),
          InsertBlockMathIntent: CallbackAction<InsertBlockMathIntent>(
            onInvoke: (_) {
              openInsertDialog(
                context: context,
                controller: controller,
                block: true,
              );
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }

  static Future<void> openInsertDialog({
    required BuildContext context,
    required TextEditingController controller,
    required bool block,
  }) async {
    final initial = _initialFormulaFromSelection(
      controller.text,
      controller.selection,
    );
    final String? formula = await MathLiveEditorDialog.show(
      context: context,
      initialLatex: initial,
      block: block,
    );
    if (!context.mounted) return;
    if (formula == null || formula.trim().isEmpty) return;
    _insertFormula(controller, formula.trim(), block: block);
  }

  static void _insertFormula(
    TextEditingController controller,
    String formula, {
    required bool block,
  }) {
    final text = controller.text;
    var selection = controller.selection;
    if (!selection.isValid) {
      selection = TextSelection.collapsed(offset: text.length);
    }
    var start = selection.start;
    var end = selection.end;
    if (start < 0) start = text.length;
    if (end < 0) end = text.length;
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }
    if (start > text.length) start = text.length;
    if (end > text.length) end = text.length;

    final prefix = block ? '\$\$\n' : r'\(';
    final suffix = block ? '\n\$\$' : r'\)';
    final wrapped = '$prefix$formula$suffix';

    final newText = text.replaceRange(start, end, wrapped);
    final caret = start + wrapped.length;
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
    );
  }

  static String _initialFormulaFromSelection(
    String text,
    TextSelection selection,
  ) {
    if (!selection.isValid || selection.start < 0 || selection.end < 0) {
      return '';
    }
    if (selection.start == selection.end) return '';
    var start = selection.start;
    var end = selection.end;
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }
    if (start > text.length) return '';
    if (end > text.length) end = text.length;
    if (start >= end) return '';
    final selected = text.substring(start, end).trim();
    return _unwrapMathMarkers(selected);
  }

  static String _unwrapMathMarkers(String selected) {
    if (selected.startsWith(r'\(') && selected.endsWith(r'\)')) {
      return selected.substring(2, selected.length - 2).trim();
    }
    if (selected.startsWith('\$\$') && selected.endsWith('\$\$')) {
      return selected.substring(2, selected.length - 2).trim();
    }
    return selected;
  }

}
