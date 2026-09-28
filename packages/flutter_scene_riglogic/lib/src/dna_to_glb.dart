// Converts DNA geometry and skeleton to a skinned glTF binary that
// flutter_scene's importer loads. Pure Dart; the DNA is read elsewhere.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import 'dna_host.dart';

/// The most influences the converter writes per vertex (three glTF
/// JOINTS/WEIGHTS sets). flutter_scene reads the first set today; more need
/// its multi-influence skinning.
const maxConvertedInfluences = 12;

/// Converts [dna] to GLB bytes: a skeleton in the neutral pose (glTF axes,
/// metres) and one skinned mesh node per DNA mesh drawn by any of [lods]
/// (all LODs when null). Mesh nodes are named after the DNA meshes.
Uint8List dnaToGlb(DnaHostData dna, {String name = 'dna', List<int>? lods}) {
  final axes = _axisMatrix(dna.axes);
  final unit = dna.translationUnit == 0 ? 0.01 : 1.0;
  final jointCount = dna.jointNames.length;
  final writer = _GlbWriter();

  // Joints: local TRS from RigLogic's neutral values, converted to glTF axes.
  final translations = <vm.Vector3>[];
  final rotations = <vm.Quaternion>[];
  final scales = <vm.Vector3>[];
  for (var j = 0; j < jointCount; j++) {
    final v = dna.neutralJointValues.sublist(10 * j, 10 * j + 10);
    translations.add(axes.transformed(vm.Vector3(v[0], v[1], v[2]))..scale(unit));
    final axis = axes.transformed(vm.Vector3(v[3], v[4], v[5]));
    rotations.add(vm.Quaternion(axis.x, axis.y, axis.z, v[6])..normalize());
    final s = _absolute(axes).transformed(vm.Vector3(v[7], v[8], v[9]));
    scales.add(s);
  }
  final world = List<vm.Matrix4?>.filled(jointCount, null);
  vm.Matrix4 worldOf(int j) {
    final cached = world[j];
    if (cached != null) return cached;
    final local = vm.Matrix4.compose(translations[j], rotations[j], scales[j]);
    final parent = dna.jointParents[j];
    return world[j] = parent < 0 ? local : worldOf(parent) * local;
  }

  final inverseBind = Float32List(16 * jointCount);
  for (var j = 0; j < jointCount; j++) {
    final inverse = vm.Matrix4.inverted(worldOf(j));
    inverseBind.setAll(16 * j, inverse.storage);
  }

  final jointNodeBase = 1;
  final nodes = <Map<String, Object?>>[
    {'name': name, 'children': <int>[]},
  ];
  for (var j = 0; j < jointCount; j++) {
    final t = translations[j], q = rotations[j], s = scales[j];
    final children = [
      for (var c = 0; c < jointCount; c++)
        if (dna.jointParents[c] == j) jointNodeBase + c,
    ];
    nodes.add({
      'name': dna.jointNames[j],
      'translation': [t.x, t.y, t.z],
      'rotation': [q.x, q.y, q.z, q.w],
      'scale': [s.x, s.y, s.z],
      if (children.isNotEmpty) 'children': children,
    });
  }
  final rootChildren = nodes[0]['children']! as List<int>;
  for (var j = 0; j < jointCount; j++) {
    if (dna.jointParents[j] < 0) rootChildren.add(jointNodeBase + j);
  }
  final skin = {
    'joints': [for (var j = 0; j < jointCount; j++) jointNodeBase + j],
    'inverseBindMatrices': writer.accessor(inverseBind, 'MAT4', _float),
  };

  final wanted = <int>{
    for (var lod = 0; lod < dna.lodMeshes.length; lod++)
      if (lods == null || lods.contains(lod)) ...dna.lodMeshes[lod],
  }.toList()
    ..sort();
  final meshes = <Map<String, Object?>>[];
  final materials = <Map<String, Object?>>[
    {'name': 'dna_skin', 'pbrMetallicRoughness': {'baseColorFactor': [0.82, 0.64, 0.56, 1.0], 'metallicFactor': 0.0, 'roughnessFactor': 0.55}},
    {'name': 'dna_eye', 'pbrMetallicRoughness': {'baseColorFactor': [0.95, 0.95, 0.97, 1.0], 'metallicFactor': 0.0, 'roughnessFactor': 0.2}},
  ];
  for (final index in wanted) {
    final mesh = dna.meshes[index];
    meshes.add(_mesh(writer, mesh, axes, unit, mesh.name.toLowerCase().contains('eye') ? 1 : 0));
    rootChildren.add(nodes.length);
    nodes.add({'name': mesh.name, 'mesh': meshes.length - 1, 'skin': 0});
  }

  final gltf = {
    'asset': {'version': '2.0', 'generator': 'flutter_scene_riglogic'},
    'scene': 0,
    'scenes': [
      {'nodes': [0]},
    ],
    'nodes': nodes,
    'skins': [skin],
    'meshes': meshes,
    'materials': materials,
    ...writer.finish(),
  };
  return writer.glb(gltf);
}

