import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:scene/scene.dart' show sceneLog;

import '../../constants.dart';
import 'accessor.dart';
import 'coordinate_policy.dart';
import 'draco/gltf_draco.dart';
import 'types.dart';

/// Pure-data result of packing a glTF mesh primitive into
/// flutter_scene's vertex layout.
///
/// Shared by the runtime GLB importer and the offline scene emitter so layout,
/// attribute defaults, and index handling stay identical. The selected
/// coordinate policy controls whether spatial values remain in source space
/// or are baked into native scene space.
class PackedPrimitive {
  PackedPrimitive({
    required this.vertexBytes,
    required this.vertexCount,
    required this.indexBytes,
    required this.indexCount,
    required this.indices32Bit,
    required this.isSkinned,
    required this.sourceWindingFlipped,
    this.skinInfluences = 4,
    this.morphTargets,
  });

  /// Packed vertex buffer in the engine's vertex layout (72 bytes per
  /// unskinned vertex, 104 per skinned, 168 per 12-influence skinned).
  final Uint8List vertexBytes;

  /// Number of vertices in [vertexBytes].
  final int vertexCount;

  /// Packed index buffer, either 16- or 32-bit per [indices32Bit].
  final Uint8List indexBytes;

  /// Number of indices in [indexBytes].
  final int indexCount;

  /// Whether [indexBytes] holds 32-bit (`true`) or 16-bit indices.
  final bool indices32Bit;

  /// Whether the vertex layout includes joints and weights.
  final bool isSkinned;

  /// The joint influences each skinned vertex carries, 4 (the 104-byte
  /// layout) or [kMaxSkinInfluences] (the 168-byte layout). Meaningless when
  /// [isSkinned] is false.
  final int skinInfluences;

  /// Whether the packed source convention reverses native winding.
  final bool sourceWindingFlipped;

  /// The primitive's morph target deltas, remapped to the packed vertex
  /// order and coordinate-converted like the base vertices, or null when
  /// the primitive declares no targets.
  final PackedMorphTargets? morphTargets;
}

/// Morph target deltas packed alongside a [PackedPrimitive], target-major
/// (`[target][vertex][component]`), aligned with the packed vertex order.
class PackedMorphTargets {
  PackedMorphTargets({
    required this.targetCount,
    required this.vertexCount,
    required this.positionDeltas,
    this.normalDeltas,
    this.tangentDeltas,
  });

  /// The number of morph targets.
  final int targetCount;

  /// The packed primitive's vertex count each target's deltas cover.
  final int vertexCount;

  /// Position deltas, `targetCount * vertexCount * 3` floats.
  final Float32List positionDeltas;

  /// Normal deltas (same shape as [positionDeltas]), or null when no target
  /// carries them or the base primitive has no authored normals.
  final Float32List? normalDeltas;

  /// Tangent deltas, xyz only (the bitangent sign always comes from the
  /// base tangent), or null when absent. Stored for later use; blending
  /// does not apply them yet. TODO(morph-tangent-deltas): apply tangent
  /// deltas in the CPU and GPU blend paths.
  final Float32List? tangentDeltas;
}

