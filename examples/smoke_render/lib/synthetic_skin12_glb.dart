/// Builds the 12-influence skinned GLB the `skinned_12_influences` smoke scene
/// draws, and the CPU-skinned reference it is compared against.
///
/// The mesh is a tube along +Y bound to twelve joints spaced around a ring.
/// Every vertex weights all twelve, biased per row toward a heading that
/// turns once up the tube, so the blended pose is a corkscrew centered on the
/// Y axis. The joints are split over `JOINTS_0`, `JOINTS_1`, and `JOINTS_2`
/// in ring order, so keeping only the first set (joints 0 to 3, one quarter
/// of the ring) shoves the whole tube toward that quarter instead: the
/// difference reads at a glance.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Rows of the tube along +Y, and the sides of its cross section.
const int _rows = 25;
const int _sides = 10;
const double _rowSpacing = 0.1;
const double _radius = 0.13;

/// Joints on the ring, and the ring radius they translate by.
const int _joints = 12;
const double _jointRing = 1.2;

/// How strongly a row leans toward its heading: weights are
/// `1 + _bias * cos(joint angle - heading)`, so every weight stays positive.
const double _bias = 0.9;

int get _vertexCount => _rows * _sides;

double _jointAngle(int k) => 2 * math.pi * k / _joints;

/// Row [r]'s heading, one full turn from bottom to top.
double _heading(int r) => 2 * math.pi * r / (_rows - 1);

/// The twelve weights of row [r], normalized to sum to 1.
List<double> _rowWeights(int r) {
  final raw = [
    for (var k = 0; k < _joints; k++)
      1 + _bias * math.cos(_jointAngle(k) - _heading(r)),
  ];
  final sum = raw.reduce((a, b) => a + b);
  return [for (final w in raw) w / sum];
}

/// Joint [k]'s translation (its only transform; inverse binds are identity).
List<double> _jointTranslation(int k) => [
  _jointRing * math.cos(_jointAngle(k)),
  0,
  _jointRing * math.sin(_jointAngle(k)),
];

/// Per-row vertex colors, warm at the base to cool at the top, so the
/// corkscrew's turn reads in the frame. Linear values.
List<double> _rowColor(int r) {
  final t = r / (_rows - 1);
  return [
    0.85 - 0.7 * t,
    0.25 + 0.35 * math.sin(math.pi * t),
    0.1 + 0.8 * t,
    1,
  ];
}

/// The tube in glTF source space: positions, normals, colors, and indices.
({
  Float32List positions,
  Float32List normals,
  Float32List colors,
  List<int> indices,
})
_tube() {
  final positions = Float32List(_vertexCount * 3);
  final normals = Float32List(_vertexCount * 3);
  final colors = Float32List(_vertexCount * 4);
  for (var r = 0; r < _rows; r++) {
    for (var s = 0; s < _sides; s++) {
      final v = r * _sides + s;
      final a = 2 * math.pi * s / _sides;
      positions[v * 3] = _radius * math.cos(a);
      positions[v * 3 + 1] = r * _rowSpacing;
      positions[v * 3 + 2] = _radius * math.sin(a);
      normals[v * 3] = math.cos(a);
      normals[v * 3 + 2] = math.sin(a);
      colors.setAll(v * 4, _rowColor(r));
    }
  }
  final indices = <int>[];
  for (var r = 0; r < _rows - 1; r++) {
    for (var s = 0; s < _sides; s++) {
      final a = r * _sides + s;
      final b = r * _sides + (s + 1) % _sides;
      // Counter-clockwise seen from outside the tube.
      indices.addAll([a, a + _sides, b]);
      indices.addAll([b, a + _sides, b + _sides]);
    }
  }
  return (
    positions: positions,
    normals: normals,
    colors: colors,
    indices: indices,
  );
}

/// Builds the GLB bytes. With [influenceSets] 1 only `JOINTS_0`/`WEIGHTS_0`
/// are written, the mesh a 4-influence importer would see.
Uint8List buildSkin12Glb({int influenceSets = 3}) {
  final tube = _tube();
  final joints = [
    for (var s = 0; s < influenceSets; s++) Uint8List(_vertexCount * 4),
  ];
  final weights = [
    for (var s = 0; s < influenceSets; s++) Float32List(_vertexCount * 4),
  ];
  for (var r = 0; r < _rows; r++) {
    final w = _rowWeights(r);
    for (var s = 0; s < _sides; s++) {
      final v = r * _sides + s;
      for (var k = 0; k < 4 * influenceSets; k++) {
        joints[k ~/ 4][v * 4 + k % 4] = k;
        weights[k ~/ 4][v * 4 + k % 4] = w[k];
      }
    }
  }

  final builder = _GlbBuilder();
  final attributes = <String, int>{
    'POSITION': builder.addFloats(tube.positions, 'VEC3', minMax: true),
    'NORMAL': builder.addFloats(tube.normals, 'VEC3'),
    'COLOR_0': builder.addFloats(tube.colors, 'VEC4'),
    for (var s = 0; s < influenceSets; s++) ...{
      'JOINTS_$s': builder.addJoints(joints[s]),
      'WEIGHTS_$s': builder.addFloats(weights[s], 'VEC4'),
    },
  };
  final indexAccessor = builder.addIndices(tube.indices);
  return builder.finish({
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {
        'nodes': [0, for (var k = 0; k < _joints; k++) k + 1],
      },
    ],
    'nodes': [
      {'name': 'Skin12Tube', 'mesh': 0, 'skin': 0},
      for (var k = 0; k < _joints; k++)
        {'name': 'Joint$k', 'translation': _jointTranslation(k)},
    ],
    'skins': [
      {
        'joints': [for (var k = 0; k < _joints; k++) k + 1],
      },
    ],
    'meshes': [
      {
        'name': 'Skin12Tube',
        'primitives': [
          {
            'attributes': attributes,
            'indices': indexAccessor,
            'material': 0,
            'mode': 4,
          },
        ],
      },
    ],
    'materials': [
      {
        'name': 'Skin12Tube',
        'pbrMetallicRoughness': {
          'baseColorFactor': [1, 1, 1, 1],
          'metallicFactor': 0.0,
          'roughnessFactor': 0.55,
        },
      },
    ],
  });
}

