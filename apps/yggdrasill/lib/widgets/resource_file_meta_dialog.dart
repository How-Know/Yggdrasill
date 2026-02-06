import 'package:flutter/material.dart';

class ResourceFileMetaDialog extends StatelessWidget {
  final String fileName;
  final String? description;
  final String? categoryLabel;
  final String? parentLabel;
  final String? gradeLabel;
  final int? linkCount;
  final bool hasCover;
  final bool hasIcon;

  const ResourceFileMetaDialog({
    super.key,
    required this.fileName,
    this.description,
    this.categoryLabel,
    this.parentLabel,
    this.gradeLabel,
    this.linkCount,
    required this.hasCover,
    required this.hasIcon,
  });

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1F1F1F);
    const text = Color(0xFFEAF2F2);
    const textSub = Color(0xFF9FB3B3);
    return AlertDialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        '파일 정보',
        style: TextStyle(color: text, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MetaRow(label: '이름', value: fileName),
            if ((description ?? '').trim().isNotEmpty)
              _MetaRow(label: '설명', value: description!.trim()),
            if ((categoryLabel ?? '').trim().isNotEmpty)
              _MetaRow(label: '분류', value: categoryLabel!.trim()),
            if ((parentLabel ?? '').trim().isNotEmpty)
              _MetaRow(label: '폴더', value: parentLabel!.trim()),
            if ((gradeLabel ?? '').trim().isNotEmpty)
              _MetaRow(label: '학년', value: gradeLabel!.trim()),
            if (linkCount != null)
              _MetaRow(label: '링크', value: '${linkCount!}개'),
            _MetaRow(label: '표지', value: hasCover ? '있음' : '없음'),
            _MetaRow(label: '아이콘', value: hasIcon ? '있음' : '없음'),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF141B1E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                '메타정보 상세/편집 기능은 준비 중입니다.',
                style: TextStyle(color: textSub, fontSize: 12.5, height: 1.35),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기', style: TextStyle(color: textSub)),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF9FB3B3), fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFFEAF2F2), fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
