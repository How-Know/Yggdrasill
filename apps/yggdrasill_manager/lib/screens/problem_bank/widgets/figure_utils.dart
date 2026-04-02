import '../problem_bank_models.dart';

const double figureScaleMin = 0.3;
const double figureScaleMax = 2.2;
const double figureWidthEmMin = 5.0;
const double figureWidthEmMax = 30.0;
const double figureWidthEmDefault = 15.5;
const double defaultStemSizePt = 11.0;
const double defaultMaxHeightPt = 170.0;

const List<String> figurePositionOptions = <String>[
  'below-stem',
  'inline-right',
  'inline-left',
  'between-stem-choices',
  'above-choices',
];

const Map<String, String> figurePositionLabels = <String, String>{
  'below-stem': '본문 아래',
  'inline-right': '본문 오른쪽',
  'inline-left': '본문 왼쪽',
  'between-stem-choices': '본문-보기 사이',
  'above-choices': '보기 위',
};

List<Map<String, dynamic>> figureAssetsOf(ProblemBankQuestion q) {
  final raw = q.meta['figure_assets'];
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw
      .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(
            (e as Map).map((k, dynamic v) => MapEntry('$k', v)),
          ))
      .toList(growable: false);
}

Map<String, dynamic>? latestFigureAssetOf(ProblemBankQuestion q) {
  final assets = figureAssetsOf(q);
  if (assets.isEmpty) return null;
  assets.sort((a, b) {
    final aa = '${a['created_at'] ?? ''}';
    final bb = '${b['created_at'] ?? ''}';
    return bb.compareTo(aa);
  });
  return assets.first;
}

List<Map<String, dynamic>> orderedFigureAssetsOf(ProblemBankQuestion q) {
  final assets = figureAssetsOf(q);
  if (assets.isEmpty) return assets;
  assets.sort((a, b) {
    final aa = '${a['created_at'] ?? ''}';
    final bb = '${b['created_at'] ?? ''}';
    return bb.compareTo(aa);
  });
  final byIndex = <int, Map<String, dynamic>>{};
  for (final asset in assets) {
    final index = int.tryParse('${asset['figure_index'] ?? ''}');
    if (index == null || index <= 0) continue;
    byIndex.putIfAbsent(index, () => asset);
  }
  if (byIndex.isNotEmpty) {
    final keys = byIndex.keys.toList()..sort();
    return keys.map((k) => byIndex[k]!).toList(growable: false);
  }
  return <Map<String, dynamic>>[assets.first];
}

bool isFigureAssetApproved(Map<String, dynamic>? asset) {
  if (asset == null) return false;
  return asset['approved'] == true;
}

String figureAssetStateText(Map<String, dynamic>? asset) {
  if (asset == null) return '생성본 없음';
  final approved = isFigureAssetApproved(asset);
  final status = '${asset['status'] ?? ''}'.trim();
  if (approved) return '승인됨';
  if (status.isNotEmpty) return '검수 필요 ($status)';
  return '검수 필요';
}

double scaleToWidthEm(double scale) {
  final safeScale = scale.clamp(figureScaleMin, figureScaleMax);
  final maxHeightPt = defaultMaxHeightPt * safeScale;
  return (maxHeightPt / defaultStemSizePt * 100).roundToDouble() / 100.0;
}

double widthEmToScale(double widthEm) {
  final widthPt =
      widthEm.clamp(figureWidthEmMin, figureWidthEmMax) * defaultStemSizePt;
  final scale = widthPt / defaultMaxHeightPt;
  return scale.clamp(figureScaleMin, figureScaleMax);
}

double normalizeFigureScale(double value) {
  if (!value.isFinite) return 1.0;
  return value.clamp(figureScaleMin, figureScaleMax).toDouble();
}

Map<String, double> figureRenderScaleMapOf(ProblemBankQuestion q) {
  final raw = q.meta['figure_render_scales'];
  if (raw is! Map) return const <String, double>{};
  final out = <String, double>{};
  raw.forEach((key, value) {
    final safeKey = '$key'.trim();
    if (safeKey.isEmpty) return;
    final parsed =
        value is num ? value.toDouble() : double.tryParse('$value');
    if (parsed == null || !parsed.isFinite) return;
    out[safeKey] = normalizeFigureScale(parsed);
  });
  return out;
}

