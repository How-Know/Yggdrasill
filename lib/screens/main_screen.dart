import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/navigation_rail.dart';
import '../widgets/student_registration_dialog.dart';
import '../services/data_manager.dart';
import 'student/student_screen.dart';
import 'timetable/timetable_screen.dart';
import 'settings/settings_screen.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/student_view_type.dart';
import '../widgets/main_fab.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  int _selectedIndex = 0;
  bool _isSideSheetOpen = false;
  late AnimationController _rotationAnimation;
  late Animation<double> _sideSheetAnimation;
  bool _isFabExpanded = false;
  late AnimationController _fabController;
  late Animation<double> _fabScaleAnimation;
  late Animation<double> _fabOpacityAnimation;
  
  // StudentScreen 관련 상태
  final GlobalKey<StudentScreenState> _studentScreenKey = GlobalKey<StudentScreenState>();
  StudentViewType _viewType = StudentViewType.all;
  final List<GroupInfo> _groups = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<GroupInfo> _expandedGroups = {};
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;
  int? _prevIndex;

  @override
  void initState() {
    super.initState();
    _rotationAnimation = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _sideSheetAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _rotationAnimation,
        curve: Curves.easeInOutCubic,
      ),
    );
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fabScaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _fabController,
        curve: Curves.easeOut,
      ),
    );
    _fabOpacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _fabController,
        curve: Curves.easeInOut,
      ),
    );
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    setState(() {
      _groups.clear();
      _groups.addAll(DataManager.instance.groups);
      _students.clear();
      _students.addAll(DataManager.instance.students.map((s) => s.student));
    });
  }

  @override
  void dispose() {
    _rotationAnimation.dispose();
    _fabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSideSheet() {
    if (_rotationAnimation.status == AnimationStatus.completed) {
      _rotationAnimation.reverse();
    } else {
      _rotationAnimation.forward();
    }
  }

  Widget _buildContent() {
    print('[DEBUG] _buildContent 진입, _selectedIndex= [38;5;246m$_selectedIndex [0m');
    switch (_selectedIndex) {
      case 0:
        return const Center(child: Text('홈', style: TextStyle(color: Colors.white)));
      case 1:
        return StudentScreen(key: _studentScreenKey);
      case 2:
        return TimetableScreen();
      case 3:
        return const Center(child: Text('학습', style: TextStyle(color: Colors.white, fontSize: 24)));
      case 4:
        return const Center(child: Text('자료', style: TextStyle(color: Colors.white, fontSize: 24)));
      default:
        return const SizedBox();
    }
  }

  void _showClassRegistrationDialog() {
    if (_studentScreenKey.currentState != null) {
      _studentScreenKey.currentState!.showClassRegistrationDialog();
    }
  }

  void _showStudentRegistrationDialog() {
    if (_studentScreenKey.currentState != null) {
      _studentScreenKey.currentState!.showStudentRegistrationDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG] MainScreen build');
    return Scaffold(
      body: Row(
        children: [
          CustomNavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            rotationAnimation: _rotationAnimation,
            onMenuPressed: _toggleSideSheet,
          ),
          AnimatedBuilder(
            animation: _sideSheetAnimation,
            builder: (context, child) => Container(
              width: 450 * _sideSheetAnimation.value,
              color: const Color(0xFF4A4A4A),
              child: const SizedBox(),
            ),
          ),
          Container(
            width: 1,
            color: const Color(0xFF4A4A4A),
          ),
          Expanded(
            child: _buildContent(),
          ),
        ],
      ),
      floatingActionButton: MainFab(),
    );
  }

  void _showFloatingSnackBar(BuildContext context, String message) {
    setState(() {
      _fabBottomPadding = 80.0 + 16.0;
    });
    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 16.0, right: 16.0, left: 16.0),
        duration: const Duration(seconds: 2),
      ),
    );
    _snackBarController?.closed.then((_) {
      if (mounted) {
        setState(() {
          _fabBottomPadding = 16.0;
        });
      }
    });
  }
} 