/// Packs a glTF mesh primitive into the engine's vertex/index layout.
///
/// The vertex layout matches `shaders/flutter_scene_(un)skinned.vert`:
///
/// - Unskinned (72 bytes/vertex): position(3 f32), normal(3 f32),
///   texture_coords(2 f32), texture_coords_1(2 f32), color(4 f32),
///   tangent(4 f32).
/// - Skinned (104 bytes/vertex): unskinned + joints(4 f32) +
///   weights(4 f32).
/// - 12-influence skinned (168 bytes/vertex): skinned + joints_1(4 f32) +
///   weights_1(4 f32) + joints_2(4 f32) + weights_2(4 f32).
///
/// A primitive with only `JOINTS_0`/`WEIGHTS_0` packs its sets verbatim into
/// the 104-byte layout. One that also authors `JOINTS_1`/`WEIGHTS_1` (and
/// beyond) has each vertex's nonzero influences packed into the leading
/// slots, and takes the 168-byte layout only when some vertex has more than
/// four; past [kMaxSkinInfluences] a vertex keeps its largest weights. The
/// shader normalizes whatever remains, as it does four.
///
/// When the primitive omits the NORMAL attribute, glTF requires the
/// client to generate flat normals. A vertex shared by several
/// triangles can't carry a single per-face normal, so the primitive is
/// de-indexed (every triangle expanded to three unique vertices, each
/// carrying that triangle's face normal) with a sequential index
/// buffer. Primitives that author normals are kept as-is.
///
/// Set [includeSkinning] to false when the owning node has no skin. Some
/// exporters leave joint attributes on otherwise static primitives.
PackedPrimitive packGltfPrimitive({
  required GltfMeshPrimitive primitive,
  required List<GltfAccessor> accessors,
  required List<GltfBufferView> bufferViews,
  required Uint8List bufferData,
  required GltfCoordinatePolicy coordinatePolicy,
  bool includeSkinning = true,
}) {
  // KHR_draco_mesh_compression: decode the payload and swap in synthesized
  // accessor tables, so the packing below reads decoded data unchanged.
  if (primitive.draco != null) {
    final resolved = decodeDracoPrimitive(
      primitive: primitive,
      accessors: accessors,
      bufferViews: bufferViews,
      bufferData: bufferData,
    );
    accessors = resolved.accessors;
    bufferViews = resolved.bufferViews;
    bufferData = resolved.bufferData;
  }
  final positionIdx = primitive.attributes['POSITION'];
  if (positionIdx == null) {
    throw const FormatException('Mesh primitive is missing POSITION attribute');
  }
  final positions = _readVec3(positionIdx, accessors, bufferViews, bufferData);
  final vertexCount = positions.length ~/ 3;

  // Read (or synthesize) the triangle index list up front: it's needed
  // both to build the index buffer and to generate normals when the
  // glTF primitive omits them.
  final Uint32List indexList;
  final bool indices32Bit;
  if (primitive.indices != null) {
    final accessor = accessors[primitive.indices!];
    indexList = readAccessorAsUint32(accessor, bufferViews, bufferData);
    indices32Bit = accessor.componentType == GltfComponentType.unsignedInt;
  } else {
    // No indices: a sequential triangle list.
    indexList = Uint32List(vertexCount);
    for (int i = 0; i < vertexCount; i++) {
      indexList[i] = i;
    }
    indices32Bit = false;
  }

  // Source attribute arrays, indexed by original glTF vertex index.
  final texCoords = _readOptionalVec2(
    'TEXCOORD_0',
    primitive,
    accessors,
    bufferViews,
    bufferData,
    vertexCount,
  );
  final texCoords1 = _readOptionalVec2(
    'TEXCOORD_1',
    primitive,
    accessors,
    bufferViews,
    bufferData,
    vertexCount,
  );
  final colors = _readOptionalColor(
    'COLOR_0',
    primitive,
    accessors,
    bufferViews,
    bufferData,
    vertexCount,
  );
  final tangents = _readOptionalVec4(
    'TANGENT',
    primitive,
    accessors,
    bufferViews,
    bufferData,
    vertexCount,
  );
  final hasJoints =
      includeSkinning &&
      primitive.attributes.containsKey('JOINTS_0') &&
      primitive.attributes.containsKey('WEIGHTS_0');
  var joints = hasJoints
      ? _readVec4(
          primitive.attributes['JOINTS_0']!,
          accessors,
          bufferViews,
          bufferData,
        )
      : null;
  var weights = hasJoints
      ? _readVec4(
          primitive.attributes['WEIGHTS_0']!,
          accessors,
          bufferViews,
          bufferData,
        )
      : null;
  // Further influence sets, when authored, fold into one packed table (see
  // the function doc). Without them the first set is used as-is.
  var influences = 4;
  if (hasJoints && primitive.attributes.containsKey('JOINTS_1')) {
    final packed = _packInfluenceSets(
      primitive,
      accessors,
      bufferViews,
      bufferData,
      vertexCount,
      joints!,
      weights!,
    );
    joints = packed.joints;
    weights = packed.weights;
    influences = packed.influences;
  }

  // Determine the output vertex set. With authored normals the mesh is
  // kept as-is; without them it is de-indexed for flat normals (see the
  // function doc).
  final List<int> srcOf; // output vertex index -> source vertex index
  final Float32List normals; // output-vertex normals (3 per vertex)
  final Uint32List outIndexList;
  final bool outIndices32Bit;

  if (primitive.attributes.containsKey('NORMAL')) {
    normals = _readVec3(
      primitive.attributes['NORMAL']!,
      accessors,
      bufferViews,
      bufferData,
    );
    srcOf = List<int>.generate(vertexCount, (i) => i);
    outIndexList = indexList;
    outIndices32Bit = indices32Bit;
  } else {
    final triCount = indexList.length ~/ 3;
    final outCount = triCount * 3;
    srcOf = List<int>.filled(outCount, 0);
    normals = Float32List(outCount * 3);
    for (int t = 0; t < triCount; t++) {
      final i0 = indexList[t * 3];
      final i1 = indexList[t * 3 + 1];
      final i2 = indexList[t * 3 + 2];
      final ax = positions[i0 * 3];
      final ay = positions[i0 * 3 + 1];
      final az = positions[i0 * 3 + 2];
      final e1x = positions[i1 * 3] - ax;
      final e1y = positions[i1 * 3 + 1] - ay;
      final e1z = positions[i1 * 3 + 2] - az;
      final e2x = positions[i2 * 3] - ax;
      final e2y = positions[i2 * 3 + 1] - ay;
      final e2z = positions[i2 * 3 + 2] - az;
      var nx = e1y * e2z - e1z * e2y;
      var ny = e1z * e2x - e1x * e2z;
      var nz = e1x * e2y - e1y * e2x;
      final len = sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 1e-12) {
        nx /= len;
        ny /= len;
        nz /= len;
      } else {
        // Degenerate (zero-area) triangle: pick an arbitrary normal.
        nx = 0;
        ny = 1;
        nz = 0;
      }
      for (int c = 0; c < 3; c++) {
        final k = t * 3 + c;
        srcOf[k] = indexList[t * 3 + c];
        normals[k * 3] = nx;
        normals[k * 3 + 1] = ny;
        normals[k * 3 + 2] = nz;
      }
    }
    outIndexList = Uint32List(outCount);
    for (int k = 0; k < outCount; k++) {
      outIndexList[k] = k;
    }
    // 16-bit indices address 0..65535.
    outIndices32Bit = outCount > 0x10000;
  }

  final outVertexCount = srcOf.length;
  final perVertex = !hasJoints
      ? kUnskinnedPerVertexSize
      : influences > 4
      ? kSkinned12PerVertexSize
      : kSkinnedPerVertexSize;
  final stride = perVertex ~/ 4; // floats per vertex
  final out = Float32List(outVertexCount * stride);

  for (int k = 0; k < outVertexCount; k++) {
    final o = k * stride;
    final s = srcOf[k];
    out[o + 0] = positions[s * 3 + 0];
    out[o + 1] = positions[s * 3 + 1];
    out[o + 2] = positions[s * 3 + 2];
    out[o + 3] = normals[k * 3 + 0];
    out[o + 4] = normals[k * 3 + 1];
    out[o + 5] = normals[k * 3 + 2];
    out[o + 6] = texCoords[s * 2 + 0];
    out[o + 7] = texCoords[s * 2 + 1];
    out[o + 8] = texCoords1[s * 2 + 0];
    out[o + 9] = texCoords1[s * 2 + 1];
    out[o + 10] = colors[s * 4 + 0];
    out[o + 11] = colors[s * 4 + 1];
    out[o + 12] = colors[s * 4 + 2];
    out[o + 13] = colors[s * 4 + 3];
    out[o + 14] = tangents[s * 4 + 0];
    out[o + 15] = tangents[s * 4 + 1];
    out[o + 16] = tangents[s * 4 + 2];
    out[o + 17] = tangents[s * 4 + 3];
    if (hasJoints) {
      // One (joints, weights) vec4 pair per set: slots 0-3, then 4-7 and
      // 8-11 on the 168-byte layout.
      final sets = influences ~/ 4;
      final width = influences;
      for (var set = 0; set < sets; set++) {
        final j = o + 18 + set * 8;
        final src = s * width + set * 4;
        out[j + 0] = joints![src + 0];
        out[j + 1] = joints[src + 1];
        out[j + 2] = joints[src + 2];
        out[j + 3] = joints[src + 3];
        out[j + 4] = weights![src + 0];
        out[j + 5] = weights[src + 1];
        out[j + 6] = weights[src + 2];
        out[j + 7] = weights[src + 3];
      }
    }
  }

  // Runtime import stops above with an exact source copy. Offline import pays
  // for a separate conversion pass so serialized geometry is native.
  if (coordinatePolicy.bakesNative) {
    for (var o = 0; o < out.length; o += stride) {
      out[o + 2] = -out[o + 2];
      out[o + 5] = -out[o + 5];
      out[o + 16] = -out[o + 16];
      out[o + 17] = -out[o + 17];
    }
    // Negating Z mirrors triangle winding; swap indices (a, b, c) -> (a, c, b)
    // so baked native geometry retains Counter-Clockwise (CCW) front faces.
    for (var i = 0; i + 2 < outIndexList.length; i += 3) {
      final tmp = outIndexList[i + 1];
      outIndexList[i + 1] = outIndexList[i + 2];
      outIndexList[i + 2] = tmp;
    }
  }

  // The engine wants 16- or 32-bit indices. Pass 32-bit through; narrow
  // everything else to 16-bit.
  final Uint8List indexBytes;
  if (outIndices32Bit) {
    indexBytes = outIndexList.buffer.asUint8List(
      outIndexList.offsetInBytes,
      outIndexList.lengthInBytes,
    );
  } else {
    final widened = Uint16List(outIndexList.length);
    for (int i = 0; i < outIndexList.length; i++) {
      widened[i] = outIndexList[i];
    }
    indexBytes = widened.buffer.asUint8List(
      widened.offsetInBytes,
      widened.lengthInBytes,
    );
  }

  return PackedPrimitive(
    vertexBytes: out.buffer.asUint8List(out.offsetInBytes, out.lengthInBytes),
    vertexCount: outVertexCount,
    indexBytes: indexBytes,
    indexCount: outIndexList.length,
    indices32Bit: outIndices32Bit,
    isSkinned: hasJoints,
    skinInfluences: influences,
    sourceWindingFlipped: coordinatePolicy.sourceWindingFlipped,
    morphTargets: _packMorphTargets(
      primitive,
      accessors,
      bufferViews,
      bufferData,
      srcOf: srcOf,
      sourceVertexCount: vertexCount,
      coordinatePolicy: coordinatePolicy,
    ),
  );
}