Map<String, Object?> _mesh(_GlbWriter writer, DnaHostMesh mesh, vm.Matrix3 axes, double unit, int material) {
  final vertexCount = mesh.layouts.length ~/ 3;
  final positions = Float32List(3 * vertexCount);
  final normals = Float32List(3 * vertexCount);
  final uvs = Float32List(2 * vertexCount);
  final sets = math.max(1, (math.min(mesh.maxInfluences, maxConvertedInfluences) + 3) ~/ 4);
  final joints = List.generate(sets, (_) => Uint16List(4 * vertexCount));
  final weights = List.generate(sets, (_) => Float32List(4 * vertexCount));
  for (var v = 0; v < vertexCount; v++) {
    final p = mesh.layouts[3 * v], t = mesh.layouts[3 * v + 1], n = mesh.layouts[3 * v + 2];
    final position = axes.transformed(vm.Vector3(mesh.positions[3 * p], mesh.positions[3 * p + 1], mesh.positions[3 * p + 2]))
      ..scale(unit);
    positions.setAll(3 * v, [position.x, position.y, position.z]);
    final normal = axes.transformed(vm.Vector3(mesh.normals[3 * n], mesh.normals[3 * n + 1], mesh.normals[3 * n + 2]))
      ..normalize();
    normals.setAll(3 * v, [normal.x, normal.y, normal.z]);
    // DNA texture coordinates start at the bottom left; glTF's at the top left.
    uvs.setAll(2 * v, [mesh.textureCoordinates[2 * t], 1 - mesh.textureCoordinates[2 * t + 1]]);

    // Heaviest influences first, so a reader of only the first set gets the
    // best four; renormalized over the kept ones.
    final order = List.generate(mesh.skinWeights[p].length, (i) => i)
      ..sort((a, b) => mesh.skinWeights[p][b].compareTo(mesh.skinWeights[p][a]));
    final kept = order.take(4 * sets).toList();
    final total = kept.fold(0.0, (sum, i) => sum + mesh.skinWeights[p][i]);
    for (var k = 0; k < kept.length; k++) {
      joints[k ~/ 4][4 * v + k % 4] = mesh.skinJoints[p][kept[k]];
      weights[k ~/ 4][4 * v + k % 4] = total > 0 ? mesh.skinWeights[p][kept[k]] / total : 0;
    }
  }
  final indices = <int>[];
  for (final face in mesh.faces) {
    for (var i = 1; i + 1 < face.length; i++) {
      indices.addAll([face[0], face[i], face[i + 1]]);
    }
  }
  final attributes = <String, int>{
    'POSITION': writer.accessor(positions, 'VEC3', _float, bounds: true),
    'NORMAL': writer.accessor(normals, 'VEC3', _float),
    'TEXCOORD_0': writer.accessor(uvs, 'VEC2', _float),
    for (var s = 0; s < sets; s++) ...{
      'JOINTS_$s': writer.accessor(joints[s], 'VEC4', _unsignedShort),
      'WEIGHTS_$s': writer.accessor(weights[s], 'VEC4', _float),
    },
  };
  return {
    'name': mesh.name,
    'primitives': [
      {
        'attributes': attributes,
        'indices': writer.accessor(Uint32List.fromList(indices), 'SCALAR', _unsignedInt, target: 34963),
        'material': material,
      },
    ],
  };
}

