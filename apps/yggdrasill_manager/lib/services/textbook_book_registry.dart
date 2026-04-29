// Book registry service — creates the `resource_files` row, writes
// `resource_file_links` entries for body/answer/cover PDFs, uploads the
// cover image to `resource-covers`, and upserts the unit structure into
// `textbook_metadata.payload`.
//
// Mirrors the student app's composite-grade scheme (`<label>#<kind>`) so
// the same row can be read back by the legacy viewer. Once the legacy
// "책 추가" flow in the student app is retired, this service becomes the
// single canonical writer.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'textbook_course_catalog.dart';
import 'textbook_series_catalog.dart';

class TextbookBookRegistryResult {
  const TextbookBookRegistryResult({
    required this.bookId,
    required this.academyId,
    required this.gradeLabel,
    this.coverPublicUrl,
  });

  final String bookId;
  final String academyId;
  final String gradeLabel;
  final String? coverPublicUrl;
}

/// Minimal description of one 중단원's 소단원 slots. The series catalog only
/// tells us "which slots exist" (쎈 ⇒ A/B/C); the start/end pages come from
/// the wizard UI.
class MidUnitInput {
  const MidUnitInput({
    required this.midOrder,
    required this.midName,
    required this.subs,
  });

  final int midOrder;
  final String midName;
  final List<SubSectionInput> subs;

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'name': midName,
      'order_index': midOrder,
      'smalls': subs.map((e) => e.toPayload()).toList(),
    };
  }
}

class BigUnitInput {
  const BigUnitInput({
    required this.bigOrder,
    required this.bigName,
    required this.middles,
  });

  final int bigOrder;
  final String bigName;
  final List<MidUnitInput> middles;

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'name': bigName,
      'order_index': bigOrder,
      'middles': middles.map((e) => e.toPayload()).toList(),
    };
  }
}

class SubSectionInput {
  const SubSectionInput({
    required this.order,
    required this.subKey,
    required this.displayName,
    this.startPage,
    this.endPage,
  });

  final int order;
  final String subKey; // A | B | C
  final String displayName; // e.g. 'A 기본다잡기'
  final int? startPage;
  final int? endPage;

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      'name': displayName,
      'order_index': order,
      'sub_key': subKey,
      'start_page': startPage,
      'end_page': endPage,
      'page_counts': const <String, int>{},
    };
  }
}

/// Registration input gathered from the 책 추가 wizard.
class TextbookRegistrationInput {
  const TextbookRegistrationInput({
    required this.academyId,
    required this.seriesKey,
    required this.bookName,
    required this.gradeLabel,
    this.gradeKey,
    this.courseKey,
    this.courseLabel,
    required this.textbookType,
    required this.pageOffset,
    required this.bigUnits,
    this.description,
    this.existingBookId,
    this.coverLocalPath,
    this.coverExplicitUrl,
    this.parentFolderId,
    this.bodyLegacyUrl,
    this.answerLegacyUrl,
    this.solutionLegacyUrl,
    this.isPublished = false,
  });

  final String academyId;
  final String seriesKey;
  final String bookName;
  final String gradeLabel;
  final String? gradeKey;
  final String? courseKey;
  final String? courseLabel;
  final String textbookType; // '개념서' | '문제집'
  final int? pageOffset;
  final List<BigUnitInput> bigUnits;

  /// Optional short note shown under the book name in both the manager app
  /// migration pane and the student app resource list. Maps 1:1 to the
  /// `resource_files.description` column the student app already renders.
  final String? description;

  /// If set, the service upserts into the existing row instead of inserting.
  final String? existingBookId;

  /// Local image path or http(s) URL.
  final String? coverLocalPath;

  /// Already-hosted cover URL (e.g. from a previous upload).
  final String? coverExplicitUrl;

  /// Optional textbook folder id. When null, the book is saved at the root of
  /// the textbook tree.
  final String? parentFolderId;

  /// Optional Dropbox / legacy fallback URLs. The storage-backed PDFs are
  /// uploaded via [TextbookPdfService] before this registration runs, so we
  /// only write legacy URLs into `resource_file_links` when they exist.
  final String? bodyLegacyUrl;
  final String? answerLegacyUrl;
  final String? solutionLegacyUrl;

  /// When false (default for the wizard), the book is hidden from the
  /// student app until the operator flips the switch in the migration pane.
  /// Set to true only for manual/admin flows that should publish instantly.
  final bool isPublished;
}

