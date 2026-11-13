import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'question_view_scale.dart';

const int _monitorInfoExSize = 104;
const int _displayDeviceSize = 840;

final class _MonitorInfoEx extends Struct {
  @Uint32()
  external int cbSize;

  @Int32()
  external int monitorLeft;

  @Int32()
  external int monitorTop;

  @Int32()
  external int monitorRight;

  @Int32()
  external int monitorBottom;

  @Int32()
  external int workLeft;

  @Int32()
  external int workTop;

  @Int32()
  external int workRight;

  @Int32()
  external int workBottom;

  @Uint32()
  external int flags;

  @Array(32)
  external Array<Uint16> device;
}

final class _DisplayDevice extends Struct {
  @Uint32()
  external int cb;

  @Array(32)
  external Array<Uint16> deviceName;

  @Array(128)
  external Array<Uint16> deviceString;

  @Uint32()
  external int stateFlags;

  @Array(128)
  external Array<Uint16> deviceId;

  @Array(128)
  external Array<Uint16> deviceKey;
}

final class _Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

/// Win32 `MONITORINFOEXW` / `DISPLAY_DEVICEW` 크기가 헤더와 같은지 확인한다.
bool get windowsMonitorStructsMatchWin32 =>
    sizeOf<_MonitorInfoEx>() == _monitorInfoExSize &&
    sizeOf<_DisplayDevice>() == _displayDeviceSize;

int? _cachedMonitor;
double? _cachedPpi;

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

final int Function(
  Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
  int,
) _enumWindows = _user32.lookupFunction<
    Int32 Function(
      Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
      IntPtr,
    ),
    int Function(
      Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>,
      int,
    )>('EnumWindows');

final int Function(int, Pointer<Uint16>, int) _getClassName = _user32
    .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)>('GetClassNameW');

final int Function(int, Pointer<Uint16>, int) _getWindowText = _user32
    .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)>('GetWindowTextW');

final int Function(int, int) _monitorFromWindow = _user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32),
    int Function(int, int)>('MonitorFromWindow');

final int Function(int, Pointer<_MonitorInfoEx>) _getMonitorInfo = _user32
    .lookupFunction<
        Int32 Function(IntPtr, Pointer<_MonitorInfoEx>),
        int Function(int, Pointer<_MonitorInfoEx>)>('GetMonitorInfoW');

final int Function(Pointer<Utf16>, int, Pointer<_DisplayDevice>, int)
    _enumDisplayDevices = _user32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32, Pointer<_DisplayDevice>, Uint32),
        int Function(Pointer<Utf16>, int, Pointer<_DisplayDevice>, int)>(
      'EnumDisplayDevicesW',
    );

final int Function(Pointer<Utf16>, int, Pointer<Uint8>) _enumDisplaySettings =
    _user32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32, Pointer<Uint8>),
        int Function(Pointer<Utf16>, int, Pointer<Uint8>)>(
      'EnumDisplaySettingsW',
    );

final int Function(int, Pointer<_Rect>) _getClientRect = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<_Rect>),
    int Function(int, Pointer<_Rect>)>('GetClientRect');

final int Function(int, Pointer<_Rect>) _getWindowRect = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<_Rect>),
    int Function(int, Pointer<_Rect>)>('GetWindowRect');

final int Function(int, int, int, int, int, int, int) _setWindowPos = _user32
    .lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');

final int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>) _regOpen =
    _advapi32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
        int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
      'RegOpenKeyExW',
    );

final int Function(int) _regClose =
    _advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'RegCloseKey',
    );

final int Function(
  int,
  Pointer<Utf16>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint8>,
  Pointer<Uint32>,
) _regQuery = _advapi32.lookupFunction<
    Int32 Function(
      IntPtr,
      Pointer<Utf16>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint8>,
      Pointer<Uint32>,
    ),
    int Function(
      int,
      Pointer<Utf16>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint8>,
      Pointer<Uint32>,
    )>('RegQueryValueExW');

final int Function(
  int,
  int,
  Pointer<Uint16>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint16>,
  Pointer<Uint32>,
  Pointer<Uint8>,
) _regEnumKey = _advapi32.lookupFunction<
    Int32 Function(
      IntPtr,
      Uint32,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Pointer<Uint8>,
    ),
    int Function(
      int,
      int,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Pointer<Uint8>,
    )>('RegEnumKeyExW');

