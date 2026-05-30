import 'package:flutter/material.dart';

import '../../../../widgets/dialog_tokens.dart';
import '../../../../widgets/pill_tab_selector.dart';
import 'settings_preview_mock.dart';

/// 학습앱 설정 화면 UI 목업 (mock only).
///
/// 프로덕션: [SettingsScreen] — 컨펌 전 수정 금지.
class SettingsPreviewScreen extends StatefulWidget {
  const SettingsPreviewScreen({super.key});

  @override
  State<SettingsPreviewScreen> createState() => _SettingsPreviewScreenState();
}

class _SettingsPreviewScreenState extends State<SettingsPreviewScreen> {
  int _tabIndex = 0;
  final _academy = SettingsPreviewMockAcademy();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDlgBg,
      appBar: AppBar(
        backgroundColor: kDlgPanelBg,
        foregroundColor: kDlgText,
        title: const Text('설정 Preview'),
        actions: [
          TextButton(
            onPressed: () {},
            child: const Text('PREVIEW', style: TextStyle(color: kDlgAccent)),
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Center(
            child: PillTabSelector(
              selectedIndex: _tabIndex,
              tabs: const ['학원', '선생님', '일반'],
              onTabSelected: (i) => setState(() => _tabIndex = i),
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: KeyedSubtree(
                key: ValueKey<int>(_tabIndex),
                child: switch (_tabIndex) {
                  0 => _AcademyTabPreview(academy: _academy),
                  1 => const _TeachersTabPreview(),
                  _ => const _GeneralTabPreview(),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final Widget child;
  final double? width;

  const _PreviewCard({required this.child, this.width});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: SizedBox(
          width: width ?? 780,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
            decoration: BoxDecoration(
              color: kDlgPanelBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kDlgBorder),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _AcademyTabPreview extends StatelessWidget {
  final SettingsPreviewMockAcademy academy;

  const _AcademyTabPreview({required this.academy});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: _PreviewCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(
              icon: Icons.school_outlined,
              title: '학원 정보',
            ),
            const SizedBox(height: 16),
            _mockField(label: '학원명', value: academy.name, width: 300),
            const SizedBox(height: 16),
            _mockField(label: '학원 주소', value: academy.address, width: 600),
            const SizedBox(height: 16),
            _mockField(label: '슬로건', value: academy.slogan, width: 600),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _mockField(
                    label: '기본 정원',
                    value: academy.capacity,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _mockField(
                    label: '수업 시간(분)',
                    value: academy.lessonDuration,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const YggDialogSectionHeader(
              icon: Icons.schedule_outlined,
              title: '운영 시간 (목업)',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final day in ['월', '화', '수', '목', '금'])
                  YggDialogFilterChip(
                    label: day,
                    selected: day == '월' || day == '수',
                    onSelected: (_) {},
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TeachersTabPreview extends StatelessWidget {
  const _TeachersTabPreview();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: [
              for (final t in kSettingsPreviewMockTeachers)
                SizedBox(
                  width: 280,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: kDlgPanelBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kDlgBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(
                            color: kDlgText,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t.subject,
                          style: const TextStyle(color: kDlgTextSub),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.phone,
                          style: const TextStyle(
                            color: kDlgTextSub,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GeneralTabPreview extends StatelessWidget {
  const _GeneralTabPreview();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: _PreviewCard(
        width: 650,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const YggDialogSectionHeader(
              icon: Icons.system_update_outlined,
              title: '업데이트',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '최신 버전 확인 및 설치를 진행합니다.',
                    style: TextStyle(color: kDlgTextSub),
                  ),
                ),
                Text(
                  '현재: $kSettingsPreviewMockVersion',
                  style: const TextStyle(color: kDlgTextSub, fontSize: 12),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () {},
                  style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('업데이트 확인'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const YggDialogSectionHeader(
              icon: Icons.print_outlined,
              title: '프린터',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kDlgFieldBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDlgBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _mockField(
                    label: '일반 출력',
                    value: kSettingsPreviewMockPrinterGeneral,
                  ),
                  const SizedBox(height: 16),
                  _mockField(
                    label: '알림장',
                    value: kSettingsPreviewMockPrinterNotice,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _mockField({
  required String label,
  required String value,
  double? width,
}) {
  final field = TextFormField(
    initialValue: value,
    readOnly: true,
    style: const TextStyle(color: kDlgText),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: kDlgTextSub),
      filled: true,
      fillColor: kDlgFieldBg,
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: kDlgBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: kDlgAccent),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );
  if (width != null) {
    return SizedBox(width: width, child: field);
  }
  return field;
}
