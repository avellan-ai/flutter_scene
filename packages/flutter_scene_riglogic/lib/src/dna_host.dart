// dart:ffi access to the host-built native library, for build-time use
// (buildDnaScenes runs inside an app's build hook, where the package's
// @Native code asset is not loaded). Not imported by app code.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

typedef _Alloc = Pointer<Void> Function(int);
typedef _Free = void Function(Pointer<Void>);

/// Everything the converter reads from one DNA file.
class DnaHostData {
  DnaHostData({
    required this.axes,
    required this.translationUnit,
    required this.jointNames,
    required this.jointParents,
    required this.neutralJointValues,
    required this.lodMeshes,
    required this.meshes,
  });

  /// The coordinate system: tdm::axis_dir for x, y and z (left 0, right 1,
  /// up 2, down 3, front 4, back 5).
  final List<int> axes;

  /// 0 centimetres, 1 metres.
  final int translationUnit;
  final List<String> jointNames;
  final List<int> jointParents;

  /// RigLogic's neutral pose, 10 floats per joint: translation xyz (DNA
  /// units), rotation quaternion xyzw, scale xyz.
  final Float32List neutralJointValues;
  final List<List<int>> lodMeshes;
  final List<DnaHostMesh> meshes;
}

class DnaHostMesh {
  DnaHostMesh({
    required this.name,
    required this.positions,
    required this.normals,
    required this.textureCoordinates,
    required this.layouts,
    required this.faces,
    required this.maxInfluences,
    required this.skinWeights,
    required this.skinJoints,
  });

  final String name;
  final Float32List positions;
  final Float32List normals;
  final Float32List textureCoordinates;

  /// Per vertex layout: position, texture coordinate and normal index.
  final Uint32List layouts;

  /// Polygons as layout indices.
  final List<Uint32List> faces;
  final int maxInfluences;

  /// Per position index, its influences.
  final List<Float32List> skinWeights;
  final List<Uint16List> skinJoints;
}

