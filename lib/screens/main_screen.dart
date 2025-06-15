import 'package:flutter/material.dart';
import 'student/student_screen.dart';
import '../widgets/student_registration_dialog.dart';
import '../services/data_manager.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _isFabExtended = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: const StudentScreen(),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_isFabExtended) ...[
              FloatingActionButton.extended(
                heroTag: 'registration',
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => StudentRegistrationDialog(
                      onSave: (student) async {
                        await DataManager.instance.addStudent(student);
                      },
                    ),
                  );
                },
                label: const Text('수강 등록'),
                icon: const Icon(Icons.person_add),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.extended(
                heroTag: 'makeup',
                onPressed: () {
                  // TODO: 보강 기능 구현
                },
                label: const Text('보강'),
                icon: const Icon(Icons.event_repeat),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.extended(
                heroTag: 'consultation',
                onPressed: () {
                  // TODO: 상담 기능 구현
                },
                label: const Text('상담'),
                icon: const Icon(Icons.chat),
              ),
              const SizedBox(height: 8),
            ],
            FloatingActionButton(
              onPressed: () {
                setState(() {
                  _isFabExtended = !_isFabExtended;
                });
              },
              child: Icon(_isFabExtended ? Icons.close : Icons.add),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
} 