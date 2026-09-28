import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_scene_riglogic/src/dna_host.dart';
import 'package:flutter_scene_riglogic/src/dna_to_glb.dart';
import 'package:test/test.dart';

/// A two-joint DNA in centimetres with one quad, whose first vertex has six
/// influences (more than one glTF set holds).
DnaHostData _dna({List<int> axes = const [0, 2, 4]}) => DnaHostData(
      axes: axes,
      translationUnit: 0,
      jointNames: ['root', 'jaw'],
      jointParents: [-1, 0],
      neutralJointValues: Float32List.fromList([
        0, 0, 0, 0, 0, 0, 1, 1, 1, 1, //
        0, 10, 2, 0, 0, 0, 1, 1, 1, 1,
      ]),
      lodMeshes: [
        [0],
        [1],
      ],
      meshes: [
        DnaHostMesh(
          name: 'head_lod0',
          positions: Float32List.fromList([0, 0, 0, 100, 0, 0, 100, 100, 0, 0, 100, 0]),
          normals: Float32List.fromList([0, 0, 1]),
          textureCoordinates: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
          layouts: Uint32List.fromList([0, 0, 0, 1, 1, 0, 2, 2, 0, 3, 3, 0]),
          faces: [
            Uint32List.fromList([0, 1, 2, 3]),
          ],
          maxInfluences: 6,
          skinWeights: [
            Float32List.fromList([0.05, 0.3, 0.1, 0.2, 0.25, 0.1]),
            Float32List.fromList([1]),
            Float32List.fromList([1]),
            Float32List.fromList([0.5, 0.5]),
          ],
          skinJoints: [
            Uint16List.fromList([0, 1, 0, 1, 0, 1]),
            Uint16List.fromList([0]),
            Uint16List.fromList([1]),
            Uint16List.fromList([0, 1]),
          ],
        ),
        DnaHostMesh(
          name: 'head_lod1',
          positions: Float32List(3),
          normals: Float32List.fromList([0, 0, 1]),
          textureCoordinates: Float32List(2),
          layouts: Uint32List(3),
          faces: const [],
          maxInfluences: 1,
          skinWeights: [Float32List.fromList([1])],
          skinJoints: [Uint16List.fromList([0])],
        ),
      ],
    );

class _Glb {
  _Glb(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(0, Endian.little), 0x46546C67); // glTF
    final length = data.getUint32(12, Endian.little);
    json = jsonDecode(utf8.decode(bytes.sublist(20, 20 + length))) as Map<String, dynamic>;
    binary = ByteData.sublistView(bytes, 20 + length + 8);
  }

  late final Map<String, dynamic> json;
  late final ByteData binary;

  List<num> accessor(int index) {
    final a = (json['accessors'] as List)[index] as Map<String, dynamic>;
    final view = (json['bufferViews'] as List)[a['bufferView'] as int] as Map<String, dynamic>;
    final width = const {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[a['type']]!;
    final offset = (view['byteOffset'] as int? ?? 0) + (a['byteOffset'] as int? ?? 0);
    final count = (a['count'] as int) * width;
    return switch (a['componentType']) {
      5126 => [for (var i = 0; i < count; i++) binary.getFloat32(offset + 4 * i, Endian.little)],
      5123 => [for (var i = 0; i < count; i++) binary.getUint16(offset + 2 * i, Endian.little)],
      5125 => [for (var i = 0; i < count; i++) binary.getUint32(offset + 4 * i, Endian.little)],
      _ => throw StateError('component type ${a['componentType']}'),
    };
  }

  Map<String, dynamic> node(String name) =>
      (json['nodes'] as List).cast<Map<String, dynamic>>().firstWhere((n) => n['name'] == name);

  Map<String, dynamic> attributes(String meshName) {
    final mesh = (json['meshes'] as List)[node(meshName)['mesh'] as int] as Map<String, dynamic>;
    return ((mesh['primitives'] as List).single as Map<String, dynamic>)['attributes'] as Map<String, dynamic>;
  }
}

