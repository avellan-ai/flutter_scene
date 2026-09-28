import 'dart:typed_data';

/// Table selectors for [RigBackend.count] and [RigBackend.name], matching
/// `enum FsrlKind` in native/flutter_scene_riglogic.h.
abstract final class Kind {
  static const guiControls = 0;
  static const rawControls = 1;
  static const psdControls = 2;
  static const mlControls = 3;
  static const rbfControls = 4;
  static const joints = 5;
  static const blendShapeChannels = 6;
  static const animatedMaps = 7;
  static const lods = 8;
  static const jointOutputs = 9;
  static const blendShapeOutputs = 10;
  static const animatedMapOutputs = 11;
  static const neutralJointValues = 12;
  static const jointAttributes = 13;
  static const meshes = 14;
}

/// One loaded rig behind the C ABI, either in the native library or in the
/// WebAssembly module. Buffers are returned as copies, so callers never hold
/// views into memory that may move.
abstract class RigBackend {
  int count(int kind);
  String name(int kind, int index);
  int jointParent(int joint);
  int translationUnit();
  List<int> axes();
  List<int> lodMeshes(int lod);
  int rotationUnit();

  void writeGuiControls(Float32List values);
  void writeRawControls(Float32List values);
  Float32List readRawControls();
  void mapGuiToRaw();

  int get lod;
  set lod(int value);

  void calculate();
  void readJointOutputs(Float32List into);
  void readBlendShapeOutputs(Float32List into);
  void readAnimatedMapOutputs(Float32List into);
  Float32List readNeutralJointValues();
  Uint16List readJointAttributeIndices(int lod);

  void dispose();
}
