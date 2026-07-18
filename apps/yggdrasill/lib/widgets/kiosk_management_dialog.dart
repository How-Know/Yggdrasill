import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kiosk_management_service.dart';
import 'utility_glass_dialog_shell.dart';

const _panel = Color(0xB315171C);
const _border = Color(0x2EFFFFFF);
const _text = Color(0xFFF5F5F7);
const _subtle = Color(0xFFAEB3BC);
const _accent = Color(0xFF33A373);
const _danger = Color(0xFFF06A6A);

Future<void> showKioskManagementDialog(BuildContext context) {
  return showUtilityGlassDialog(
    context: context,
    title: '키오스크 관리',
    icon: Icons.tv_rounded,
    maxWidth: 940,
    maxHeight: 780,
    preferredWidth: 940,
    child: const KioskManagementDialog(),
  );
}

class KioskManagementDialog extends StatefulWidget {
  const KioskManagementDialog({super.key});

  @override
  State<KioskManagementDialog> createState() => _KioskManagementDialogState();
}

class _KioskManagementDialogState extends State<KioskManagementDialog> {
  final _service = KioskManagementService.instance;
  final _pinController = TextEditingController();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();

  List<KioskDevice> _devices = const [];
  List<KioskAnnouncement> _announcements = const [];
  final Set<String> _busyAnnouncementIds = {};
  bool _loadingDevices = true;
  bool _loadingAnnouncements = true;
  bool _approving = false;
  bool _publishing = false;
  String? _devicesError;
  String? _announcementsError;
  int _expiryDays = 3;