class TextbookBookRegistry {
  TextbookBookRegistry({SupabaseClient? supabase})
      : _supa = supabase ?? Supabase.instance.client;

  final SupabaseClient _supa;
  final _uuid = const Uuid();

  static const String _coverBucket = 'resource-covers';

  /// Runs the full registration transaction. Returns the canonical book_id
  /// and uploaded cover URL (if any) so the caller can jump straight into the
  /// PDF upload step with a stable identifier.
  Future<TextbookBookRegistryResult> registerBook(
    TextbookRegistrationInput input,
  ) async {
    if (input.academyId.trim().isEmpty) {
      throw ArgumentError('academy_id is required');
    }
    if (input.bookName.trim().isEmpty) {
      throw ArgumentError('book_name is required');
    }
    if (input.gradeLabel.trim().isEmpty) {
      throw ArgumentError('grade_label is required');
    }

    final seriesEntry = textbookSeriesByKey(input.seriesKey);
    final bookId = input.existingBookId ?? _uuid.v4();
    final courseInfo = _resolveCourseInfo(
      gradeLabel: input.gradeLabel,
      gradeKey: input.gradeKey,
      courseKey: input.courseKey,
      courseLabel: input.courseLabel,
    );

    await _upsertResourceFileRow(
      bookId: bookId,
      academyId: input.academyId,
      name: input.bookName.trim(),
      description: input.description?.trim(),
      isUpdate: input.existingBookId != null,
      isPublished: input.isPublished,
      parentFolderId: input.parentFolderId?.trim(),
    );

    final coverUrl = await _resolveCoverUrl(
      bookId: bookId,
      academyId: input.academyId,
      gradeLabel: input.gradeLabel,
      explicitUrl: input.coverExplicitUrl,
      localPath: input.coverLocalPath,
    );

    await _upsertResourceFileLinks(
      bookId: bookId,
      academyId: input.academyId,
      gradeLabel: input.gradeLabel,
      gradeKey: courseInfo.gradeKey,
      courseKey: courseInfo.courseKey,
      courseLabel: courseInfo.courseLabel,
      bodyLegacyUrl: input.bodyLegacyUrl?.trim(),
      answerLegacyUrl: input.answerLegacyUrl?.trim(),
      solutionLegacyUrl: input.solutionLegacyUrl?.trim(),
      coverUrl: coverUrl,
    );

    await _upsertMetadataPayload(
      bookId: bookId,
      academyId: input.academyId,
      gradeLabel: input.gradeLabel,
      gradeKey: courseInfo.gradeKey,
      courseKey: courseInfo.courseKey,
      courseLabel: courseInfo.courseLabel,
      textbookType: input.textbookType,
      pageOffset: input.pageOffset,
      series: seriesEntry?.key ?? input.seriesKey,
      seriesDisplayName: seriesEntry?.displayName ?? input.seriesKey,
      bigUnits: input.bigUnits,
    );

    return TextbookBookRegistryResult(
      bookId: bookId,
      academyId: input.academyId,
      gradeLabel: input.gradeLabel,
      coverPublicUrl: coverUrl,
    );
  }

  Future<void> _upsertResourceFileRow({
    required String bookId,
    required String academyId,
    required String name,
    required String? description,
    required bool isUpdate,
    required bool isPublished,
    required String? parentFolderId,
  }) async {
    // Treat the empty string as "no description" so we don't overwrite an
    // existing note with a blank when the user leaves the field alone on
    // update. The student app renders whichever value we persist here.
    final descValue = (description ?? '').trim();
    if (isUpdate) {
      final row = <String, dynamic>{
        'name': name,
        'category': 'textbook',
        'folder_id':
            (parentFolderId ?? '').trim().isEmpty ? null : parentFolderId,
      };
      if (descValue.isNotEmpty) {
        row['description'] = descValue;
      }
      await _supa.from('resource_files').update(row).eq('id', bookId);
      return;
    }
    final row = <String, dynamic>{
      'id': bookId,
      'academy_id': academyId,
      'name': name,
      'description': descValue.isEmpty ? null : descValue,
      'category': 'textbook',
      'folder_id':
          (parentFolderId ?? '').trim().isEmpty ? null : parentFolderId,
      // Explicit so newly-registered books stay hidden until the operator
      // flips the switch in the migration pane.
      'is_published': isPublished,
    };
    await _supa.from('resource_files').upsert(row, onConflict: 'id');
  }

