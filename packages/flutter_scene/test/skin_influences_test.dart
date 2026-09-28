// Covers skinned meshes with more than four joint influences per vertex, end
// to end short of the GPU: both glTF import paths read JOINTS_1/WEIGHTS_1 and
// JOINTS_2/WEIGHTS_2, pick the 168-byte layout only when a vertex needs it,
// and serialize it under its own payload layout; the 12-influence geometry,
// material variant, and shaders exist on every backend.
//
// The load-bearing check is a CPU reference: skinned positions computed here
// from the source arrays (all twelve influences, normalized like the shader)
// must equal skinning the importer's packed vertices, while the first set
// alone (what a 4-influence importer keeps) lands measurably elsewhere.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gpu_shaders/environment.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/fmat/fmat.dart';
import 'package:flutter_scene/src/geometry/geometry.dart'
    show kSkinned12VertexBuffer;
import 'package:flutter_scene/src/geometry/interleaved_layout.dart';
import 'package:flutter_scene/src/importer/constants.dart';
import 'package:flutter_scene/src/importer/gltf.dart';
import 'package:flutter_scene/src/importer/in_memory_import.dart';
import 'package:flutter_scene/src/importer/src/gltf/bounds_baker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scene/scene.dart' as fscene;
import 'package:vector_math/vector_math.dart';

const int _jointCount = 12;
const int _vertexCount = 24;

/// Joint [k]'s global transform: a ring of translations around Y, each
/// yawed by its own angle, so every joint deforms a vertex differently.
Matrix4 _jointMatrix(int k) {
  final angle = 2 * math.pi * k / _jointCount;
  return Matrix4.translation(
    Vector3(0.8 * math.cos(angle), 0.05 * k, 0.8 * math.sin(angle)),
  )..multiply(Matrix4.rotationY(0.15 * k));
}

/// Vertex [v]'s rest position.
Vector3 _position(int v) =>
    Vector3(0.3 * math.cos(v * 0.7), 0.1 * v, 0.3 * math.sin(v * 0.7));

/// Vertex [v]'s influences as (joint, weight), spread over up to three sets.
///
/// Most vertices weight all twelve joints, with the set-0 slots holding a
/// rotating subset so truncation drops different joints per vertex. A few
/// are shaped to exercise packing: vertex 3 has three influences (trailing
/// sets empty), vertex 5 splits five across sets 0 and 2, and vertex 7 sums
/// to 0.95 like a sloppy export.
List<(int, double)> _influences(int v) {
  if (v == 3) return [(2, 0.5), (6, 0.3), (9, 0.2)];
  if (v == 5) return [(0, 0.3), (1, 0.2), (11, 0.1), (10, 0.25), (4, 0.15)];
  final raw = [
    for (var k = 0; k < _jointCount; k++)
      ((k + v) % _jointCount, 1.0 + (v * 7 + k * 5) % 11),
  ];
  final sum = raw.fold(0.0, (s, e) => s + e.$2);
  final scale = v == 7 ? 0.95 : 1.0;
  return [for (final (j, w) in raw) (j, w / sum * scale)];
}

/// The influence sets as the glTF stores them, slot `i` of set `s` holding
/// influence `4s + i` (vertex 5 skips set 1 to leave a hole).
({List<Uint8List> joints, List<Float32List> weights}) _sets(int setCount) {
  final joints = [
    for (var s = 0; s < setCount; s++) Uint8List(_vertexCount * 4),
  ];
  final weights = [
    for (var s = 0; s < setCount; s++) Float32List(_vertexCount * 4),
  ];
  for (var v = 0; v < _vertexCount; v++) {
    final list = _influences(v);
    for (var i = 0; i < list.length; i++) {
      // Vertex 5's fifth influence lives in set 2, leaving set 1 empty.
      final slot = v == 5 && i == 4 ? 8 : i;
      final s = slot ~/ 4;
      if (s >= setCount) continue;
      joints[s][v * 4 + slot % 4] = list[i].$1;
      weights[s][v * 4 + slot % 4] = list[i].$2;
    }
  }
  return (joints: joints, weights: weights);
}

