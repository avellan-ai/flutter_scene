// dart:ffi backend: the OpenRigLogic C ABI in the native library the build
// hook bundles.

@DefaultAsset('package:flutter_scene_riglogic/flutter_scene_riglogic_native')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'backend.dart';

final class _Rig extends Opaque {}

@Native<Pointer<Void> Function(Uint32)>(symbol: 'fsrl_alloc')
external Pointer<Void> _alloc(int size);
@Native<Void Function(Pointer<Void>)>(symbol: 'fsrl_free')
external void _free(Pointer<Void> pointer);
@Native<Pointer<_Rig> Function(Pointer<Uint8>, Uint32, Int32, Pointer<Uint8>, Uint32)>(symbol: 'fsrl_rig_create')
external Pointer<_Rig> _create(Pointer<Uint8> dna, int length, int calculation, Pointer<Uint8> error, int errorCapacity);
@Native<Void Function(Pointer<_Rig>)>(symbol: 'fsrl_rig_destroy')
external void _destroy(Pointer<_Rig> rig);
@Native<Uint32 Function(Pointer<_Rig>, Int32)>(symbol: 'fsrl_count')
external int _count(Pointer<_Rig> rig, int kind);
@Native<Pointer<Uint8> Function(Pointer<_Rig>, Int32, Uint32)>(symbol: 'fsrl_name')
external Pointer<Uint8> _name(Pointer<_Rig> rig, int kind, int index);
@Native<Int32 Function(Pointer<_Rig>, Uint32)>(symbol: 'fsrl_joint_parent')
external int _jointParent(Pointer<_Rig> rig, int joint);
@Native<Void Function(Pointer<_Rig>, Pointer<Int32>)>(symbol: 'fsrl_axes')
external void _axes(Pointer<_Rig> rig, Pointer<Int32> out3);
@Native<Uint32 Function(Pointer<_Rig>, Uint32, Pointer<Uint16>, Uint32)>(symbol: 'fsrl_lod_meshes')
external int _lodMeshes(Pointer<_Rig> rig, int lod, Pointer<Uint16> out, int capacity);
@Native<Int32 Function(Pointer<_Rig>)>(symbol: 'fsrl_translation_unit')
external int _translationUnit(Pointer<_Rig> rig);
@Native<Int32 Function(Pointer<_Rig>)>(symbol: 'fsrl_rotation_unit')
external int _rotationUnit(Pointer<_Rig> rig);
@Native<Pointer<Float> Function(Pointer<_Rig>)>(symbol: 'fsrl_gui_controls')
external Pointer<Float> _guiControls(Pointer<_Rig> rig);
@Native<Pointer<Float> Function(Pointer<_Rig>)>(symbol: 'fsrl_raw_controls')
external Pointer<Float> _rawControls(Pointer<_Rig> rig);
@Native<Void Function(Pointer<_Rig>)>(symbol: 'fsrl_map_gui_to_raw')
external void _mapGuiToRaw(Pointer<_Rig> rig);
@Native<Void Function(Pointer<_Rig>, Uint32)>(symbol: 'fsrl_set_lod')
external void _setLod(Pointer<_Rig> rig, int lod);
@Native<Uint32 Function(Pointer<_Rig>)>(symbol: 'fsrl_get_lod')
external int _getLod(Pointer<_Rig> rig);
@Native<Void Function(Pointer<_Rig>)>(symbol: 'fsrl_calculate')
external void _calculate(Pointer<_Rig> rig);
@Native<Pointer<Float> Function(Pointer<_Rig>)>(symbol: 'fsrl_joint_outputs')
external Pointer<Float> _jointOutputs(Pointer<_Rig> rig);
@Native<Pointer<Float> Function(Pointer<_Rig>)>(symbol: 'fsrl_blend_shape_outputs')
external Pointer<Float> _blendShapeOutputs(Pointer<_Rig> rig);
@Native<Pointer<Float> Function(Pointer<_Rig>)>(symbol: 'fsrl_animated_map_outputs')
external Pointer<Float> _animatedMapOutputs(Pointer<_Rig> rig);
@Native<Pointer<Float> Function(Pointer<_Rig>)>(symbol: 'fsrl_neutral_joint_values')
external Pointer<Float> _neutralJointValues(Pointer<_Rig> rig);
@Native<Pointer<Uint16> Function(Pointer<_Rig>, Uint32, Pointer<Uint32>)>(symbol: 'fsrl_joint_attribute_indices')
external Pointer<Uint16> _jointAttributeIndices(Pointer<_Rig> rig, int lod, Pointer<Uint32> count);

