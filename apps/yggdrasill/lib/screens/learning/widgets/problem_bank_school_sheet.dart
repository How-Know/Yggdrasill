import 'package:flutter/material.dart';

import '../../../services/learning_problem_bank_service.dart';

class ProblemBankSchoolSheet extends StatelessWidget {
  const ProblemBankSchoolSheet({
    super.key,
    required this.selectedSourceTypeCode,
    required this.documents,
    required this.selectedDocumentId,
    required this.onDocumentSelected,
    required this.isLoading,
  });

  final String selectedSourceTypeCode;
  final List<LearningProblemDocumentSummary> documents;
  final String? selectedDocumentId;
  final ValueChanged<String> onDocumentSelected;
  final bool isLoading;

  static const _panelBg = Color(0xFF222222);
  static const _border = Color(0xFF333333);
  static const _selectedBg = Color(0xFF173C36);
  static const _text = Color(0xFFEAF2F2);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _panelBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: _border),
              ),
            ),
            child: const Text(
              '추출 문서',
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: _buildBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (selectedSourceTypeCode != 'school_past') {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
            '내신 기출 출처에서만 추출 문서 목록을 제공합니다.\n다른 출처는 추후 구현 예정입니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ),
      );
    }
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (documents.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '조건에 맞는 추출 문서가 없습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF9FB3B3),
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      itemCount: documents.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final doc = documents[index];
        final selected = doc.id == selectedDocumentId;
        final subtitle = doc.displaySubtitle;
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onDocumentSelected(doc.id),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? _selectedBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? const Color(0xFF2B6B61) : Colors.transparent,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    selected
                        ? Icons.picture_as_pdf_outlined
                        : Icons.description_outlined,
                    color: selected
                        ? const Color(0xFFBEE7D2)
                        : const Color(0xFF8AA5A5),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        doc.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? const Color(0xFFD6ECEA)
                              : const Color(0xFF9FB3B3),
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          fontSize: 13,
                          height: 1.25,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? const Color(0xFF8FB8B5)
                                : const Color(0xFF7A8F8F),
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