/// Builds a GLB: one skinned mesh of [_vertexCount] points (as degenerate
/// triangles) bound to [_jointCount] top-level joints with identity inverse
/// binds. [setCount] influence sets are written (1 truncates to the first).
Uint8List _buildGlb({int setCount = 3}) {
  final builder = _GlbBuilder();
  final positions = Float32List(_vertexCount * 3);
  for (var v = 0; v < _vertexCount; v++) {
    _position(v).copyIntoArray(positions, v * 3);
  }
  final sets = _sets(setCount);
  final attributes = <String, int>{
    'POSITION': builder.addFloats(positions, 'VEC3', minMax: true),
    'NORMAL': builder.addNormals(_vertexCount),
    for (var s = 0; s < setCount; s++) ...{
      'JOINTS_$s': builder.addJoints(sets.joints[s]),
      'WEIGHTS_$s': builder.addFloats(sets.weights[s], 'VEC4'),
    },
  };
  final indices = [for (var v = 0; v < _vertexCount; v++) v];
  final indexAccessor = builder.addIndices(indices);
  return builder.finish({
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {
        'nodes': [for (var n = 0; n <= _jointCount; n++) n],
      },
    ],
    'nodes': [
      {'name': 'Skinned', 'mesh': 0, 'skin': 0},
      for (var k = 0; k < _jointCount; k++) _jointNode(k),
    ],
    'skins': [
      {
        'joints': [for (var k = 0; k < _jointCount; k++) k + 1],
      },
    ],
    'meshes': [
      {
        'primitives': [
          {'attributes': attributes, 'indices': indexAccessor, 'mode': 4},
        ],
      },
    ],
  });
}

Map<String, Object?> _jointNode(int k) {
  final m = _jointMatrix(k);
  final t = m.getTranslation();
  final q = Quaternion.fromRotation(m.getRotation());
  return {
    'name': 'Joint$k',
    'translation': [t.x, t.y, t.z],
    'rotation': [q.x, q.y, q.z, q.w],
  };
}

/// Skins [p] with [influences], normalizing the weights like the shader
/// (the first joint at full weight when they sum to zero).
Vector3 _skin(
  Vector3 p,
  List<(int, double)> influences,
  Matrix4 Function(int joint) jointMatrix,
) {
  final sum = influences.fold(0.0, (s, e) => s + e.$2);
  if (sum <= 0) return jointMatrix(influences.first.$1).transformed3(p);
  final out = Vector3.zero();
  for (final (joint, weight) in influences) {
    out.addScaled(jointMatrix(joint).transformed3(p.clone()), weight / sum);
  }
  return out;
}

/// Reads every packed vertex's position and influences back out of
/// [vertexBytes], at whatever skinned stride the importer chose.
List<(Vector3, List<(int, double)>)> _unpack(
  Uint8List vertexBytes,
  int vertexCount,
) {
  final floats = Float32List.sublistView(vertexBytes);
  final stride = floats.length ~/ vertexCount;
  final influenceCount = (stride - 18) ~/ 2;
  return [
    for (var v = 0; v < vertexCount; v++)
      (
        Vector3(
          floats[v * stride],
          floats[v * stride + 1],
          floats[v * stride + 2],
        ),
        [
          // One (joints, weights) vec4 pair per set after the 18 base floats.
          for (var i = 0; i < influenceCount; i++)
            (
              floats[v * stride + 18 + (i ~/ 4) * 8 + i % 4].toInt(),
              floats[v * stride + 18 + (i ~/ 4) * 8 + 4 + i % 4].toDouble(),
            ),
        ],
      ),
  ];
}

({GltfDocument doc, Uint8List bin}) _parse(Uint8List glb) {
  final container = parseGlb(glb);
  return (doc: parseGltfJson(container.json), bin: container.binaryChunk);
}

PackedPrimitive _pack(
  Uint8List glb, {
  GltfCoordinatePolicy policy = GltfCoordinatePolicy.runtimeBoundary,
}) {
  final (:doc, :bin) = _parse(glb);
  return packGltfPrimitive(
    primitive: doc.meshes.single.primitives.single,
    accessors: doc.accessors,
    bufferViews: doc.bufferViews,
    bufferData: bin,
    coordinatePolicy: policy,
  );
}

/// The largest distance between two position lists.
double _maxError(List<Vector3> a, List<Vector3> b) {
  var worst = 0.0;
  for (var i = 0; i < a.length; i++) {
    worst = math.max(worst, a[i].distanceTo(b[i]));
  }
  return worst;
}