void main() {
  test('converts the skeleton to metres with inverse bind matrices', () {
    final glb = _Glb(dnaToGlb(_dna(), lods: [0]));
    expect(glb.node('jaw')['translation'], [closeTo(0, 1e-7), closeTo(0.1, 1e-7), closeTo(0.02, 1e-7)]);
    final root = glb.node('root');
    expect(root['children'], [(glb.json['nodes'] as List).indexOf(glb.node('jaw'))]);
    final skin = (glb.json['skins'] as List).single as Map<String, dynamic>;
    final inverse = glb.accessor(skin['inverseBindMatrices'] as int);
    // Column-major; the jaw's inverse bind translates by minus its position.
    expect(inverse.sublist(16 + 12, 16 + 15), [closeTo(0, 1e-7), closeTo(-0.1, 1e-7), closeTo(-0.02, 1e-7)]);
  });

  test('keeps only the requested LODs', () {
    final glb = _Glb(dnaToGlb(_dna(), lods: [0]));
    final names = [for (final n in glb.json['nodes'] as List) (n as Map)['name']];
    expect(names, contains('head_lod0'));
    expect(names, isNot(contains('head_lod1')));
    expect(_Glb(dnaToGlb(_dna())).json['meshes'], hasLength(2));
  });

  test('writes vertices per layout with flipped texture coordinates and fan triangles', () {
    final glb = _Glb(dnaToGlb(_dna(), lods: [0]));
    final attributes = glb.attributes('head_lod0');
    final positions = glb.accessor(attributes['POSITION'] as int);
    expect(positions.sublist(6, 9), [1, 1, 0]);
    expect(glb.accessor(attributes['TEXCOORD_0'] as int), [0, 1, 1, 1, 1, 0, 0, 0]);
    final mesh = (glb.json['meshes'] as List)[glb.node('head_lod0')['mesh'] as int] as Map<String, dynamic>;
    final primitive = (mesh['primitives'] as List).single as Map<String, dynamic>;
    expect(glb.accessor(primitive['indices'] as int), [0, 1, 2, 0, 2, 3]);
  });

  test('sorts influences heaviest first across sets and renormalizes them', () {
    final glb = _Glb(dnaToGlb(_dna(), lods: [0]));
    final attributes = glb.attributes('head_lod0');
    expect(attributes.keys, containsAll(['JOINTS_0', 'WEIGHTS_0', 'JOINTS_1', 'WEIGHTS_1']));
    expect(attributes.keys, isNot(contains('JOINTS_2')));
    final joints = [...glb.accessor(attributes['JOINTS_0'] as int).sublist(0, 4), ...glb.accessor(attributes['JOINTS_1'] as int).sublist(0, 4)];
    final weights = [...glb.accessor(attributes['WEIGHTS_0'] as int).sublist(0, 4), ...glb.accessor(attributes['WEIGHTS_1'] as int).sublist(0, 4)];
    // Weights 0.3 (jaw), 0.25 (root), 0.2 (jaw), then the 0.1s, then 0.05; the
    // six sum to one already, and the empty slots stay zero.
    expect(weights.sublist(0, 3), [closeTo(0.3, 1e-6), closeTo(0.25, 1e-6), closeTo(0.2, 1e-6)]);
    expect(weights[5], closeTo(0.05, 1e-6));
    expect(weights.sublist(6), [0, 0]);
    expect(joints.sublist(0, 3), [1, 0, 1]);
    expect(weights.fold<num>(0, (a, b) => a + b), closeTo(1, 1e-6));
    // A two-influence vertex renormalizes over its own weights.
    expect(glb.accessor(attributes['WEIGHTS_0'] as int).sublist(12, 16), [0.5, 0.5, 0, 0]);
  });

  test('rejects mirrored coordinate systems', () {
    expect(() => dnaToGlb(_dna(axes: const [1, 2, 4])), throwsUnsupportedError);
  });

  test('rotates other right-handed systems into glTF axes', () {
    // x right, y up, z back: a half turn about y.
    final glb = _Glb(dnaToGlb(_dna(axes: const [1, 2, 5]), lods: [0]));
    expect(glb.node('jaw')['translation'], [closeTo(0, 1e-7), closeTo(0.1, 1e-7), closeTo(-0.02, 1e-7)]);
  });
}
