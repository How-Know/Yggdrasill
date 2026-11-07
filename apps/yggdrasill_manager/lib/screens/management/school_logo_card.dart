import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../problem_bank/naesin_link_school_name.dart';

/// 내신 시험지 표지 하단에 그릴 학교 로고(플랫폼 공용, 슈퍼관리자만 바꿀 수 있다).
class SchoolLogoCard extends StatefulWidget {
  const SchoolLogoCard({super.key});

  @override
  State<SchoolLogoCard> createState() => _SchoolLogoCardState();
}

class _SchoolLogoRow {
  const _SchoolLogoRow({
    required this.bucket,
    required this.path,
    required this.previewUrl,
  });

  final String bucket;
  final String path;
  final String previewUrl;
}

class _SchoolLogoCardState extends State<SchoolLogoCard> {
  static const _bucket = 'school-logos';
  static const _table = 'school_logos';

  final Map<String, _SchoolLogoRow> _logos = <String, _SchoolLogoRow>{};
  bool _loading = false;
  String? _busyKey;
  String? _message;
  bool _messageIsError = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await _client
          .from(_table)
          .select('school_key,logo_bucket,logo_path');
      final next = <String, _SchoolLogoRow>{};
      for (final raw in rows as List<dynamic>) {
        final row = raw as Map<String, dynamic>;
        final key = '${row['school_key'] ?? ''}'.trim();
        final path = '${row['logo_path'] ?? ''}'.trim();
        if (key.isEmpty || path.isEmpty) continue;
        final bucket = '${row['logo_bucket'] ?? _bucket}'.trim();
        var url = '';
        try {
          url = await _client.storage.from(bucket).createSignedUrl(path, 3600);
        } catch (_) {}
        next[key] = _SchoolLogoRow(bucket: bucket, path: path, previewUrl: url);
      }
      if (!mounted) return;
      setState(() {
        _logos
          ..clear()
          ..addAll(next);
      });
    } catch (e) {
      _setMessage('학교 로고를 불러오지 못했습니다: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setMessage(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  Future<void> _upload(String key) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '${naesinSchoolDisplayName(key)} 로고 선택',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
      withData: true,
    );
    final file = picked?.files.singleOrNull;
    if (file == null) return;
    Uint8List? bytes = file.bytes;
    if ((bytes == null || bytes.isEmpty) && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) {
      _setMessage('이미지 파일을 읽지 못했습니다.', error: true);
      return;
    }
    final ext = (file.extension ?? 'png').toLowerCase() == 'png' ? 'png' : 'jpg';
    final objectPath =
        'logos/${DateTime.now().millisecondsSinceEpoch}.$ext';
    setState(() => _busyKey = key);
    try {
      await _client.storage.from(_bucket).uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(
              contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
              upsert: false,
            ),
          );
      final previous = _logos[key];
      await _client.from(_table).upsert(<String, dynamic>{
        'school_key': key,
        'display_name': naesinSchoolDisplayName(key),
        'logo_bucket': _bucket,
        'logo_path': objectPath,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (previous != null) {
        try {
          await _client.storage.from(previous.bucket).remove([previous.path]);
        } catch (_) {}
      }
      await _load();
      _setMessage('${naesinSchoolDisplayName(key)} 로고를 저장했습니다.');
    } catch (e) {
      _setMessage('로고를 저장하지 못했습니다: $e', error: true);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _remove(String key) async {
    final current = _logos[key];
    if (current == null) return;
    setState(() => _busyKey = key);
    try {
      await _client.from(_table).delete().eq('school_key', key);
      try {
        await _client.storage.from(current.bucket).remove([current.path]);
      } catch (_) {}
      await _load();
      _setMessage('${naesinSchoolDisplayName(key)} 로고를 지웠습니다.');
    } catch (e) {
      _setMessage('로고를 지우지 못했습니다: $e', error: true);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Widget _buildSchoolTile(String key) {
    final logo = _logos[key];
    final busy = _busyKey == key;
    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        children: [
          Container(
            width: 72,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
            child: logo != null && logo.previewUrl.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.all(4),
                    child: Image.network(logo.previewUrl, fit: BoxFit.contain),
                  )
                : const Text(
                    '없음',
                    style: TextStyle(color: Color(0xFF8F8F8F), fontSize: 12),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  naesinSchoolDisplayName(key),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton(
                      onPressed: busy || _loading ? null : () => _upload(key),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF64B5F6),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(busy ? '저장 중...' : (logo == null ? '등록' : '변경')),
                    ),
                    if (logo != null)
                      TextButton(
                        onPressed: busy || _loading ? null : () => _remove(key),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFB3B3B3),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('지우기'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF18181A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '학교 로고',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFB3B3B3)),
                label: const Text('새로고침', style: TextStyle(color: Color(0xFFB3B3B3))),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '내신 시험지 표지 하단에 학교명과 함께 그립니다. 로고가 없는 학교는 학교명만 나옵니다. PNG·JPG를 올리세요.',
            style: TextStyle(color: Color(0xFFB3B3B3), fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (_loading && _logos.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final key in [...kNaesinMiddleSchools, ...kNaesinHighSchools])
                  _buildSchoolTile(key),
              ],
            ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            Text(
              _message!,
              style: TextStyle(
                color: _messageIsError ? const Color(0xFFD32F2F) : const Color(0xFF64B5F6),
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