/// Reads a primitive's morph targets into packed, target-major delta slabs
/// aligned with the packed vertex order ([srcOf] maps output vertex to
/// source vertex, identity unless the primitive was de-indexed for flat
/// normals). Deltas are additive per spec; a native-baking policy negates
/// each delta's Z like the base attributes.
PackedMorphTargets? _packMorphTargets(
  GltfMeshPrimitive primitive,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData, {
  required List<int> srcOf,
  required int sourceVertexCount,
  required GltfCoordinatePolicy coordinatePolicy,
}) {
  final targets = primitive.targets;
  if (targets.isEmpty) return null;

  final hasBaseNormals = primitive.attributes.containsKey('NORMAL');
  final hasBaseTangents = primitive.attributes.containsKey('TANGENT');
  final anyNormals = targets.any((t) => t.containsKey('NORMAL'));
  final anyTangents = targets.any((t) => t.containsKey('TANGENT'));
  // Without authored base normals the primitive was de-indexed to flat
  // normals; deltas relative to normals the asset never authored have no
  // meaning, so they are dropped. TODO(morph-flat-normals): regenerate flat
  // normals from morphed positions instead of keeping the rest normals.
  if (anyNormals && !hasBaseNormals) {
    sceneLog(
      'glTF morph targets carry NORMAL deltas but the base primitive has no '
      'authored normals; morphing keeps the generated flat normals',
    );
  }
  // Tangent deltas without base normals cannot produce a valid frame; with
  // base normals but no base tangent there is nothing to offset.
  if (anyTangents && !hasBaseTangents) {
    sceneLog(
      'glTF morph targets carry TANGENT deltas but the base primitive has no '
      'authored tangents; ignoring them',
    );
  }
  final includeNormals = anyNormals && hasBaseNormals;
  final includeTangents = anyTangents && hasBaseTangents && hasBaseNormals;

  final outVertexCount = srcOf.length;
  final targetCount = targets.length;
  final positionDeltas = Float32List(targetCount * outVertexCount * 3);
  final normalDeltas = includeNormals
      ? Float32List(targetCount * outVertexCount * 3)
      : null;
  final tangentDeltas = includeTangents
      ? Float32List(targetCount * outVertexCount * 3)
      : null;

  void fill(Float32List slab, int targetIndex, int accessorIndex) {
    final accessor = accessors[accessorIndex];
    if (accessor.count != sourceVertexCount) {
      throw FormatException(
        'glTF morph target accessor has ${accessor.count} elements; the '
        'primitive has $sourceVertexCount vertices',
      );
    }
    final source = readAccessorAsFloat32(accessor, bufferViews, bufferData);
    // POSITION/NORMAL deltas are VEC3; TANGENT deltas are VEC3 per spec but
    // a VEC4-authored one is tolerated (its w is ignored, the bitangent sign
    // always comes from the base tangent).
    final comps = accessor.type.componentCount;
    if (comps < 3) {
      throw FormatException(
        'glTF morph target accessor has $comps components; expected 3',
      );
    }
    final base = targetIndex * outVertexCount * 3;
    final flipZ = coordinatePolicy.bakesNative;
    for (var k = 0; k < outVertexCount; k++) {
      final s = srcOf[k] * comps;
      slab[base + k * 3] = source[s];
      slab[base + k * 3 + 1] = source[s + 1];
      slab[base + k * 3 + 2] = flipZ ? -source[s + 2] : source[s + 2];
    }
  }

  for (var t = 0; t < targetCount; t++) {
    final target = targets[t];
    // A target may omit any attribute; omitted deltas stay zero.
    final position = target['POSITION'];
    if (position != null) fill(positionDeltas, t, position);
    final normal = target['NORMAL'];
    if (normalDeltas != null && normal != null) fill(normalDeltas, t, normal);
    final tangent = target['TANGENT'];
    if (tangentDeltas != null && tangent != null) {
      fill(tangentDeltas, t, tangent);
    }
  }

  return PackedMorphTargets(
    targetCount: targetCount,
    vertexCount: outVertexCount,
    positionDeltas: positionDeltas,
    normalDeltas: normalDeltas,
    tangentDeltas: tangentDeltas,
  );
}

