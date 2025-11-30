import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A defensive [TextEditingController] for Windows IME.
///
/// On Flutter Windows builds the system IME occasionally reports cursor
/// positions that jump to the start of the field while characters are still
/// composing. This controller keeps the caret within the composing range and
/// snaps it back to the end of the committed text once the composition is
/// finished so that fast Korean input does not get scrambled.
class ImeAwareTextEditingController extends TextEditingController {
  ImeAwareTextEditingController({super.text});

  bool _isApplyingFix = false;
  TextRange? _lastComposingRange;
  TextEditingValue? _lastValue;

  bool get _shouldApplyFix =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  set value(TextEditingValue newValue) {
    if (_isApplyingFix || !_shouldApplyFix) {
      super.value = newValue;
      _lastValue = newValue;
      return;
    }

    final previousValue = _lastValue ?? super.value;
    var nextValue = newValue;

    if (newValue.composing.isValid) {
      nextValue = _clampSelectionToComposing(nextValue);
      _lastComposingRange = nextValue.composing;
    } else {
      nextValue = _restoreCaretIfNeeded(previousValue, nextValue);
      _lastComposingRange = null;
    }

    _isApplyingFix = true;
    super.value = nextValue;
    _isApplyingFix = false;
    _lastValue = nextValue;
  }

  TextEditingValue _clampSelectionToComposing(TextEditingValue value) {
    final composing = value.composing;
    final selection = value.selection;
    final isOutsideRange =
        selection.start < composing.start ||
            selection.start > composing.end ||
            selection.end < composing.start ||
            selection.end > composing.end;

    if (!isOutsideRange) {
      return value;
    }

    return value.copyWith(
      selection: TextSelection.collapsed(offset: composing.end),
    );
  }

  TextEditingValue _restoreCaretIfNeeded(
    TextEditingValue previous,
    TextEditingValue next,
  ) {
    final selection = next.selection;
    final textLength = next.text.length;

    final isSelectionOutOfBounds = selection.start < 0 ||
        selection.end < 0 ||
        selection.start > textLength ||
        selection.end > textLength;

    final jumpedToStart = selection.isCollapsed &&
        selection.start == 0 &&
        previous.text == next.text &&
        (_lastComposingRange?.end == textLength ||
            previous.selection.baseOffset == previous.text.length);

    if (!isSelectionOutOfBounds && !jumpedToStart) {
      return next;
    }

    return next.copyWith(
      selection: TextSelection.collapsed(offset: textLength),
    );
  }
}