String _string(Pointer<Uint8> p) {
  if (p == nullptr) return '';
  var length = 0;
  while (p[length] != 0) {
    length++;
  }
  return utf8.decode(p.asTypedList(length));
}

Future<void> ensureBackendReady() async {}

RigBackend createBackend(Uint8List dna, int calculation) {
  const errorCapacity = 512;
  final buffer = _alloc(dna.length).cast<Uint8>();
  final error = _alloc(errorCapacity).cast<Uint8>();
  error[0] = 0;
  buffer.asTypedList(dna.length).setAll(0, dna);
  final rig = _create(buffer, dna.length, calculation, error, errorCapacity);
  final message = _string(error);
  _free(buffer.cast());
  _free(error.cast());
  if (rig == nullptr) {
    throw FormatException('OpenRigLogic could not load the DNA: $message');
  }
  return _NativeBackend(rig);
}

class _NativeBackend implements RigBackend {
  _NativeBackend(this._rig);

  Pointer<_Rig> _rig;

  Float32List _view(Pointer<Float> p, int kind) => p.asTypedList(count(kind));

  @override
  int count(int kind) => _count(_rig, kind);

  @override
  String name(int kind, int index) => _string(_name(_rig, kind, index));

  @override
  int jointParent(int joint) => _jointParent(_rig, joint);

  @override
  int translationUnit() => _translationUnit(_rig);

  @override
  int rotationUnit() => _rotationUnit(_rig);

  @override
  List<int> axes() {
    final out = _alloc(12).cast<Int32>();
    _axes(_rig, out);
    final result = List<int>.of(out.asTypedList(3));
    _free(out.cast());
    return result;
  }

  @override
  List<int> lodMeshes(int lod) {
    final count = _lodMeshes(_rig, lod, nullptr, 0);
    final out = _alloc(2 * count + 2).cast<Uint16>();
    _lodMeshes(_rig, lod, out, count);
    final result = List<int>.of(out.asTypedList(count));
    _free(out.cast());
    return result;
  }

  @override
  void writeGuiControls(Float32List values) => _view(_guiControls(_rig), Kind.guiControls).setAll(0, values);

  @override
  void writeRawControls(Float32List values) => _view(_rawControls(_rig), Kind.rawControls).setAll(0, values);

  @override
  Float32List readRawControls() => Float32List.fromList(_view(_rawControls(_rig), Kind.rawControls));

  @override
  void mapGuiToRaw() => _mapGuiToRaw(_rig);

  @override
  int get lod => _getLod(_rig);

  @override
  set lod(int value) => _setLod(_rig, value);

  @override
  void calculate() => _calculate(_rig);

  @override
  void readJointOutputs(Float32List into) => into.setAll(0, _view(_jointOutputs(_rig), Kind.jointOutputs));

  @override
  void readBlendShapeOutputs(Float32List into) =>
      into.setAll(0, _view(_blendShapeOutputs(_rig), Kind.blendShapeOutputs));

  @override
  void readAnimatedMapOutputs(Float32List into) =>
      into.setAll(0, _view(_animatedMapOutputs(_rig), Kind.animatedMapOutputs));

  @override
  Float32List readNeutralJointValues() =>
      Float32List.fromList(_view(_neutralJointValues(_rig), Kind.neutralJointValues));

  @override
  Uint16List readJointAttributeIndices(int lod) {
    final count = _alloc(4).cast<Uint32>();
    final indices = _jointAttributeIndices(_rig, lod, count);
    final result = indices == nullptr ? Uint16List(0) : Uint16List.fromList(indices.asTypedList(count.value));
    _free(count.cast());
    return result;
  }

  @override
  void dispose() {
    if (_rig == nullptr) return;
    _destroy(_rig);
    _rig = nullptr;
  }
}