  @override
  void initState() {
    super.initState();
    _refreshDevices();
    _refreshAnnouncements();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    if (!mounted) return;
    setState(() {
      _loadingDevices = true;
      _devicesError = null;
    });
    try {
      final devices = await _service.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loadingDevices = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDevices = false;
        _devicesError = _message(error);
      });
    }
  }

  Future<void> _refreshAnnouncements() async {
    if (!mounted) return;
    setState(() {
      _loadingAnnouncements = true;
      _announcementsError = null;
    });
    try {
      final announcements = await _service.listAnnouncements();
      if (!mounted) return;
      setState(() {
        _announcements = announcements;
        _loadingAnnouncements = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingAnnouncements = false;
        _announcementsError = _message(error);
      });
    }
  }

  Future<void> _approvePairing() async {
    if (_approving) return;
    final code = _pinController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showMessage('연결 PIN 6자리를 입력해 주세요.', error: true);
      return;
    }
    setState(() => _approving = true);
    try {
      await _service.approvePairing(code);
      if (!mounted) return;
      _pinController.clear();
      _showMessage('연결을 승인했습니다. 키오스크에서 연결을 완료해 주세요.');
      await _refreshDevices();
    } catch (error) {
      if (mounted) _showMessage(_message(error), error: true);
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  Future<void> _publishAnnouncement() async {
    if (_publishing) return;
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();
    if (title.isEmpty) {
      _showMessage('공지 제목을 입력해 주세요.', error: true);
      return;
    }
    if (title.length > 200) {
      _showMessage('제목은 200자 이하로 입력해 주세요.', error: true);
      return;
    }
    if (body.isEmpty) {
      _showMessage('공지 본문을 입력해 주세요.', error: true);
      return;
    }
    if (body.length > 10000) {
      _showMessage('본문은 10,000자 이하로 입력해 주세요.', error: true);
      return;
    }

    setState(() => _publishing = true);
    try {
      await _service.createAnnouncement(
        title: title,
        body: body,
        expiresAt: _expiryDays == 0
            ? null
            : DateTime.now().add(Duration(days: _expiryDays)),
      );
      if (!mounted) return;
      _titleController.clear();
      _bodyController.clear();
      _showMessage('공지를 즉시 게시했습니다.');
      await _refreshAnnouncements();
    } catch (error) {
      if (mounted) _showMessage(_message(error), error: true);
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _endAnnouncement(KioskAnnouncement announcement) async {
    await _runAnnouncementAction(
      announcement.id,
      _service.endAnnouncement,
      '공지를 종료했습니다.',
    );
  }

  Future<void> _deleteAnnouncement(KioskAnnouncement announcement) async {
    if (_busyAnnouncementIds.contains(announcement.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF202126),
        title: const Text('공지 삭제', style: TextStyle(color: _text)),
        content: Text(
          '‘${announcement.title}’ 공지를 삭제할까요?\n삭제한 공지는 복구할 수 없습니다.',
          style: const TextStyle(color: _subtle),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제', style: TextStyle(color: _danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runAnnouncementAction(
      announcement.id,
      _service.deleteAnnouncement,
      '공지를 삭제했습니다.',
    );
  }

  Future<void> _runAnnouncementAction(
    String id,
    Future<void> Function(String id) action,
    String successMessage,
  ) async {
    if (_busyAnnouncementIds.contains(id)) return;
    setState(() => _busyAnnouncementIds.add(id));
    try {
      await action(id);
      if (!mounted) return;
      _showMessage(successMessage);
      await _refreshAnnouncements();
    } catch (error) {
      if (mounted) _showMessage(_message(error), error: true);
    } finally {
      if (mounted) setState(() => _busyAnnouncementIds.remove(id));
    }
  }

  String _message(Object error) {
    if (error is KioskManagementException) return error.message;
    return '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.';
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor:
              error ? const Color(0xFF8E3535) : const Color(0xFF17614A),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const Material(
            color: Colors.transparent,
            child: TabBar(
              labelColor: _text,
              unselectedLabelColor: _subtle,
              indicatorColor: _accent,
              dividerColor: _border,
              tabs: [
                Tab(icon: Icon(Icons.link_rounded), text: '기기 연결'),
                Tab(icon: Icon(Icons.campaign_rounded), text: '공지 전송'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildConnectionTab(),
                _buildAnnouncementTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _GlassSection(
          title: '새 키오스크 연결',
          subtitle: '키오스크 화면에 표시된 6자리 PIN을 입력하세요.',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _pinController,
                  enabled: !_approving,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _approvePairing(),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  style: const TextStyle(
                    color: _text,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 8,
                  ),
                  decoration: _inputDecoration(
                    label: '연결 PIN',
                    hint: '000000',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: _approving ? null : _approvePairing,
                  style: _primaryButtonStyle(),
                  icon: _approving
                      ? const _SmallProgress()
                      : const Icon(Icons.check_circle_rounded),
                  label: Text(_approving ? '승인 중' : '승인'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _GlassSection(
          title: '연결된 기기',
          subtitle: '승인이 완료되어 이 학원에 연결된 키오스크입니다.',
          trailing: IconButton(
            tooltip: '새로고침',
            onPressed: _loadingDevices ? null : _refreshDevices,
            icon: _loadingDevices
                ? const _SmallProgress()
                : const Icon(Icons.refresh_rounded, color: _text),
          ),
          child: _buildDevicesContent(),
        ),
      ],
    );
  }

  Widget _buildDevicesContent() {
    if (_loadingDevices && _devices.isEmpty) {
      return const _LoadingBlock(label: '연결된 기기를 불러오는 중입니다.');
    }
    if (_devicesError != null && _devices.isEmpty) {
      return _ErrorBlock(message: _devicesError!, onRetry: _refreshDevices);
    }
    if (_devices.isEmpty) {
      return const _EmptyBlock(
        icon: Icons.tv_off_rounded,
        message: '아직 연결된 키오스크가 없습니다.',
      );
    }
    return Column(
      children: [
        if (_devicesError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _InlineError(message: _devicesError!),
          ),
        for (var index = 0; index < _devices.length; index++) ...[
          _DeviceTile(device: _devices[index]),
          if (index != _devices.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildAnnouncementTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _GlassSection(
          title: '새 공지 게시',
          subtitle: '게시 즉시 연결된 키오스크 화면에 반영됩니다.',
          child: Column(
            children: [
              TextField(
                controller: _titleController,
                enabled: !_publishing,
                maxLength: 200,
                style: const TextStyle(color: _text),
                decoration: _inputDecoration(
                  label: '제목',
                  hint: '예: 오늘 수업 시간 변경 안내',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bodyController,
                enabled: !_publishing,
                maxLength: 10000,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(color: _text),
                decoration: _inputDecoration(
                  label: '본문',
                  hint: '키오스크에 표시할 내용을 입력하세요.',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _expiryDays,
                      dropdownColor: const Color(0xFF25272D),
                      style: const TextStyle(color: _text),
                      decoration: _inputDecoration(label: '만료'),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1일 후')),
                        DropdownMenuItem(value: 3, child: Text('3일 후')),
                        DropdownMenuItem(value: 7, child: Text('7일 후')),
                        DropdownMenuItem(value: 0, child: Text('만료 없음')),
                      ],
                      onChanged: _publishing
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _expiryDays = value);
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _publishing ? null : _publishAnnouncement,
                      style: _primaryButtonStyle(),
                      icon: _publishing
                          ? const _SmallProgress()
                          : const Icon(Icons.send_rounded),
                      label: Text(_publishing ? '게시 중' : '즉시 게시'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _GlassSection(
          title: '공지 목록',
          subtitle: '종료된 공지도 함께 표시됩니다.',
          trailing: IconButton(
            tooltip: '새로고침',
            onPressed: _loadingAnnouncements ? null : _refreshAnnouncements,
            icon: _loadingAnnouncements
                ? const _SmallProgress()
                : const Icon(Icons.refresh_rounded, color: _text),
          ),
          child: _buildAnnouncementsContent(),
        ),
      ],
    );
  }

  Widget _buildAnnouncementsContent() {
    if (_loadingAnnouncements && _announcements.isEmpty) {
      return const _LoadingBlock(label: '공지 목록을 불러오는 중입니다.');
    }
    if (_announcementsError != null && _announcements.isEmpty) {
      return _ErrorBlock(
        message: _announcementsError!,
        onRetry: _refreshAnnouncements,
      );
    }
    if (_announcements.isEmpty) {
      return const _EmptyBlock(
        icon: Icons.notifications_none_rounded,
        message: '게시한 공지가 없습니다.',
      );
    }
    return Column(
      children: [
        if (_announcementsError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _InlineError(message: _announcementsError!),
          ),
        for (var index = 0; index < _announcements.length; index++) ...[
          _AnnouncementTile(
            announcement: _announcements[index],
            busy: _busyAnnouncementIds.contains(_announcements[index].id),
            onEnd: () => _endAnnouncement(_announcements[index]),
            onDelete: () => _deleteAnnouncement(_announcements[index]),
          ),
          if (index != _announcements.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _GlassSection extends StatelessWidget {
  const _GlassSection({
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: _text,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(color: _subtle, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});

  final KioskDevice device;

  @override
  Widget build(BuildContext context) {
    return _ListCard(
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.tv_rounded, color: _accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.deviceName,
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '마지막 접속 ${_formatDateTime(device.lastSeenAt)}',
                  style: const TextStyle(color: _subtle, fontSize: 12),
                ),
              ],
            ),
          ),
          _StatusBadge(
            label: device.isActive ? '활성' : '비활성',
            active: device.isActive,
          ),
        ],
      ),
    );
  }
}

class _AnnouncementTile extends StatelessWidget {
  const _AnnouncementTile({
    required this.announcement,
    required this.busy,
    required this.onEnd,
    required this.onDelete,
  });

  final KioskAnnouncement announcement;
  final bool busy;
  final VoidCallback onEnd;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final active = announcement.isCurrentlyActive;
    return _ListCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  announcement.title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _StatusBadge(label: active ? '게시 중' : '종료', active: active),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            announcement.body,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFD5D8DE), height: 1.45),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '게시 ${_formatDateTime(announcement.publishedAt)} · '
                  '만료 ${announcement.expiresAt == null ? '없음' : _formatDateTime(announcement.expiresAt)}',
                  style: const TextStyle(color: _subtle, fontSize: 11),
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: _SmallProgress(),
                )
              else ...[
                if (active)
                  TextButton.icon(
                    onPressed: onEnd,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('종료'),
                  ),
                TextButton.icon(
                  onPressed: onDelete,
                  style: TextButton.styleFrom(foregroundColor: _danger),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('삭제'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x7A24262C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: child,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? _accent : _subtle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _SmallProgress(),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: _subtle)),
        ],
      ),
    );
  }
}

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(icon, color: _subtle, size: 34),
          const SizedBox(height: 8),
          Text(message, style: const TextStyle(color: _subtle)),
        ],
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _InlineError(message: message),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('다시 시도'),
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: _danger, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFFFB6B6), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallProgress extends StatelessWidget {
  const _SmallProgress();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: _accent,
      ),
    );
  }
}

InputDecoration _inputDecoration({
  required String label,
  String? hint,
  bool alignLabelWithHint = false,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    alignLabelWithHint: alignLabelWithHint,
    labelStyle: const TextStyle(color: _subtle),
    hintStyle: const TextStyle(color: Color(0xFF737983)),
    counterStyle: const TextStyle(color: _subtle),
    filled: true,
    fillColor: const Color(0x80101216),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: _accent, width: 1.4),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0x18FFFFFF)),
    ),
  );
}

ButtonStyle _primaryButtonStyle() {
  return FilledButton.styleFrom(
    backgroundColor: _accent,
    foregroundColor: Colors.white,
    disabledBackgroundColor: const Color(0xFF315348),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
}

String _formatDateTime(DateTime? value) {
  if (value == null) return '기록 없음';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}.${two(value.month)}.${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