/// Mirrors a source-space matrix into native space (Z negated), as the
/// offline importer bakes geometry.
Matrix4 _native(Matrix4 m) {
  final flip = Matrix4.diagonal3Values(1, 1, -1);
  return flip * m * flip;
}

void main() {
  final reference = [
    for (var v = 0; v < _vertexCount; v++)
      _skin(_position(v), _influences(v), _jointMatrix),
  ];

  group('import', () {
    test('runtime import skins to the 12-influence CPU reference', () {
      final packed = _pack(_buildGlb());
      final loaded = [
        for (final (p, influences) in _unpack(
          packed.vertexBytes,
          packed.vertexCount,
        ))
          _skin(p, influences, _jointMatrix),
      ];
      expect(_maxError(loaded, reference), lessThan(1e-5));
    });

    test('offline import skins to the 12-influence CPU reference', () {
      final document = importGlbToSceneDocument(_buildGlb());
      final geometry = document.resources.values
          .whereType<fscene.GeometryResource>()
          .single;
      final bytes = document.payload(geometry.vertices!)!.bytes!;
      // The offline importer bakes native space (Z negated), so skin with
      // the mirrored joints and compare against the mirrored reference.
      final loaded = [
        for (final (p, influences) in _unpack(bytes, _vertexCount))
          _skin(p, influences, (j) => _native(_jointMatrix(j))),
      ];
      final nativeReference = [
        for (final p in reference) Vector3(p.x, p.y, -p.z),
      ];
      expect(_maxError(loaded, nativeReference), lessThan(1e-5));
    });

    test('truncating to the first four influences lands elsewhere', () {
      // What a 4-influence importer keeps: JOINTS_0/WEIGHTS_0, renormalized.
      final truncated = [
        for (var v = 0; v < _vertexCount; v++)
          _skin(_position(v), _influences(v).take(4).toList(), _jointMatrix),
      ];
      expect(_maxError(truncated, reference), greaterThan(0.1));
      // And a file carrying only the first set packs to exactly that.
      final firstSetOnly = _pack(_buildGlb(setCount: 1));
      final loaded = [
        for (final (p, influences) in _unpack(
          firstSetOnly.vertexBytes,
          firstSetOnly.vertexCount,
        ))
          _skin(p, influences, _jointMatrix),
      ];
      expect(_maxError(loaded, truncated), lessThan(1e-5));
      expect(_maxError(loaded, reference), greaterThan(0.1));
    });
  });

  group('packing', () {
    test('more than four influences pick the 168-byte layout', () {
      final packed = _pack(_buildGlb());
      expect(packed.isSkinned, isTrue);
      expect(packed.skinInfluences, kMaxSkinInfluences);
      expect(
        packed.vertexBytes.length,
        packed.vertexCount * kSkinned12PerVertexSize,
      );
      final vertices = _unpack(packed.vertexBytes, packed.vertexCount);
      // Vertex 3's three influences lead, and its trailing sets stay zero
      // so the shader skips their joint fetches.
      expect([for (final (j, _) in vertices[3].$2.take(3)) j], [2, 6, 9]);
      expect([for (final (_, w) in vertices[3].$2.skip(4)) w], everyElement(0));
      // Vertex 5's set-2 influence moves up into the empty set-1 slot.
      expect(
        [for (final (j, _) in vertices[5].$2.take(5)) j],
        [0, 1, 11, 10, 4],
      );
      expect([for (final (_, w) in vertices[5].$2.skip(8)) w], everyElement(0));
    });

    test('a single set packs verbatim into the 104-byte layout', () {
      final packed = _pack(_buildGlb(setCount: 1));
      expect(packed.skinInfluences, 4);
      expect(
        packed.vertexBytes.length,
        packed.vertexCount * kSkinnedPerVertexSize,
      );
      final sets = _sets(1);
      final floats = Float32List.sublistView(packed.vertexBytes);
      for (var v = 0; v < _vertexCount; v++) {
        for (var i = 0; i < 4; i++) {
          expect(floats[v * 26 + 18 + i], sets.joints[0][v * 4 + i]);
          expect(floats[v * 26 + 22 + i], sets.weights[0][v * 4 + i]);
        }
      }
    });

    test('extra sets with no vertex past four stay on the 104-byte layout', () {
      // Two influences in set 0 and two in set 1 per vertex, the rest zero.
      final builder = _GlbBuilder();
      final positions = Float32List(4 * 3)..fillRange(0, 12, 0.5);
      final joints0 = Uint8List.fromList([
        for (var i = 0; i < 16; i++) i % 4 < 2 ? 1 + i % 4 : 0,
      ]);
      final weights0 = Float32List.fromList([
        for (var i = 0; i < 16; i++) i % 4 < 2 ? 0.25 : 0.0,
      ]);
      final joints1 = Uint8List.fromList([
        for (var i = 0; i < 16; i++) i % 4 < 2 ? 5 + i % 4 : 0,
      ]);
      final weights1 = Float32List.fromList([
        for (var i = 0; i < 16; i++) i % 4 < 2 ? 0.25 : 0.0,
      ]);
      final glb = builder.finish({
        'asset': {'version': '2.0'},
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {
                  'POSITION': builder.addFloats(positions, 'VEC3'),
                  'NORMAL': builder.addNormals(4),
                  'JOINTS_0': builder.addJoints(joints0),
                  'WEIGHTS_0': builder.addFloats(weights0, 'VEC4'),
                  'JOINTS_1': builder.addJoints(joints1),
                  'WEIGHTS_1': builder.addFloats(weights1, 'VEC4'),
                },
              },
            ],
          },
        ],
      });
      final packed = _pack(glb);
      expect(packed.skinInfluences, 4);
      expect(packed.vertexBytes.length, 4 * kSkinnedPerVertexSize);
      final vertices = _unpack(packed.vertexBytes, packed.vertexCount);
      for (final (_, influences) in vertices) {
        expect([for (final (j, _) in influences) j], [1, 2, 5, 6]);
        expect([for (final (_, w) in influences) w], everyElement(0.25));
      }
    });

    test('past twelve influences a vertex keeps its largest weights', () {
      final builder = _GlbBuilder();
      // One vertex, sixteen influences over four sets, weight 16 - k on
      // joint k, so joints 12 through 15 carry the four smallest.
      final attributes = <String, int>{
        'POSITION': builder.addFloats(Float32List.fromList([0, 1, 0]), 'VEC3'),
        'NORMAL': builder.addNormals(1),
      };
      for (var s = 0; s < 4; s++) {
        attributes['JOINTS_$s'] = builder.addJoints(
          Uint8List.fromList([for (var i = 0; i < 4; i++) 4 * s + i]),
        );
        attributes['WEIGHTS_$s'] = builder.addFloats(
          Float32List.fromList([for (var i = 0; i < 4; i++) 16.0 - 4 * s - i]),
          'VEC4',
        );
      }
      final glb = builder.finish({
        'asset': {'version': '2.0'},
        'meshes': [
          {
            'primitives': [
              {'attributes': attributes},
            ],
          },
        ],
      });
      final packed = _pack(glb);
      expect(packed.skinInfluences, kMaxSkinInfluences);
      final (_, influences) = _unpack(packed.vertexBytes, 1).single;
      expect(
        [for (final (j, _) in influences) j],
        [for (var k = 0; k < 12; k++) k],
      );
    });

    test('a vertex with no weight keeps its first joint', () {
      final builder = _GlbBuilder();
      final glb = builder.finish({
        'asset': {'version': '2.0'},
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {
                  'POSITION': builder.addFloats(
                    Float32List.fromList([0, 0, 0, 1, 0, 0]),
                    'VEC3',
                  ),
                  'NORMAL': builder.addNormals(2),
                  'JOINTS_0': builder.addJoints(
                    Uint8List.fromList([7, 1, 2, 3, 0, 1, 2, 3]),
                  ),
                  'WEIGHTS_0': builder.addFloats(
                    Float32List.fromList([0, 0, 0, 0, 0.2, 0.2, 0.2, 0.2]),
                    'VEC4',
                  ),
                  'JOINTS_1': builder.addJoints(
                    Uint8List.fromList([0, 0, 0, 0, 4, 0, 0, 0]),
                  ),
                  'WEIGHTS_1': builder.addFloats(
                    Float32List.fromList([0, 0, 0, 0, 0.2, 0, 0, 0]),
                    'VEC4',
                  ),
                },
              },
            ],
          },
        ],
      });
      final packed = _pack(glb);
      expect(packed.skinInfluences, kMaxSkinInfluences);
      final vertices = _unpack(packed.vertexBytes, 2);
      expect(vertices[0].$2.first.$1, 7);
      expect([for (final (_, w) in vertices[0].$2) w], everyElement(0));
    });

    test('pose-union bounds cover a joint only JOINTS_2 references', () {
      // A triangle hanging half on joint 0 at the origin (set 0) and half on
      // joint 1 four units along +X (set 2, set 1 empty). The bound must
      // reach the posed extent joint 1 gives it.
      final builder = _GlbBuilder();
      Uint8List joints(int j) => Uint8List.fromList([
        for (var v = 0; v < 3; v++) ...[j, 0, 0, 0],
      ]);
      Float32List weights(double w) => Float32List.fromList([
        for (var v = 0; v < 3; v++) ...[w, 0, 0, 0],
      ]);
      final glb = builder.finish({
        'asset': {'version': '2.0'},
        'scene': 0,
        'scenes': [
          {
            'nodes': [0, 1, 2],
          },
        ],
        'nodes': [
          {'mesh': 0, 'skin': 0},
          {'name': 'Root'},
          {
            'name': 'Far',
            'translation': [4, 0, 0],
          },
        ],
        'skins': [
          {
            'joints': [1, 2],
          },
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {
                  'POSITION': builder.addFloats(
                    Float32List.fromList([0, 0, 0, 0.1, 0, 0, 0, 0.1, 0]),
                    'VEC3',
                    minMax: true,
                  ),
                  'NORMAL': builder.addNormals(3),
                  'JOINTS_0': builder.addJoints(joints(0)),
                  'WEIGHTS_0': builder.addFloats(weights(0.5), 'VEC4'),
                  'JOINTS_1': builder.addJoints(joints(0)),
                  'WEIGHTS_1': builder.addFloats(weights(0), 'VEC4'),
                  'JOINTS_2': builder.addJoints(joints(1)),
                  'WEIGHTS_2': builder.addFloats(weights(0.5), 'VEC4'),
                },
              },
            ],
          },
        ],
      });
      final (:doc, :bin) = _parse(glb);
      final union = bakeSkinnedPoseUnionAabbs(doc, bin)[0]!.single!;
      expect(union.maxX, closeTo(4.1, 1e-5));
    });
  });

  group('serialization', () {
    test('12-influence geometry writes its own payload layout', () {
      final glb = _buildGlb();
      final document = importGlbToSceneDocument(glb);
      final geometry = document.resources.values
          .whereType<fscene.GeometryResource>()
          .single;
      final payload = document.payload(geometry.vertices!)!;
      expect(payload.layout, InterleavedLayoutAdapter.skinned12Layout);
      expect(
        payload.bytes,
        _pack(glb, policy: GltfCoordinatePolicy.bakeNative).vertexBytes,
      );

      // And the binary container carries it through.
      final decoded = fscene.readFsceneb(importGlbToFscenebBytes(glb));
      final decodedGeometry = decoded.resources.values
          .whereType<fscene.GeometryResource>()
          .single;
      final decodedPayload = decoded.payload(decodedGeometry.vertices!)!;
      expect(decodedPayload.layout, InterleavedLayoutAdapter.skinned12Layout);
      expect(decodedPayload.bytes, payload.bytes);
    });

    test('4-influence geometry keeps the layout older engines read', () {
      final document = importGlbToSceneDocument(_buildGlb(setCount: 1));
      final geometry = document.resources.values
          .whereType<fscene.GeometryResource>()
          .single;
      expect(
        document.payload(geometry.vertices!)!.layout,
        InterleavedLayoutAdapter.skinnedLayout,
      );
    });
  });

  group('geometry', () {
    test('SkinnedGeometry takes 4 or 12 influences', () {
      expect(SkinnedGeometry().influences, 4);
      expect(SkinnedGeometry().materialVertexVariant, 'skinned');
      final wide = SkinnedGeometry(influences: 12);
      expect(wide.materialVertexVariant, 'skinned12');
      expect(() => SkinnedGeometry(influences: 8), throwsArgumentError);
    });

    test('12-influence geometry polices the 168-byte stride', () {
      final narrow = Float32List(3 * kSkinnedPerVertexSize ~/ 4);
      expect(
        () => SkinnedGeometry(influences: 12).uploadVertexData(narrow, 3, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('168-byte'), contains('joints_2 4, weights_2 4')),
          ),
        ),
      );
    });

    test('the mesh variant round-trips its wire name', () {
      expect(MeshVariant.fromName('skinned12'), MeshVariant.skinned12);
      expect(MeshVariant.skinned12.name, 'skinned12');
    });
  });

  group('shaders', () {
    test('the base bundle carries the 12-influence vertex variants', () {
      final manifest =
          jsonDecode(File('shaders/base.shaderbundle.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(
        manifest['Skinned12Vertex']['file'],
        'shaders/flutter_scene_skinned12.vert',
      );
      expect(
        manifest['MorphedSkinned12Vertex']['file'],
        'shaders/flutter_scene_morphed_skinned12.vert',
      );
      expect(
        manifest['VelocitySkinned12Vertex']['file'],
        'shaders/flutter_scene_velocity_skinned12.vert',
      );
    });

    test('a .fmat vertex stage generates a 12-influence variant', () {
      final material = parseFmat('''
material { name: "Curved" }
vertex { void Vertex(inout VertexInputs vertex) {} }
fragment { void Surface(inout MaterialInputs material) {} }
''');
      final variants = emitVertexGlsl(material);
      final wide = variants['CurvedSkinned12Vertex']!;
      expect(wide, contains('#define FLUTTER_SCENE_SKIN_12_INFLUENCES'));
      expect(wide, contains('#include <flutter_scene_skinned_body.glsl>'));
      expect(
        variants['CurvedSkinnedVertex'],
        isNot(contains('FLUTTER_SCENE_SKIN_12_INFLUENCES')),
      );
    });

    test('12-influence variants compile on every impellerc backend', () async {
      final temp = Directory.systemTemp.createTempSync('skin12_variants');
      try {
        final impellerc = await findImpellerC();
        for (final entry in [
          'flutter_scene_skinned12',
          'flutter_scene_morphed_skinned12',
          'flutter_scene_velocity_skinned12',
        ]) {
          for (final backend in ['opengl-es', 'metal-desktop', 'vulkan']) {
            final reflection = File.fromUri(
              temp.uri.resolve('$entry.$backend.json'),
            );
            final result = await Process.run(impellerc.toFilePath(), [
              '--$backend',
              '--input-type=vert',
              '--input=shaders/$entry.vert',
              '--sl=${temp.uri.resolve('$entry.$backend.sl').toFilePath()}',
              '--spirv=${temp.uri.resolve('$entry.$backend.spirv').toFilePath()}',
              '--reflection-json=${reflection.path}',
              '--include=${Directory.current.uri.resolve('shaders/').toFilePath()}',
              '--include=${impellerc.resolve('./shader_lib').toFilePath()}',
              if (backend == 'opengl-es') '--gles-language-version=300',
            ]);
            expect(
              result.exitCode,
              0,
              reason: '$entry $backend: ${result.stdout}\n${result.stderr}',
            );
            final parsed =
                jsonDecode(reflection.readAsStringSync())
                    as Map<String, dynamic>;
            final inputs = {
              for (final input in parsed['stage_inputs'] as List)
                input['name'] as String: input['offset'] as int,
            };
            for (final name in [
              'joints_1',
              'weights_1',
              'joints_2',
              'weights_2',
            ]) {
              expect(
                inputs,
                contains(name),
                reason: '$entry $backend should read $name',
              );
            }
            // The color variants draw through the shader's own reflected
            // layout, so its offsets must be the packer's.
            if (entry != 'flutter_scene_velocity_skinned12') {
              for (final attribute in kSkinned12VertexBuffer.attributes) {
                expect(
                  inputs[attribute.name],
                  attribute.offsetInBytes,
                  reason: '$entry $backend ${attribute.name} offset',
                );
              }
            }
          }
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });
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

  /// Unit +Y normals for [count] vertices. Authored normals keep the packer
  /// from de-indexing the primitive to generate flat ones.
  int addNormals(int count) => addFloats(
    Float32List.fromList([
      for (var i = 0; i < count; i++) ...[0.0, 1.0, 0.0],
    ]),
    'VEC3',
  );

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
    output.add(
      Uint8List(jsonLength - jsonBytes.length)
        ..fillRange(0, jsonLength - jsonBytes.length, 0x20),
    );
    uint32(binaryLength);
    output.add([0x42, 0x49, 0x4e, 0]);
    output.add(binary);
    output.add(Uint8List(binaryLength - binary.length));
    return output.takeBytes();
  }
}