/// Folds every authored `JOINTS_n`/`WEIGHTS_n` set of [primitive] into one
/// per-vertex influence table, [joints0] and [weights0] (set 0, already read)
/// first.
///
/// Each vertex's nonzero weights move into its leading slots in set order,
/// so the trailing sets of a vertex with few influences stay zero and the
/// shader skips them. A vertex with more than [kMaxSkinInfluences] keeps its
/// largest, and one with none keeps its first joint so the shader's
/// all-zero fallback binds the same joint it does for four. The table is
/// [influences] wide: 4 when no vertex needs more, else
/// [kMaxSkinInfluences].
({Float32List joints, Float32List weights, int influences}) _packInfluenceSets(
  GltfMeshPrimitive primitive,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData,
  int vertexCount,
  Float32List joints0,
  Float32List weights0,
) {
  final jointSets = [joints0];
  final weightSets = [weights0];
  for (var set = 1; ; set++) {
    final jointsIdx = primitive.attributes['JOINTS_$set'];
    final weightsIdx = primitive.attributes['WEIGHTS_$set'];
    if (jointsIdx == null || weightsIdx == null) break;
    jointSets.add(_readVec4(jointsIdx, accessors, bufferViews, bufferData));
    weightSets.add(_readVec4(weightsIdx, accessors, bufferViews, bufferData));
  }
  final authored = jointSets.length * 4;
  final joints = Float32List(vertexCount * kMaxSkinInfluences);
  final weights = Float32List(vertexCount * kMaxSkinInfluences);
  final order = List<int>.filled(authored, 0);
  var widest = 0;
  var dropped = 0;
  for (var v = 0; v < vertexCount; v++) {
    var count = 0;
    for (var i = 0; i < authored; i++) {
      if (weightSets[i ~/ 4][v * 4 + i % 4] != 0) order[count++] = i;
    }
    if (count > widest) widest = count;
    if (count > kMaxSkinInfluences) {
      // Keep the largest weights, ties in set order.
      final kept = order.sublist(0, count)
        ..sort((a, b) {
          final byWeight = weightSets[b ~/ 4][v * 4 + b % 4].compareTo(
            weightSets[a ~/ 4][v * 4 + a % 4],
          );
          return byWeight != 0 ? byWeight : a.compareTo(b);
        });
      order.setRange(0, kMaxSkinInfluences, kept);
      dropped++;
      count = kMaxSkinInfluences;
    }
    final base = v * kMaxSkinInfluences;
    if (count == 0) joints[base] = joints0[v * 4];
    for (var k = 0; k < count; k++) {
      final i = order[k];
      joints[base + k] = jointSets[i ~/ 4][v * 4 + i % 4];
      weights[base + k] = weightSets[i ~/ 4][v * 4 + i % 4];
    }
  }
  if (dropped > 0) {
    sceneLog(
      'glTF primitive weights $dropped vertices to more than '
      '$kMaxSkinInfluences joints (up to $widest); each keeps its '
      '$kMaxSkinInfluences largest weights',
    );
  }
  if (widest > 4) {
    return (joints: joints, weights: weights, influences: kMaxSkinInfluences);
  }
  // No vertex needs more than one set: narrow to the 104-byte layout.
  final narrowJoints = Float32List(vertexCount * 4);
  final narrowWeights = Float32List(vertexCount * 4);
  for (var v = 0; v < vertexCount; v++) {
    for (var k = 0; k < 4; k++) {
      narrowJoints[v * 4 + k] = joints[v * kMaxSkinInfluences + k];
      narrowWeights[v * 4 + k] = weights[v * kMaxSkinInfluences + k];
    }
  }
  return (joints: narrowJoints, weights: narrowWeights, influences: 4);
}

