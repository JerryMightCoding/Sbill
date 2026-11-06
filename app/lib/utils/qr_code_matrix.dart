import 'dart:convert';
import 'dart:typed_data';

/// Standard ISO/IEC 18004 QR Code encoder (Byte mode, Error Correction Level L, Versions 1..20).
/// Produces a scannable boolean matrix where `true` is a dark module.
class QrCodeMatrix {
  QrCodeMatrix._(this.version, this.size, this.modules);

  final int version;
  final int size;
  final List<List<bool>> modules;

  // Total data codewords for versions 1..20 at Error Correction Level L,
  // and block structure: [totalDataCodewords, ecCodewordsPerBlock, numBlocksGroup1, dataCodewordsGroup1, numBlocksGroup2, dataCodewordsGroup2]
  static const List<List<int>> _vTableL = [
    [], // v0 unused
    [19, 7, 1, 19, 0, 0],
    [34, 10, 1, 34, 0, 0],
    [55, 15, 1, 55, 0, 0],
    [80, 20, 1, 80, 0, 0],
    [108, 26, 1, 108, 0, 0],
    [136, 18, 2, 68, 0, 0],
    [156, 20, 2, 78, 0, 0],
    [194, 24, 2, 97, 0, 0],
    [232, 30, 2, 116, 0, 0],
    [274, 18, 2, 68, 2, 69],
    [324, 20, 4, 81, 0, 0],
    [370, 24, 2, 92, 2, 93],
    [428, 26, 4, 107, 0, 0],
    [461, 30, 3, 115, 1, 116],
    [523, 22, 5, 87, 1, 88],
    [589, 24, 5, 98, 1, 99],
    [647, 28, 1, 107, 5, 108],
    [721, 30, 5, 120, 1, 121],
    [795, 28, 3, 113, 4, 114],
    [861, 28, 3, 107, 5, 108],
  ];

  static const List<List<int>> _alignCenters = [
    [],
    [],
    [6, 18],
    [6, 22],
    [6, 26],
    [6, 30],
    [6, 34],
    [6, 22, 38],
    [6, 24, 42],
    [6, 26, 46],
    [6, 28, 50],
    [6, 30, 54],
    [6, 32, 58],
    [6, 34, 62],
    [6, 26, 46, 66],
    [6, 26, 48, 70],
    [6, 26, 50, 74],
    [6, 30, 54, 78],
    [6, 30, 56, 82],
    [6, 30, 58, 86],
    [6, 34, 62, 90],
  ];

  static QrCodeMatrix encodeText(String text) {
    final data = utf8.encode(text);
    return encodeBytes(Uint8List.fromList(data));
  }