/// The tube skinned on the CPU with all twelve influences, in native scene
/// space (Z negated, winding reversed to stay counter-clockwise), for an
/// unskinned mesh the GPU-skinned copies must match. Joints only translate,
/// so the rest normals are the skinned normals.
({
  Float32List positions,
  Float32List normals,
  Float32List colors,
  List<int> indices,
})
skin12Reference() {
  final tube = _tube();
  final positions = Float32List(_vertexCount * 3);
  final normals = Float32List(_vertexCount * 3);
  for (var r = 0; r < _rows; r++) {
    final w = _rowWeights(r);
    var dx = 0.0, dz = 0.0;
    for (var k = 0; k < _joints; k++) {
      final t = _jointTranslation(k);
      dx += w[k] * t[0];
      dz += w[k] * t[2];
    }
    for (var s = 0; s < _sides; s++) {
      final v = r * _sides + s;
      positions[v * 3] = tube.positions[v * 3] + dx;
      positions[v * 3 + 1] = tube.positions[v * 3 + 1];
      positions[v * 3 + 2] = -(tube.positions[v * 3 + 2] + dz);
      normals[v * 3] = tube.normals[v * 3];
      normals[v * 3 + 2] = -tube.normals[v * 3 + 2];
    }
  }
  final indices = [
    for (var i = 0; i < tube.indices.length; i += 3) ...[
      tube.indices[i],
      tube.indices[i + 2],
      tube.indices[i + 1],
    ],
  ];
  return (
    positions: positions,
    normals: normals,
    colors: tube.colors,
    indices: indices,
  );
}

/// Accumulates accessors into one GLB binary chunk.
class _GlbBuilder {
  final BytesBuilder _binary = BytesBuilder();
  final List<Map<String, Object?>> _views = [];
  final List<Map<String, Object?>> _accessors = [];

  int _addView(TypedData data) {
    while (_binary.length % 4 != 0) {
      _binary.addByte(0);
    }
    final bytes = Uint8List.sublistView(data);
    _views.add({
      'buffer': 0,
      'byteOffset': _binary.length,
      'byteLength': bytes.length,
    });
    _binary.add(bytes);
    return _views.length - 1;
  }

  int addFloats(Float32List values, String type, {bool minMax = false}) {
    final stride = type == 'VEC3' ? 3 : 4;
    final count = values.length ~/ stride;
    final accessor = <String, Object?>{
      'bufferView': _addView(values),
      'componentType': 5126,
      'count': count,
      'type': type,
    };
    if (minMax) {
      final min = List<double>.filled(stride, double.infinity);
      final max = List<double>.filled(stride, double.negativeInfinity);
      for (var i = 0; i < count; i++) {
        for (var c = 0; c < stride; c++) {
          min[c] = math.min(min[c], values[i * stride + c]);
          max[c] = math.max(max[c], values[i * stride + c]);
        }
      }
      accessor['min'] = min;
      accessor['max'] = max;
    }
    _accessors.add(accessor);
    return _accessors.length - 1;
  }

  int addJoints(Uint8List values) {
    _accessors.add({
      'bufferView': _addView(values),
      'componentType': 5121,
      'count': values.length ~/ 4,
      'type': 'VEC4',
    });
    return _accessors.length - 1;
  }

  int addIndices(List<int> values) {
    _accessors.add({
      'bufferView': _addView(Uint16List.fromList(values)),
      'componentType': 5123,
      'count': values.length,
      'type': 'SCALAR',
    });
    return _accessors.length - 1;
  }

  Uint8List finish(Map<String, Object?> json) {
    final binary = _binary.toBytes();
    final document = <String, Object?>{
      ...json,
      'buffers': [
        {'byteLength': binary.length},
      ],
      'bufferViews': _views,
      'accessors': _accessors,
    };
    final jsonBytes = utf8.encode(jsonEncode(document));
    final jsonLength = (jsonBytes.length + 3) & ~3;
    final binaryLength = (binary.length + 3) & ~3;
    final output = BytesBuilder();
    void uint32(int value) => output.add(
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little),
    );
    output.add(ascii.encode('glTF'));
    uint32(2);
    uint32(12 + 8 + jsonLength + 8 + binaryLength);
    uint32(jsonLength);
    output.add(ascii.encode('JSON'));
    output.add(jsonBytes);
    final pad = jsonLength - jsonBytes.length;
    output.add(Uint8List(pad)..fillRange(0, pad, 0x20));
    uint32(binaryLength);
    output.add([0x42, 0x49, 0x4e, 0]);
    output.add(binary);
    output.add(Uint8List(binaryLength - binary.length));
    return output.takeBytes();
  }
}