/// 학생 앱 창이 있는 모니터의 실제 가로 ppi.
///
/// 윈도우 배율이 알려 주는 96dpi가 아니라, 현재 해상도와 EDID 패널 크기로 계산한다.
double? windowsMonitorPhysicalPpi() {
  if (!windowsMonitorStructsMatchWin32) return _cachedPpi;
  final monitor = _studentMonitor();
  if (monitor == 0) return _cachedPpi;
  if (monitor == _cachedMonitor && _cachedPpi != null) return _cachedPpi;
  final ppi = _ppiForMonitor(monitor);
  if (ppi == null) return _cachedPpi;
  _cachedMonitor = monitor;
  _cachedPpi = ppi;
  return ppi;
}

/// 105mm 문항이 창에 들어가도록 학생 앱 창의 가로만 늘린다.
void ensureQuestionPreviewWindow({required double devicePixelRatio}) {
  final ppi = windowsMonitorPhysicalPpi();
  final hwnd = _findStudentWindow();
  if (ppi == null || hwnd == 0) return;
  final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  final clientLogical = questionViewLogicalWidth(
        maxWidth: double.infinity,
        logicalPixelsPerInch: ppi / dpr,
      ) +
      24 * 2 +
      10 * 2 +
      24;
  final neededClient = (clientLogical * dpr).ceil();

  final arena = Arena();
  try {
    final client = arena<_Rect>();
    final window = arena<_Rect>();
    final info = arena<_MonitorInfoEx>();
    if (_getClientRect(hwnd, client) == 0 || _getWindowRect(hwnd, window) == 0) {
      return;
    }
    final clientWidth = client.ref.right - client.ref.left;
    if (clientWidth >= neededClient) return;
    info.ref.cbSize = sizeOf<_MonitorInfoEx>();
    final monitor = _monitorFromWindow(hwnd, 2);
    if (monitor == 0 || _getMonitorInfo(monitor, info) == 0) return;

    final frame = (window.ref.right - window.ref.left) - clientWidth;
    final workWidth = info.ref.workRight - info.ref.workLeft;
    var outerWidth = neededClient + (frame < 0 ? 0 : frame);
    if (outerWidth > workWidth) outerWidth = workWidth;
    var left = window.ref.left;
    if (left + outerWidth > info.ref.workRight) {
      left = info.ref.workRight - outerWidth;
    }
    if (left < info.ref.workLeft) left = info.ref.workLeft;
    const swpNoZOrder = 0x0004;
    const swpNoActivate = 0x0010;
    _setWindowPos(
      hwnd,
      0,
      left,
      window.ref.top,
      outerWidth,
      window.ref.bottom - window.ref.top,
      swpNoZOrder | swpNoActivate,
    );
  } finally {
    arena.releaseAll();
  }
}

int _studentMonitor() {
  final hwnd = _findStudentWindow();
  if (hwnd != 0) {
    final monitor = _monitorFromWindow(hwnd, 2);
    if (monitor != 0) return monitor;
  }
  final desktop = _user32
      .lookupFunction<IntPtr Function(), int Function()>('GetDesktopWindow');
  return _monitorFromWindow(desktop(), 1);
}

int _findStudentWindow() {
  final arena = Arena();
  var found = 0;
  late final NativeCallable<Int32 Function(IntPtr, IntPtr)> callback;
  callback = NativeCallable<Int32 Function(IntPtr, IntPtr)>.isolateLocal(
    (int hwnd, int lparam) {
      final classBuf = arena<Uint16>(64);
      final titleBuf = arena<Uint16>(64);
      _getClassName(hwnd, classBuf, 64);
      _getWindowText(hwnd, titleBuf, 64);
      final className = classBuf.cast<Utf16>().toDartString();
      final title = titleBuf.cast<Utf16>().toDartString();
      if (className == 'FLUTTER_RUNNER_WIN32_WINDOW' &&
          title == 'yggdrasill_student') {
        found = hwnd;
        return 0;
      }
      return 1;
    },
    exceptionalReturn: 1,
  );
  try {
    _enumWindows(callback.nativeFunction, 0);
  } finally {
    callback.close();
    arena.releaseAll();
  }
  return found;
}