  static QrCodeMatrix encodeBytes(Uint8List data) {
    int version = 1;
    while (version <= 20) {
      final capBits = _vTableL[version][0] * 8;
      final headerBits = 4 + (version <= 9 ? 8 : 16);
      if (headerBits + data.length * 8 <= capBits) {
        break;
      }
      version++;
    }
    if (version > 20) {
      throw ArgumentError('QR payload too large (${data.length} bytes)');
    }

    final spec = _vTableL[version];
    final totalDataCodewords = spec[0];
    final bits = <int>[];
    void pushBits(int val, int len) {
      for (var i = len - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    // Byte mode indicator (0100)
    pushBits(0x4, 4);
    pushBits(data.length, version <= 9 ? 8 : 16);
    for (final b in data) {
      pushBits(b, 8);
    }

    final maxBits = totalDataCodewords * 8;
    final term = (maxBits - bits.length).clamp(0, 4);
    pushBits(0, term);
    while (bits.length % 8 != 0) {
      bits.add(0);
    }

    final dataBytes = Uint8List(totalDataCodewords);
    final byteLen = bits.length ~/ 8;
    for (var i = 0; i < byteLen; i++) {
      var v = 0;
      for (var j = 0; j < 8; j++) {
        v = (v << 1) | bits[i * 8 + j];
      }
      dataBytes[i] = v;
    }
    const padBytes = [0xEC, 0x11];
    for (var i = byteLen; i < totalDataCodewords; i++) {
      dataBytes[i] = padBytes[(i - byteLen) & 1];
    }

    final codewords = _interleaveWithEc(dataBytes, spec);
    final size = version * 4 + 17;
    final modules = List.generate(size, (_) => List<bool>.filled(size, false));
    final isFunction = List.generate(size, (_) => List<bool>.filled(size, false));

    _drawFunctionPatterns(version, size, modules, isFunction);
    _drawCodewords(size, modules, isFunction, codewords);

    // Choose mask 0 (checkerboard `(r + c) % 2 == 0`) and write format information
    _applyMask0(size, modules, isFunction);
    _drawFormatBits(size, modules, isFunction, mask: 0);
    if (version >= 7) {
      _drawVersionBits(version, size, modules, isFunction);
    }

    return QrCodeMatrix._(version, size, modules);
  }

  static Uint8List _interleaveWithEc(Uint8List data, List<int> spec) {
    final ecLen = spec[1];
    final g1Blocks = spec[2];
    final g1Len = spec[3];
    final g2Blocks = spec[4];
    final g2Len = spec[5];

    final dataBlocks = <Uint8List>[];
    final ecBlocks = <Uint8List>[];
    final gen = _rsGeneratorPoly(ecLen);
    var offset = 0;

    for (var i = 0; i < g1Blocks; i++) {
      final blk = Uint8List.sublistView(data, offset, offset + g1Len);
      offset += g1Len;
      dataBlocks.add(blk);
      ecBlocks.add(_rsComputeRemainder(blk, gen));
    }
    for (var i = 0; i < g2Blocks; i++) {
      final blk = Uint8List.sublistView(data, offset, offset + g2Len);
      offset += g2Len;
      dataBlocks.add(blk);
      ecBlocks.add(_rsComputeRemainder(blk, gen));
    }

    final out = <int>[];
    final maxDataLen = g2Blocks > 0 ? g2Len : g1Len;
    for (var i = 0; i < maxDataLen; i++) {
      for (final blk in dataBlocks) {
        if (i < blk.length) out.add(blk[i]);
      }
    }
    for (var i = 0; i < ecLen; i++) {
      for (final blk in ecBlocks) {
        out.add(blk[i]);
      }
    }
    return Uint8List.fromList(out);
  }

  static Uint8List _rsGeneratorPoly(int degree) {
    final result = Uint8List(degree);
    result[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _gfMultiply(result[j], root);
        if (j + 1 < degree) {
          result[j] ^= result[j + 1];
        }
      }
      root = _gfMultiply(root, 0x02);
    }
    return result;
  }

  static Uint8List _rsComputeRemainder(Uint8List data, Uint8List gen) {
    final res = Uint8List(gen.length);
    for (final b in data) {
      final factor = b ^ res[0];
      for (var i = 0; i < gen.length - 1; i++) {
        res[i] = res[i + 1];
      }
      res[gen.length - 1] = 0;
      for (var i = 0; i < gen.length; i++) {
        res[i] ^= _gfMultiply(gen[i], factor);
      }
    }
    return res;
  }

  static int _gfMultiply(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }

  static void _setFunctionModule(
    int r,
    int c,
    bool dark,
    List<List<bool>> modules,
    List<List<bool>> isFunction,
  ) {
    modules[r][c] = dark;
    isFunction[r][c] = true;
  }

  static void _drawFunctionPatterns(
    int version,
    int size,
    List<List<bool>> modules,
    List<List<bool>> isFunction,
  ) {
    for (var i = 0; i < size; i++) {
      _setFunctionModule(6, i, i.isEven, modules, isFunction);
      _setFunctionModule(i, 6, i.isEven, modules, isFunction);
    }

    void drawFinder(int cr, int cc) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final r = cr + dy;
          final c = cc + dx;
          if (r >= 0 && r < size && c >= 0 && c < size) {
            final dist = dy.abs() > dx.abs() ? dy.abs() : dx.abs();
            _setFunctionModule(
              r,
              c,
              dist != 2 && dist != 4,
              modules,
              isFunction,
            );
          }
        }
      }
    }

    drawFinder(3, 3);
    drawFinder(3, size - 4);
    drawFinder(size - 4, 3);

    final centers = _alignCenters[version];
    for (var i = 0; i < centers.length; i++) {
      for (var j = 0; j < centers.length; j++) {
        if ((i == 0 && j == 0) ||
            (i == 0 && j == centers.length - 1) ||
            (i == centers.length - 1 && j == 0)) {
          continue;
        }
        final cr = centers[i];
        final cc = centers[j];
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            final dist = dy.abs() > dx.abs() ? dy.abs() : dx.abs();
            _setFunctionModule(cr + dy, cc + dx, dist != 1, modules, isFunction);
          }
        }
      }
    }

    // Reserve format areas
    for (var i = 0; i <= 8; i++) {
      if (i != 6) {
        _setFunctionModule(8, i, false, modules, isFunction);
        _setFunctionModule(i, 8, false, modules, isFunction);
      }
    }
    for (var i = 0; i < 8; i++) {
      _setFunctionModule(8, size - 1 - i, false, modules, isFunction);
      _setFunctionModule(size - 1 - i, 8, false, modules, isFunction);
    }
    _setFunctionModule(size - 8, 8, true, modules, isFunction);

    if (version >= 7) {
      for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 3; j++) {
          _setFunctionModule(size - 11 + j, i, false, modules, isFunction);
          _setFunctionModule(i, size - 11 + j, false, modules, isFunction);
        }
      }
    }
  }

  static void _drawCodewords(
    int size,
    List<List<bool>> modules,
    List<List<bool>> isFunction,
    Uint8List codewords,
  ) {
    var bitIdx = 0;
    final totalBits = codewords.length * 8;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final c = right - j;
          final upward = ((right + 1) & 2) == 0;
          final r = upward ? size - 1 - vert : vert;
          if (!isFunction[r][c] && bitIdx < totalBits) {
            final dark = ((codewords[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1) != 0;
            modules[r][c] = dark;
            bitIdx++;
          }
        }
      }
    }
  }

  static void _applyMask0(
    int size,
    List<List<bool>> modules,
    List<List<bool>> isFunction,
  ) {
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (!isFunction[r][c] && (r + c).isEven) {
          modules[r][c] = !modules[r][c];
        }
      }
    }
  }

  static void _drawFormatBits(
    int size,
    List<List<bool>> modules,
    List<List<bool>> isFunction, {
    required int mask,
  }) {
    // Error correction level L = 01
    final data = (1 << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = ((data << 10) | rem) ^ 0x5412;
    bool bit(int i) => ((bits >> i) & 1) != 0;

    for (var i = 0; i <= 5; i++) {
      _setFunctionModule(8, i, bit(i), modules, isFunction);
    }
    _setFunctionModule(8, 7, bit(6), modules, isFunction);
    _setFunctionModule(8, 8, bit(7), modules, isFunction);
    _setFunctionModule(7, 8, bit(8), modules, isFunction);
    for (var i = 9; i < 15; i++) {
      _setFunctionModule(14 - i, 8, bit(i), modules, isFunction);
    }

    for (var i = 0; i < 8; i++) {
      _setFunctionModule(8, size - 1 - i, bit(i), modules, isFunction);
    }
    for (var i = 8; i < 15; i++) {
      _setFunctionModule(size - 15 + i, 8, bit(i), modules, isFunction);
    }
    _setFunctionModule(size - 8, 8, true, modules, isFunction);
  }

  static void _drawVersionBits(
    int version,
    int size,
    List<List<bool>> modules,
    List<List<bool>> isFunction,
  ) {
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = (version << 12) | rem;
    for (var i = 0; i < 18; i++) {
      final dark = ((bits >> i) & 1) != 0;
      final a = size - 11 + (i % 3);
      final b = i ~/ 3;
      _setFunctionModule(a, b, dark, modules, isFunction);
      _setFunctionModule(b, a, dark, modules, isFunction);
    }
  }
}