Float32List _readVec3(
  int idx,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData,
) {
  final accessor = accessors[idx];
  return readAccessorAsFloat32(accessor, bufferViews, bufferData);
}

Float32List _readVec4(
  int idx,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData,
) {
  final accessor = accessors[idx];
  return readAccessorAsFloat32(accessor, bufferViews, bufferData);
}

Float32List _readOptionalVec4(
  String name,
  GltfMeshPrimitive primitive,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData,
  int vertexCount,
) {
  final idx = primitive.attributes[name];
  if (idx == null) return Float32List(vertexCount * 4);
  return _readVec4(idx, accessors, bufferViews, bufferData);
}

Float32List _readOptionalVec2(
  String name,
  GltfMeshPrimitive primitive,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData,
  int vertexCount,
) {
  final idx = primitive.attributes[name];
  if (idx == null) return Float32List(vertexCount * 2);
  final accessor = accessors[idx];
  return readAccessorAsFloat32(accessor, bufferViews, bufferData);
}

Float32List _readOptionalColor(
  String name,
  GltfMeshPrimitive primitive,
  List<GltfAccessor> accessors,
  List<GltfBufferView> bufferViews,
  Uint8List bufferData,
  int vertexCount,
) {
  final idx = primitive.attributes[name];
  if (idx == null) {
    // Default vertex color = opaque white.
    final out = Float32List(vertexCount * 4);
    for (int i = 0; i < vertexCount; i++) {
      out[i * 4 + 0] = 1.0;
      out[i * 4 + 1] = 1.0;
      out[i * 4 + 2] = 1.0;
      out[i * 4 + 3] = 1.0;
    }
    return out;
  }
  final accessor = accessors[idx];
  final raw = readAccessorAsFloat32(accessor, bufferViews, bufferData);
  if (accessor.type == GltfAccessorType.vec4) return raw;
  // Promote vec3 colors to vec4 with alpha=1.
  final out = Float32List(vertexCount * 4);
  for (int i = 0; i < vertexCount; i++) {
    out[i * 4 + 0] = raw[i * 3 + 0];
    out[i * 4 + 1] = raw[i * 3 + 1];
    out[i * 4 + 2] = raw[i * 3 + 2];
    out[i * 4 + 3] = 1.0;
  }
  return out;
}
