import 'package:flutter/material.dart';

const Color kNavAccent = Color(0xFF33A373); // Yggdrasill 시그니처 초록

class AppNavigationBar extends StatelessWidget {
  final int selectedIndex;
  final Function(int) onDestinationSelected;
  final VoidCallback onLogout;

  const AppNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Color(0xFF18181A),
        border: Border(
          right: BorderSide(color: Color(0xFF2A2A2A), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Yggdrasill',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '관리자',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          
          const Divider(color: Color(0xFF2A2A2A), height: 1),
          
          // 네비게이션 항목
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                _NavigationItem(
                  icon: Icons.school_outlined,
                  label: '개념',
                  isSelected: selectedIndex == 0,
                  onTap: () => onDestinationSelected(0),
                ),
                _NavigationItem(
                  icon: Icons.calculate_outlined,
                  label: '연산',
                  isSelected: selectedIndex == 1,
                  onTap: () => onDestinationSelected(1),
                ),
                _NavigationItem(
                  icon: Icons.psychology_outlined,
                  label: '스킬',
                  isSelected: selectedIndex == 2,
                  onTap: () => onDestinationSelected(2),
                ),
                _NavigationItem(
                  icon: Icons.quiz_outlined,
                  label: '문제은행',
                  isSelected: selectedIndex == 3,
                  onTap: () => onDestinationSelected(3),
                ),
                _NavigationItem(
                  icon: Icons.psychology_outlined,
                  label: '성향조사',
                  isSelected: selectedIndex == 4,
                  onTap: () => onDestinationSelected(4),
                ),
                _NavigationItem(
                  icon: Icons.menu_book_outlined,
                  label: '교재',
                  isSelected: selectedIndex == 5,
                  onTap: () => onDestinationSelected(5),
                ),
                _NavigationItem(
                  icon: Icons.settings_outlined,
                  label: '설정',
                  isSelected: selectedIndex == 6,
                  onTap: () => onDestinationSelected(6),
                ),
              ],
            ),
          ),

          const Divider(color: Color(0xFF2A2A2A), height: 1),

          // 로그아웃 (최하단 고정)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onLogout,
                borderRadius: BorderRadius.circular(10),
                splashColor: Colors.transparent,
                highlightColor: Colors.white.withOpacity(0.06),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F1F1F),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.logout,
                        size: 24,
                        color: Colors.white.withOpacity(0.7),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        '로그아웃',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
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
    );
  }
}

class _NavigationItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          splashColor: Colors.transparent, // 흰색 깜빡임 제거
          highlightColor: kNavAccent.withOpacity(0.12), // 하이라이트 색상만 유지
          child: Container(
            // 고정 높이로 위치 이동 방지
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: isSelected ? kNavAccent.withOpacity(0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: isSelected
                  ? Border.all(color: kNavAccent.withOpacity(0.28), width: 1)
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 24, // 아이콘 크기 증가
                  color: isSelected ? kNavAccent : Colors.white.withOpacity(0.7),
                ),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? kNavAccent : Colors.white.withOpacity(0.7),
                    fontSize: 16, // 폰트 크기 증가
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