  /// Flip `resource_files.is_published` for a single book. Used by the
  /// migration pane's 학습앱 노출 switch.
  Future<void> setBookPublished({
    required String bookId,
    required bool isPublished,
  }) async {
    await _supa.from('resource_files').update(
        <String, dynamic>{'is_published': isPublished}).eq('id', bookId);
  }

  /// Reads back the current is_published value. Used by the migration pane
  /// to render the initial switch state without inflating the book list
  /// query.
  Future<bool> loadBookPublished({required String bookId}) async {
    try {
      final row = await _supa
          .from('resource_files')
          .select('is_published')
          .eq('id', bookId)
          .maybeSingle();
      if (row == null) return false;
      final v = row['is_published'];
      if (v is bool) return v;
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<String?> _resolveCoverUrl({
    required String bookId,
    required String academyId,
    required String gradeLabel,
    String? explicitUrl,
    String? localPath,
  }) async {
    final explicit = (explicitUrl ?? '').trim();
    if (explicit.isNotEmpty && _looksRemote(explicit)) {
      return explicit;
    }
    final local = (localPath ?? '').trim();
    if (local.isEmpty) return null;
    if (_looksRemote(local)) return local;
    final file = File(local);
    if (!await file.exists()) return null;
    final ext = p.extension(local).toLowerCase();
    final safeExt = ext.isNotEmpty ? ext : '.png';
    final safeGrade = gradeLabel.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final object =
        '$academyId/resource-covers/${bookId}_${safeGrade}_${DateTime.now().millisecondsSinceEpoch}$safeExt';
    final bytes = await file.readAsBytes();
    await _supa.storage.from(_coverBucket).uploadBinary(
          object,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: _contentTypeFromExt(safeExt),
          ),
        );
    return _supa.storage.from(_coverBucket).getPublicUrl(object);
  }

  Future<void> _upsertResourceFileLinks({
    required String bookId,
    required String academyId,
    required String gradeLabel,
    required String gradeKey,
    required String courseKey,
    required String courseLabel,
    String? bodyLegacyUrl,
    String? answerLegacyUrl,
    String? solutionLegacyUrl,
    String? coverUrl,
  }) async {
    // `resource_file_links` has no unique on (academy_id,file_id,grade), so
    // ON CONFLICT is unavailable. Do a per-row lookup → update-or-insert
    // instead, which also mirrors the gateway's finalize logic.
    Future<void> upsertOne(String kind, String? url) async {
      if (url == null || url.trim().isEmpty) return;
      final grade = '$gradeLabel#$kind';
      final existing = await _supa
          .from('resource_file_links')
          .select('id')
          .match(<String, Object>{
            'academy_id': academyId,
            'file_id': bookId,
            'grade': grade,
          })
          .limit(1)
          .maybeSingle();
      if (existing != null && existing['id'] != null) {
        final linkId = (existing['id'] as num).toInt();
        await _supa.from('resource_file_links').update(<String, dynamic>{
          'url': url,
          'grade_key': gradeKey,
          'course_key': courseKey,
          'course_label': courseLabel,
        }).eq('id', linkId);
      } else {
        await _supa.from('resource_file_links').insert(<String, dynamic>{
          'academy_id': academyId,
          'file_id': bookId,
          'grade': grade,
          'url': url,
          'grade_key': gradeKey,
          'course_key': courseKey,
          'course_label': courseLabel,
        });
      }
    }

    await upsertOne('body', bodyLegacyUrl);
    await upsertOne('ans', answerLegacyUrl);
    await upsertOne('sol', solutionLegacyUrl);
    await upsertOne('cover', coverUrl);
  }

  Future<void> _upsertMetadataPayload({
    required String bookId,
    required String academyId,
    required String gradeLabel,
    required String gradeKey,
    required String courseKey,
    required String courseLabel,
    required String textbookType,
    required int? pageOffset,
    required String series,
    required String seriesDisplayName,
    required List<BigUnitInput> bigUnits,
  }) async {
    final payload = <String, dynamic>{
      'version': 2,
      'series': series,
      'series_name': seriesDisplayName,
      'book_id': bookId,
      'grade_label': gradeLabel,
      'grade_key': gradeKey,
      'course_key': courseKey,
      'course_label': courseLabel,
      'units': bigUnits.map((u) => u.toPayload()).toList(),
    };
    await _supa.from('textbook_metadata').upsert(
      <String, dynamic>{
        'academy_id': academyId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'grade_key': gradeKey,
        'course_key': courseKey,
        'course_label': courseLabel,
        'textbook_type': textbookType,
        'page_offset': pageOffset,
        'payload': payload,
      },
      onConflict: 'academy_id,book_id,grade_label',
    );
  }

  ({String gradeKey, String courseKey, String courseLabel}) _resolveCourseInfo({
    required String gradeLabel,
    String? gradeKey,
    String? courseKey,
    String? courseLabel,
  }) {
    final byKey = textbookCourseByKey(courseKey);
    final byLabel = byKey ??
        textbookCourseByLabel(courseLabel) ??
        textbookCourseByLabel(gradeLabel);
    return (
      gradeKey: (gradeKey ?? '').trim().isNotEmpty
          ? gradeKey!.trim()
          : (byLabel?.gradeKey ?? ''),
      courseKey: (courseKey ?? '').trim().isNotEmpty
          ? courseKey!.trim()
          : (byLabel?.courseKey ?? ''),
      courseLabel: (courseLabel ?? '').trim().isNotEmpty
          ? courseLabel!.trim()
          : (byLabel?.label ?? gradeLabel.trim()),
    );
  }

  /// Helper to read back an existing book's unit payload so the unit
  /// authoring dialog can preload it on open.
  Future<Map<String, dynamic>?> loadPayload({
    required String academyId,
    required String bookId,
    required String gradeLabel,
  }) async {
    final row = await _supa
        .from('textbook_metadata')
        .select(
            'payload,textbook_type,page_offset,grade_key,course_key,course_label')
        .match(<String, Object>{
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
    }).maybeSingle();
    if (row == null) return null;
    return Map<String, dynamic>.from(row);
  }

  /// Persists only the unit tree (no file rows) — used by the unit authoring
  /// dialog when the user adjusts page ranges after the book has been
  /// registered.
  Future<void> saveUnitPayload({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required String seriesKey,
    required List<BigUnitInput> bigUnits,
  }) async {
    final seriesEntry = textbookSeriesByKey(seriesKey);
    final courseInfo = _resolveCourseInfo(gradeLabel: gradeLabel);
    final payload = <String, dynamic>{
      'version': 2,
      'series': seriesEntry?.key ?? seriesKey,
      'series_name': seriesEntry?.displayName ?? seriesKey,
      'book_id': bookId,
      'grade_label': gradeLabel,
      'grade_key': courseInfo.gradeKey,
      'course_key': courseInfo.courseKey,
      'course_label': courseInfo.courseLabel,
      'units': bigUnits.map((u) => u.toPayload()).toList(),
    };
    final existing = await _supa
        .from('textbook_metadata')
        .select('textbook_type,page_offset,grade_key,course_key,course_label')
        .match(<String, Object>{
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
    }).maybeSingle();
    final row = <String, dynamic>{
      'academy_id': academyId,
      'book_id': bookId,
      'grade_label': gradeLabel,
      'grade_key': courseInfo.gradeKey,
      'course_key': courseInfo.courseKey,
      'course_label': courseInfo.courseLabel,
      'payload': payload,
    };
    if (existing != null) {
      final existingMap = Map<String, dynamic>.from(existing);
      final tt = (existingMap['textbook_type'] as String?)?.trim();
      if (tt != null && tt.isNotEmpty) row['textbook_type'] = tt;
      final po = existingMap['page_offset'];
      if (po is int) row['page_offset'] = po;
      final existingGradeKey = '${existingMap['grade_key'] ?? ''}'.trim();
      final existingCourseKey = '${existingMap['course_key'] ?? ''}'.trim();
      final existingCourseLabel = '${existingMap['course_label'] ?? ''}'.trim();
      if (existingGradeKey.isNotEmpty) {
        row['grade_key'] = existingGradeKey;
        payload['grade_key'] = existingGradeKey;
      }
      if (existingCourseKey.isNotEmpty) {
        row['course_key'] = existingCourseKey;
        payload['course_key'] = existingCourseKey;
      }
      if (existingCourseLabel.isNotEmpty) {
        row['course_label'] = existingCourseLabel;
        payload['course_label'] = existingCourseLabel;
      }
    }
    await _supa.from('textbook_metadata').upsert(
          row,
          onConflict: 'academy_id,book_id,grade_label',
        );
  }
}

bool _looksRemote(String value) {
  final v = value.trim().toLowerCase();
  return v.startsWith('http://') || v.startsWith('https://');
}

String _contentTypeFromExt(String ext) {
  switch (ext.toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.webp':
      return 'image/webp';
    case '.gif':
      return 'image/gif';
    default:
      return 'application/octet-stream';
  }
}

/// Utility: decode a payload back into [BigUnitInput] list. Used by the unit
/// authoring dialog to rehydrate the tree editor from the server.
List<BigUnitInput> bigUnitsFromPayload(
  Map<String, dynamic>? payload, {
  required String seriesKey,
}) {
  if (payload == null) return const <BigUnitInput>[];
  final rawUnits = payload['units'];
  if (rawUnits is! List) return const <BigUnitInput>[];
  final seriesEntry = textbookSeriesByKey(seriesKey);
  final out = <BigUnitInput>[];
  for (var i = 0; i < rawUnits.length; i += 1) {
    final bigRaw = rawUnits[i];
    if (bigRaw is! Map) continue;
    final big = Map<String, dynamic>.from(bigRaw);
    final bigName = (big['name'] as String?)?.trim() ?? '';
    final bigOrder = _asInt(big['order_index']) ?? i;
    final midsRaw = big['middles'];
    final middles = <MidUnitInput>[];
    if (midsRaw is List) {
      for (var m = 0; m < midsRaw.length; m += 1) {
        final midRaw = midsRaw[m];
        if (midRaw is! Map) continue;
        final mid = Map<String, dynamic>.from(midRaw);
        final midName = (mid['name'] as String?)?.trim() ?? '';
        final midOrder = _asInt(mid['order_index']) ?? m;
        final smalls = <SubSectionInput>[];
        final rawSmalls = mid['smalls'];
        if (rawSmalls is List) {
          for (var s = 0; s < rawSmalls.length; s += 1) {
            final smallRaw = rawSmalls[s];
            if (smallRaw is! Map) continue;
            final small = Map<String, dynamic>.from(smallRaw);
            final key = (small['sub_key'] as String?)?.trim().toUpperCase() ??
                seriesEntry?.subPreset[s].key ??
                'A';
            final name = (small['name'] as String?)?.trim().isNotEmpty == true
                ? (small['name'] as String).trim()
                : (seriesEntry?.subPreset[s].displayName ?? key);
            smalls.add(SubSectionInput(
              order: _asInt(small['order_index']) ?? s,
              subKey: key,
              displayName: name,
              startPage: _asInt(small['start_page']),
              endPage: _asInt(small['end_page']),
            ));
          }
        }
        // If the stored tree predates the A/B/C preset, synthesise empty
        // slots so the UI always shows the expected three rows.
        if (smalls.isEmpty && seriesEntry != null) {
          for (var s = 0; s < seriesEntry.subPreset.length; s += 1) {
            final preset = seriesEntry.subPreset[s];
            smalls.add(SubSectionInput(
              order: s,
              subKey: preset.key,
              displayName: preset.displayName,
            ));
          }
        }
        middles.add(MidUnitInput(
          midOrder: midOrder,
          midName: midName,
          subs: smalls,
        ));
      }
    }
    out.add(BigUnitInput(
      bigOrder: bigOrder,
      bigName: bigName,
      middles: middles,
    ));
  }
  return out;
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Convenience helper so the wizard can turn the series preset into the
/// default set of sub-sections before the user has touched anything.
List<SubSectionInput> defaultSubsFor(String seriesKey) {
  final entry = textbookSeriesByKey(seriesKey);
  if (entry == null) return const <SubSectionInput>[];
  final out = <SubSectionInput>[];
  for (var i = 0; i < entry.subPreset.length; i += 1) {
    final preset = entry.subPreset[i];
    out.add(SubSectionInput(
      order: i,
      subKey: preset.key,
      displayName: preset.displayName,
    ));
  }
  return out;
}

/// Opaque helper for diagnostic logging / unit tests.
String debugDumpPayload(Map<String, dynamic> payload) =>
    const JsonEncoder.withIndent('  ').convert(payload);