String figureScaleKeyForAsset(Map<String, dynamic>? asset, int order) {
  final index = int.tryParse('${asset?['figure_index'] ?? ''}');
  if (index != null && index > 0) return 'idx:$index';
  final path = '${asset?['path'] ?? ''}'.trim();
  if (path.isNotEmpty) return 'path:$path';
  return 'ord:$order';
}

String figureScaleKeyLabel(String key, int fallbackOrder) {
  if (key.startsWith('idx:')) {
    final n = int.tryParse(key.substring(4));
    if (n != null && n > 0) return '그림 $n';
  }
  if (key.startsWith('ord:')) {
    final n = int.tryParse(key.substring(4));
    if (n != null && n > 0) return '그림 $n';
  }
  return '그림 $fallbackOrder';
}

String figurePairKey(String keyA, String keyB) {
  final a = keyA.trim();
  final b = keyB.trim();
  if (a.isEmpty || b.isEmpty || a == b) return '';
  return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
}

List<String> figurePairParts(String pairKey) {
  final i = pairKey.indexOf('|');
  if (i <= 0 || i >= pairKey.length - 1) return const <String>[];
  final a = pairKey.substring(0, i).trim();
  final b = pairKey.substring(i + 1).trim();
  if (a.isEmpty || b.isEmpty || a == b) return const <String>[];
  return <String>[a, b];
}

Set<String> figureHorizontalPairKeysOf(ProblemBankQuestion q) {
  final raw = q.meta['figure_horizontal_pairs'];
  if (raw is! List) return const <String>{};
  final out = <String>{};
  for (final item in raw) {
    if (item is! Map) continue;
    final map =
        Map<String, dynamic>.from(item.map((k, v) => MapEntry('$k', v)));
    final key = figurePairKey(
      '${map['a'] ?? map['left'] ?? ''}',
      '${map['b'] ?? map['right'] ?? ''}',
    );
    if (key.isNotEmpty) out.add(key);
  }
  return out;
}

List<Map<String, String>> figureHorizontalPairsPayloadOf(
    ProblemBankQuestion q) {
  final pairs = figureHorizontalPairKeysOf(q);
  return pairs
      .map((pairKey) {
        final parts = figurePairParts(pairKey);
        return <String, String>{
          'a': parts.isNotEmpty ? parts[0] : '',
          'b': parts.length >= 2 ? parts[1] : '',
        };
      })
      .where((e) => e['a']!.isNotEmpty && e['b']!.isNotEmpty)
      .toList(growable: false);
}

double figureRenderScaleOf(ProblemBankQuestion q) {
  final raw = q.meta['figure_render_scale'];
  final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (parsed != null && parsed.isFinite) {
    return normalizeFigureScale(parsed);
  }
  final map = figureRenderScaleMapOf(q);
  if (map.isEmpty) return 1.0;
  final avg = map.values.fold<double>(0.0, (sum, v) => sum + v) / map.length;
  return normalizeFigureScale(avg);
}

double figureRenderScaleForAsset(
  ProblemBankQuestion q, {
  Map<String, dynamic>? asset,
  int order = 1,
}) {
  final scaleMap = figureRenderScaleMapOf(q);
  if (scaleMap.isEmpty) return figureRenderScaleOf(q);
  final key = figureScaleKeyForAsset(asset, order);
  final direct = scaleMap[key];
  if (direct != null) return direct;
  final index = int.tryParse('${asset?['figure_index'] ?? ''}');
  if (index != null) {
    final byIndex = scaleMap['idx:$index'];
    if (byIndex != null) return byIndex;
  }
  final path = '${asset?['path'] ?? ''}'.trim();
  if (path.isNotEmpty) {
    final byPath = scaleMap['path:$path'];
    if (byPath != null) return byPath;
  }
  return figureRenderScaleOf(q);
}

String figureRenderScaleLabel(ProblemBankQuestion q) {
  final pct = (figureRenderScaleOf(q) * 100).round();
  return '$pct%';
}