double? _ppiForMonitor(int monitor) {
  final arena = Arena();
  try {
    final info = arena<_MonitorInfoEx>();
    info.ref.cbSize = sizeOf<_MonitorInfoEx>();
    if (_getMonitorInfo(monitor, info) == 0) return null;
    final deviceName = _utf16(info.ref.device, 32);
    if (deviceName.isEmpty) return null;
    final pixelWidth = _currentPixelWidth(arena, deviceName);
    if (pixelWidth == null) return null;
    final edid = _edidForDevice(arena, deviceName);
    if (edid == null) return null;
    return physicalPpiFromPanel(pixelWidth: pixelWidth, edid: edid);
  } finally {
    arena.releaseAll();
  }
}

int? _currentPixelWidth(Arena arena, String deviceName) {
  final mode = arena<Uint8>(256);
  (mode.cast<Uint16>() + 34).value = 220;
  final name = deviceName.toNativeUtf16(allocator: arena);
  if (_enumDisplaySettings(name, 0xFFFFFFFF, mode) == 0) return null;
  final width = (mode + 172).cast<Uint32>().value;
  if (width < 320) return null;
  return width;
}

Uint8List? _edidForDevice(Arena arena, String deviceName) {
  final device = arena<_DisplayDevice>();
  device.ref.cb = sizeOf<_DisplayDevice>();
  final name = deviceName.toNativeUtf16(allocator: arena);
  const interfaceName = 0x00000001;
  if (_enumDisplayDevices(name, 0, device, interfaceName) == 0) {
    return null;
  }
  final deviceId = _utf16(device.ref.deviceId, 128);
  final parsed = parseDisplayInterfaceId(deviceId);
  if (parsed == null) return null;
  return _readEdid(parsed.hardwareId, parsed.instanceId);
}

Uint8List? _readEdid(String hardwareId, String instanceId) {
  final direct = _queryEdid(
    'SYSTEM\\CurrentControlSet\\Enum\\DISPLAY\\$hardwareId\\$instanceId\\Device Parameters',
  );
  if (direct != null) return direct;

  const hklm = -2147483646;
  final arena = Arena();
  var parent = 0;
  try {
    parent = _openKey(
          arena,
          hklm,
          'SYSTEM\\CurrentControlSet\\Enum\\DISPLAY\\$hardwareId',
        ) ??
        0;
    if (parent == 0) return null;
    for (var index = 0; index < 16; index++) {
      final nameBuf = arena<Uint16>(256);
      final nameLen = arena<Uint32>()..value = 255;
      final status = _regEnumKey(
        parent,
        index,
        nameBuf,
        nameLen,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
      );
      if (status != 0) break;
      final child = nameBuf.cast<Utf16>().toDartString();
      final edid = _queryEdid(
        'SYSTEM\\CurrentControlSet\\Enum\\DISPLAY\\$hardwareId\\$child\\Device Parameters',
      );
      if (edid != null) return edid;
    }
  } finally {
    if (parent != 0) _regClose(parent);
    arena.releaseAll();
  }
  return null;
}

Uint8List? _queryEdid(String path) {
  const hklm = -2147483646;
  final arena = Arena();
  var key = 0;
  try {
    key = _openKey(arena, hklm, path) ?? 0;
    if (key == 0) return null;
    final size = arena<Uint32>();
    final type = arena<Uint32>();
    final name = 'EDID'.toNativeUtf16(allocator: arena);
    var status = _regQuery(key, name, nullptr, type, nullptr, size);
    if ((status != 0 && status != 234) || size.value == 0 || size.value > 1024) {
      return null;
    }
    final data = arena<Uint8>(size.value);
    status = _regQuery(key, name, nullptr, type, data, size);
    if (status != 0 || type.value != 3) return null;
    return Uint8List.fromList(data.asTypedList(size.value));
  } finally {
    if (key != 0) _regClose(key);
    arena.releaseAll();
  }
}

int? _openKey(Arena arena, int parent, String path) {
  final out = arena<IntPtr>();
  final status = _regOpen(
    parent,
    path.toNativeUtf16(allocator: arena),
    0,
    0x20019,
    out,
  );
  if (status != 0 || out.value == 0) return null;
  return out.value;
}

String _utf16(Array<Uint16> data, int max) {
  final codes = <int>[];
  for (var i = 0; i < max; i++) {
    final unit = data[i];
    if (unit == 0) break;
    codes.add(unit);
  }
  return String.fromCharCodes(codes);
}
