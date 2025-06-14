import 'dart:html' as html;
import 'dart:convert';

class Window {
  final Storage localStorage = Storage();
}

class Storage {
  final Map<String, String> _data = {};

  operator []=(String key, String? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  String? operator [](String key) => _data[key];
}

final Window window = Window();

Future<void> saveWebData(String filename, dynamic data) async {
  final jsonString = json.encode(data);
  html.window.localStorage[filename] = jsonString;
}

Future<dynamic> loadWebData(String filename) async {
  final jsonString = html.window.localStorage[filename];
  if (jsonString == null) {
    throw Exception('File not found: $filename');
  }
  return json.decode(jsonString);
}

Future<void> saveData(String filename, dynamic data) async {
  window.localStorage[filename] = jsonEncode(data);
}

Future<dynamic> loadData(String filename) async {
  final jsonString = window.localStorage[filename];
  if (jsonString == null) {
    throw Exception('File not found: $filename');
  }
  return jsonDecode(jsonString);
} 