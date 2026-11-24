import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 밝기만 가진 그림(0=검정, 255=흰색). 원본과 겹쳐 보거나 선 굵기를 잴 때 쓴다.
class GrayMap {
  GrayMap(this.width, this.height, [Uint8List? data]) : data = data ?? Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List data;

  static GrayMap readPng(String path) => fromImage(img.decodePng(File(path).readAsBytesSync())!);

  static GrayMap fromImage(img.Image image) {
    final out = GrayMap(image.width, image.height);
    var i = 0;
    for (final px in image) {
      // 투명한 곳은 흰 종이로 본다.
      final a = image.numChannels == 4 || image.numChannels == 2 ? px.a / px.maxChannelValue : 1.0;
      final l = image.numChannels >= 3 ? (px.r * 0.299 + px.g * 0.587 + px.b * 0.114) : px.r.toDouble();
      final scaled = l / px.maxChannelValue * 255;
      out.data[i++] = (scaled * a + 255 * (1 - a)).round().clamp(0, 255);
    }
    return out;
  }

  int at(int x, int y) => data[y * width + x];

  img.Image toImage() {
    final out = img.Image(width: width, height: height, numChannels: 1);
    var i = 0;
    for (final px in out) {
      px.r = data[i++];
    }
    return out;
  }
}

/// 가장 가까운 잉크(어두운 점)까지의 거리를 픽셀 단위로 낸다. [invert] 면 잉크 안에서
/// 가장 가까운 종이까지의 거리.
Float32List distanceToInk(GrayMap map, {int threshold = 128, bool invert = false}) {
  final w = map.width, h = map.height;
  const inf = 1e20;
  final grid = Float64List(w * h);
  for (var i = 0; i < grid.length; i++) {
    final ink = map.data[i] < threshold;
    grid[i] = (ink != invert) ? 0 : inf;
  }
  final n = math.max(w, h);
  final f = Float64List(n), d = Float64List(n), z = Float64List(n + 1);
  final v = Int32List(n);
  void pass(int len, double Function(int) read, void Function(int, double) write) {
    for (var i = 0; i < len; i++) {
      f[i] = read(i);
    }
    var k = 0;
    v[0] = 0;
    z[0] = -inf;
    z[1] = inf;
    for (var q = 1; q < len; q++) {
      double s;
      while (true) {
        final p = v[k];
        s = ((f[q] + q * q) - (f[p] + p * p)) / (2.0 * q - 2.0 * p);
        if (s <= z[k] && k > 0) {
          k--;
        } else {
          break;
        }
      }
      k++;
      v[k] = q;
      z[k] = s;
      z[k + 1] = inf;
    }
    k = 0;
    for (var q = 0; q < len; q++) {
      while (z[k + 1] < q) {
        k++;
      }
      final p = v[k];
      d[q] = (q - p) * (q - p) + f[p];
    }
    for (var i = 0; i < len; i++) {
      write(i, d[i]);
    }
  }

  for (var x = 0; x < w; x++) {
    pass(h, (y) => grid[y * w + x], (y, val) => grid[y * w + x] = val);
  }
  for (var y = 0; y < h; y++) {
    final row = y * w;
    pass(w, (x) => grid[row + x], (x, val) => grid[row + x] = val);
  }
  final out = Float32List(w * h);
  for (var i = 0; i < out.length; i++) {
    out[i] = math.sqrt(math.min(grid[i], 1e12));
  }
  return out;
}
