import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Temporary migration toggle for the textbook viewer.
///
/// Phase 1 of the Dropbox → Supabase Storage migration keeps both code paths
/// alive so we can compare them side-by-side without risking the legacy flow.
/// While this flag is `false`, the resources screen opens textbook PDFs using
/// the pre-existing external launcher / Dropbox URL path. When it is `true`,
/// the new `TextbookPdfService` + `TextbookViewerPage` (local cache +
/// in-app pdfrx viewer) is used instead.
///
/// The value is persisted with `shared_preferences` so it survives app
/// restarts, and exposed as a [ValueNotifier] so cards that show the toggle
/// rebuild immediately when it changes anywhere in the app.
///
/// Once the in-app viewer is stable, this whole service can be deleted and
/// the call sites can hard-code the new viewer.
class TextbookViewerPreference {
  TextbookViewerPreference._internal();

  static final TextbookViewerPreference instance =
      TextbookViewerPreference._internal();

  static const String _prefsKey = 'textbook_viewer.use_in_app';

  final ValueNotifier<bool> _useInApp = ValueNotifier<bool>(false);
  bool _hydrated = false;
  Future<void>? _hydrationFuture;

  /// Current value. May still be the default (`false`) if [ensureLoaded]
  /// has not completed yet.
  bool get useInApp => _useInApp.value;

  /// Listenable the UI can bind to (e.g. `AnimatedBuilder` / `ValueListenableBuilder`).
  ValueListenable<bool> get useInAppListenable => _useInApp;

  /// Loads the persisted flag once. Subsequent calls return immediately.
  Future<void> ensureLoaded() {
    if (_hydrated) return Future<void>.value();
    return _hydrationFuture ??= _hydrate();
  }

  Future<void> _hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _useInApp.value = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      // If prefs fail to load for any reason, fall back to the safe default
      // (legacy flow) so we never accidentally force the new flow.
      _useInApp.value = false;
    } finally {
      _hydrated = true;
    }
  }

  Future<void> setUseInApp(bool value) async {
    _useInApp.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {
      // Best-effort persistence: UI already reflects the new value via the
      // notifier, we just lose it on next launch if prefs are unavailable.
    }
  }

  Future<void> toggle() => setUseInApp(!_useInApp.value);
}