/// Reads [dna] with the native library at [libraryPath].
DnaHostData readDnaOnHost(String libraryPath, Uint8List dna) {
  final lib = DynamicLibrary.open(libraryPath);
  final alloc = lib.lookupFunction<Pointer<Void> Function(Uint32), _Alloc>('fsrl_alloc');
  final free = lib.lookupFunction<Void Function(Pointer<Void>), _Free>('fsrl_free');
  Pointer<T> allocate<T extends NativeType>(int bytes) => alloc(bytes).cast<T>();

  final dnaOpen = lib.lookupFunction<Pointer<Void> Function(Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32),
      Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Uint8>, int)>('fsrl_dna_open');
  final dnaClose = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fsrl_dna_close');
  final dnaCount = lib.lookupFunction<Uint32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('fsrl_dna_count');
  final jointName =
      lib.lookupFunction<Pointer<Uint8> Function(Pointer<Void>, Uint32), Pointer<Uint8> Function(Pointer<Void>, int)>('fsrl_dna_joint_name');
  final jointParent = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('fsrl_dna_joint_parent');
  final conventions = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Int32>), void Function(Pointer<Void>, Pointer<Int32>)>(
      'fsrl_dna_conventions');
  final lodMeshes = lib.lookupFunction<Uint32 Function(Pointer<Void>, Uint32, Pointer<Uint16>, Uint32),
      int Function(Pointer<Void>, int, Pointer<Uint16>, int)>('fsrl_dna_lod_meshes');
  final meshName =
      lib.lookupFunction<Pointer<Uint8> Function(Pointer<Void>, Uint32), Pointer<Uint8> Function(Pointer<Void>, int)>('fsrl_dna_mesh_name');
  final meshCount = lib.lookupFunction<Uint32 Function(Pointer<Void>, Uint32, Int32), int Function(Pointer<Void>, int, int)>(
      'fsrl_dna_mesh_count');
  final meshFloats = <String, void Function(Pointer<Void>, int, Pointer<Float>)>{
    for (final name in ['fsrl_dna_mesh_positions', 'fsrl_dna_mesh_normals', 'fsrl_dna_mesh_texture_coordinates'])
      name: lib.lookupFunction<Void Function(Pointer<Void>, Uint32, Pointer<Float>), void Function(Pointer<Void>, int, Pointer<Float>)>(name),
  };
  final meshLayouts = lib.lookupFunction<Void Function(Pointer<Void>, Uint32, Pointer<Uint32>),
      void Function(Pointer<Void>, int, Pointer<Uint32>)>('fsrl_dna_mesh_layouts');
  final meshFace = lib.lookupFunction<Uint32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Uint32>, Uint32),
      int Function(Pointer<Void>, int, int, Pointer<Uint32>, int)>('fsrl_dna_mesh_face');
  final meshSkin = lib.lookupFunction<Uint32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Float>, Pointer<Uint16>, Uint32),
      int Function(Pointer<Void>, int, int, Pointer<Float>, Pointer<Uint16>, int)>('fsrl_dna_mesh_skin');
  final rigCreate = lib.lookupFunction<Pointer<Void> Function(Pointer<Uint8>, Uint32, Int32, Pointer<Uint8>, Uint32),
      Pointer<Void> Function(Pointer<Uint8>, int, int, Pointer<Uint8>, int)>('fsrl_rig_create');
  final rigDestroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fsrl_rig_destroy');
  final rigCount = lib.lookupFunction<Uint32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('fsrl_count');
  final rigNeutral = lib.lookupFunction<Pointer<Float> Function(Pointer<Void>), Pointer<Float> Function(Pointer<Void>)>(
      'fsrl_neutral_joint_values');

  String string(Pointer<Uint8> p) {
    if (p == nullptr) return '';
    var n = 0;
    while (p[n] != 0) {
      n++;
    }
    return utf8.decode(p.asTypedList(n));
  }

  const errorCapacity = 512;
  final bytes = allocate<Uint8>(dna.length)..asTypedList(dna.length).setAll(0, dna);
  final error = allocate<Uint8>(errorCapacity)..[0] = 0;
  final handle = dnaOpen(bytes, dna.length, error, errorCapacity);
  if (handle == nullptr) {
    final message = string(error);
    free(bytes.cast());
    free(error.cast());
    throw FormatException('Could not read the DNA: $message');
  }
  final rig = rigCreate(bytes, dna.length, 0, error, errorCapacity);
  if (rig == nullptr) {
    final message = string(error);
    dnaClose(handle);
    free(bytes.cast());
    free(error.cast());
    throw FormatException('RigLogic could not load the DNA: $message');
  }

  try {
    final conv = allocate<Int32>(6 * 4);
    conventions(handle, conv);
    final axes = [conv[0], conv[1], conv[2]];
    final translationUnit = conv[3];
    free(conv.cast());

    final jointCount = dnaCount(handle, 2);
    final neutralCount = rigCount(rig, 12);
    final neutral = Float32List.fromList(rigNeutral(rig).asTypedList(neutralCount));

    final lodCount = dnaCount(handle, 0);
    final lodBuffer = allocate<Uint16>(2 * 1024);
    final lods = <List<int>>[];
    for (var lod = 0; lod < lodCount; lod++) {
      final n = lodMeshes(handle, lod, lodBuffer, 1024);
      lods.add(List<int>.of(lodBuffer.asTypedList(n < 1024 ? n : 1024)));
    }
    free(lodBuffer.cast());

    final meshes = <DnaHostMesh>[];
    for (var m = 0; m < dnaCount(handle, 1); m++) {
      Float32List floats(String fn, int count, int width) {
        final p = allocate<Float>(4 * count * width + 4);
        meshFloats[fn]!(handle, m, p);
        final out = Float32List.fromList(p.asTypedList(count * width));
        free(p.cast());
        return out;
      }

      final positionCount = meshCount(handle, m, 0);
      final layoutCount = meshCount(handle, m, 3);
      final layoutPointer = allocate<Uint32>(4 * 3 * layoutCount + 4);
      meshLayouts(handle, m, layoutPointer);
      final layouts = Uint32List.fromList(layoutPointer.asTypedList(3 * layoutCount));
      free(layoutPointer.cast());

      const faceCapacity = 256;
      final faceBuffer = allocate<Uint32>(4 * faceCapacity);
      final faces = <Uint32List>[];
      for (var f = 0; f < meshCount(handle, m, 4); f++) {
        final n = meshFace(handle, m, f, faceBuffer, faceCapacity);
        if (n > faceCapacity) throw FormatException('Face $f of mesh $m has $n corners');
        faces.add(Uint32List.fromList(faceBuffer.asTypedList(n)));
      }
      free(faceBuffer.cast());

      const influenceCapacity = 64;
      final weightBuffer = allocate<Float>(4 * influenceCapacity);
      final jointBuffer = allocate<Uint16>(2 * influenceCapacity);
      final weights = <Float32List>[];
      final joints = <Uint16List>[];
      for (var v = 0; v < positionCount; v++) {
        final n = meshSkin(handle, m, v, weightBuffer, jointBuffer, influenceCapacity);
        if (n > influenceCapacity) throw FormatException('Vertex $v of mesh $m has $n influences');
        weights.add(Float32List.fromList(weightBuffer.asTypedList(n)));
        joints.add(Uint16List.fromList(jointBuffer.asTypedList(n)));
      }
      free(weightBuffer.cast());
      free(jointBuffer.cast());

      meshes.add(DnaHostMesh(
        name: string(meshName(handle, m)),
        positions: floats('fsrl_dna_mesh_positions', positionCount, 3),
        normals: floats('fsrl_dna_mesh_normals', meshCount(handle, m, 2), 3),
        textureCoordinates: floats('fsrl_dna_mesh_texture_coordinates', meshCount(handle, m, 1), 2),
        layouts: layouts,
        faces: faces,
        maxInfluences: meshCount(handle, m, 5),
        skinWeights: weights,
        skinJoints: joints,
      ));
    }

    return DnaHostData(
      axes: axes,
      translationUnit: translationUnit,
      jointNames: [for (var j = 0; j < jointCount; j++) string(jointName(handle, j))],
      jointParents: [for (var j = 0; j < jointCount; j++) jointParent(handle, j)],
      neutralJointValues: neutral,
      lodMeshes: lods,
      meshes: meshes,
    );
  } finally {
    rigDestroy(rig);
    dnaClose(handle);
    free(bytes.cast());
    free(error.cast());
  }
}
