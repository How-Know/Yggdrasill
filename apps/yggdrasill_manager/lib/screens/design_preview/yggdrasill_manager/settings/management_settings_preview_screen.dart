import 'package:flutter/material.dart';

import 'management_settings_preview_mock.dart';

/// 매니저앱 설정(ManagementScreen) UI 목업.
///
/// 프로덕션: [ManagementScreen] — 컨펌 전 수정 금지.
class ManagementSettingsPreviewScreen extends StatelessWidget {
  const ManagementSettingsPreviewScreen({super.key});

  static const Color _pageBg = Color(0xFF1F1F1F);
  static const Color _card = Color(0xFF18181A);
  static const Color _border = Color(0xFF2A2A2A);
  static const Color _fieldBg = Color(0xFF1F1F1F);
  static const Color _text = Colors.white;
  static const Color _sub = Color(0xFFB3B3B3);
  static const Color _primary = Color(0xFF1976D2);
  static const Color _accent = Color(0xFF33A373);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg,
      appBar: AppBar(
        backgroundColor: _pageBg,
        foregroundColor: _text,
        title: const Text('설정 Preview (매니저)'),
      ),
      body: Container(
        color: _pageBg,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '설정',
              style: TextStyle(
                color: _text,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '학원 및 소유자 관리 / 성향조사 웹 설정',
              style: TextStyle(color: _sub, fontSize: 14),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sectionCard(
                          title: '성향조사 웹',
                          subtitle: '설문/문항 관리자 페이지 주소를 설정합니다.',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _mockTextField(
                                      label: '설문 웹 Base URL',
                                      value: kManagementPreviewSurveyBaseUrl,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton(
                                    onPressed: () {},
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _primary,
                                      foregroundColor: _text,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 16,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    child: const Text(
                                      '저장',
                                      style: TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  _secondaryButton('관리자 페이지 열기'),
                                  _outlinedButton('설문 페이지 열기'),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionCard(
                          title: 'OpenAI API 키',
                          subtitle:
                              '관리자가 설정한 API 키는 서버에 저장됩니다. (목업)',
                          child: Row(
                            children: [
                              Expanded(
                                child: _mockTextField(
                                  label: 'API Key',
                                  value: kManagementPreviewOpenAiKeyMasked,
                                  obscure: true,
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton(
                                onPressed: () {},
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _accent,
                                  foregroundColor: _text,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text('저장'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        _sectionCard(
                          title: '소유자',
                          subtitle: '학원 소유자 계정 (목업)',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              kManagementPreviewOwnerEmail,
                              style: const TextStyle(color: _text),
                            ),
                            subtitle: const Text(
                              '역할: admin',
                              style: TextStyle(color: _sub),
                            ),
                            trailing: OutlinedButton(
                              onPressed: () {},
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _text,
                                side: const BorderSide(color: _border),
                              ),
                              child: const Text('관리'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _text,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(color: _sub, fontSize: 13)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _mockTextField({
    required String label,
    required String value,
    bool obscure = false,
  }) {
    return TextFormField(
      initialValue: value,
      readOnly: true,
      obscureText: obscure,
      style: const TextStyle(color: _text),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _text.withValues(alpha: 0.6)),
        filled: true,
        fillColor: _fieldBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: _primary.withValues(alpha: 0.7)),
        ),
      ),
    );
  }

  Widget _secondaryButton(String label) {
    return ElevatedButton(
      onPressed: () {},
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF2A2A2A),
        foregroundColor: _text,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }

  Widget _outlinedButton(String label) {
    return OutlinedButton(
      onPressed: () {},
      style: OutlinedButton.styleFrom(
        foregroundColor: _text,
        side: const BorderSide(color: _border),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}
