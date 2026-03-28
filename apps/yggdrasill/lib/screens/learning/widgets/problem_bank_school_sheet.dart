import 'package:flutter/material.dart';

class ProblemBankSchoolSheet extends StatelessWidget {
  const ProblemBankSchoolSheet({
    super.key,
    required this.selectedSourceTypeCode,
    required this.schoolNames,
    required this.selectedSchoolName,
    required this.onSchoolSelected,
    required this.isLoading,
  });

  final String selectedSourceTypeCode;
  final List<String> schoolNames;
  final String? selectedSchoolName;
  final ValueChanged<String> onSchoolSelected;
  final bool isLoading;

  static const _panelBg = Color(0xFF151C21);
  static const _border = Color(0xFF223131);
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
              '학교 목록',
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
            '내신 기출 출처에서만 학교 목록을 제공합니다.\n다른 출처는 추후 구현 예정입니다.',
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
    if (schoolNames.isEmpty) {
      return const Center(
        child: Text(
          '조건에 맞는 학교가 없습니다.',
          style: TextStyle(
            color: Color(0xFF9FB3B3),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      itemCount: schoolNames.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final school = schoolNames[index];
        final selected = school == selectedSchoolName;
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSchoolSelected(school),
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
              children: [
                Icon(
                  selected ? Icons.folder_open : Icons.folder,
                  color: selected
                      ? const Color(0xFFBEE7D2)
                      : const Color(0xFF8AA5A5),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    school,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFFD6ECEA)
                          : const Color(0xFF9FB3B3),
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
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