/// DNA axes to glTF axes (x the character's left, y up, z front). The
/// columns are where each DNA axis points in glTF.
vm.Matrix3 _axisMatrix(List<int> axes) {
  vm.Vector3 direction(int axis) => switch (axis) {
        0 => vm.Vector3(1, 0, 0), // left
        1 => vm.Vector3(-1, 0, 0), // right
        2 => vm.Vector3(0, 1, 0), // up
        3 => vm.Vector3(0, -1, 0), // down
        4 => vm.Vector3(0, 0, 1), // front
        5 => vm.Vector3(0, 0, -1), // back
        _ => throw FormatException('Unknown DNA axis direction $axis'),
      };
  final m = vm.Matrix3.columns(direction(axes[0]), direction(axes[1]), direction(axes[2]));
  if ((m.determinant() - 1).abs() > 1e-6) {
    throw UnsupportedError('DNA coordinate system $axes is mirrored relative to glTF; only rotations are supported.');
  }
  return m;
}

vm.Matrix3 _absolute(vm.Matrix3 m) => vm.Matrix3.fromList([for (final v in m.storage) v.abs()]);

const _float = 5126;
const _unsignedShort = 5123;
const _unsignedInt = 5125;

class _GlbWriter {
  final _bytes = BytesBuilder();
  final _views = <Map<String, Object?>>[];
  final _accessors = <Map<String, Object?>>[];

  int accessor(TypedData data, String type, int componentType, {bool bounds = false, int? target}) {
    while (_bytes.length % 4 != 0) {
      _bytes.addByte(0);
    }
    final offset = _bytes.length;
    final view = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    _bytes.add(view);
    _views.add({'buffer': 0, 'byteOffset': offset, 'byteLength': view.length, 'target': ?target});
    final width = const {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[type]!;
    final elements = data.lengthInBytes ~/ data.elementSizeInBytes;
    final accessor = <String, Object?>{
      'bufferView': _views.length - 1,
      'componentType': componentType,
      'count': elements ~/ width,
      'type': type,
    };
    if (bounds && data is Float32List) {
      final min = List.filled(width, double.infinity), max = List.filled(width, double.negativeInfinity);
      for (var i = 0; i < elements; i++) {
        min[i % width] = math.min(min[i % width], data[i]);
        max[i % width] = math.max(max[i % width], data[i]);
      }
      accessor['min'] = min;
      accessor['max'] = max;
    }
    _accessors.add(accessor);
    return _accessors.length - 1;
  }

  Map<String, Object?> finish() => {
        'buffers': [
          {'byteLength': _bytes.length},
        ],
        'bufferViews': _views,
        'accessors': _accessors,
      };

  Uint8List glb(Map<String, Object?> gltf) {
    var json = utf8.encode(jsonEncode(gltf));
    final jsonPadding = (4 - json.length % 4) % 4;
    json = Uint8List.fromList([...json, ...List.filled(jsonPadding, 0x20)]);
    final bin = _bytes.takeBytes();
    final binPadding = (4 - bin.length % 4) % 4;
    final total = 12 + 8 + json.length + 8 + bin.length + binPadding;
    final out = BytesBuilder()
      ..add(_u32([0x46546C67, 2, total]))
      ..add(_u32([json.length, 0x4E4F534A]))
      ..add(json)
      ..add(_u32([bin.length + binPadding, 0x004E4942]))
      ..add(bin)
      ..add(List.filled(binPadding, 0));
    return out.takeBytes();
  }

  static Uint8List _u32(List<int> values) {
    final data = ByteData(4 * values.length);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(4 * i, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
