// WebAssembly backend: the same C ABI, compiled with Emscripten as a
// standalone module (native/CMakeLists.txt). Pointers are offsets into the
// module's linear memory; views are rebuilt on every access because memory
// growth detaches old ones.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'backend.dart';

/// Where the module is fetched from. Build it with
/// `emcmake cmake -S native -B build-wasm && cmake --build build-wasm`
/// and serve flutter_scene_riglogic_native.wasm next to the app, or point
/// this at another URL with --dart-define.
const _wasmUrl = String.fromEnvironment(
  'FLUTTER_SCENE_RIGLOGIC_WASM_URL',
  defaultValue: 'flutter_scene_riglogic_native.wasm',
);

_Exports? _exports;

Future<void> ensureBackendReady() async {
  if (_exports != null) return;
  final response = await _fetch(_wasmUrl.toJS).toDart;
  if (!response.ok) {
    throw StateError('Could not download the RigLogic wasm module from $_wasmUrl: HTTP ${response.status}');
  }
  final bytes = await response.arrayBuffer().toDart;
  final imports = JSObject();
  final env = JSObject();
  env.setProperty('emscripten_notify_memory_growth'.toJS, ((JSAny? _) {}).toJS);
  imports.setProperty('env'.toJS, env);
  final result = await _instantiate(bytes, imports).toDart;
  final exports = result.instance.exports;
  exports.initialize();
  _exports = exports;
}

RigBackend createBackend(Uint8List dna, int calculation) {
  final e = _exports;
  if (e == null) {
    throw StateError('Await RigLogicRig.ensureInitialized() before loading a rig on the web.');
  }
  const errorCapacity = 512;
  final buffer = e.alloc(dna.length.toJS).toDartInt;
  final error = e.alloc(errorCapacity.toJS).toDartInt;
  _bytes(e)
    ..setAll(buffer, dna)
    ..[error] = 0;
  final rig = e.create(buffer.toJS, dna.length.toJS, calculation.toJS, error.toJS, errorCapacity.toJS).toDartInt;
  final message = _string(e, error);
  e.free(buffer.toJS);
  e.free(error.toJS);
  if (rig == 0) {
    throw FormatException('OpenRigLogic could not load the DNA: $message');
  }
  return _WasmBackend(e, rig);
}

Uint8List _bytes(_Exports e) => e.memory.buffer.toDart.asUint8List();

Float32List _floats(_Exports e, int pointer, int count) =>
    e.memory.buffer.toDart.asFloat32List(pointer, count);

String _string(_Exports e, int pointer) {
  if (pointer == 0) return '';
  final bytes = _bytes(e);
  var end = pointer;
  while (bytes[end] != 0) {
    end++;
  }
  return utf8.decode(Uint8List.sublistView(bytes, pointer, end));
}

class _WasmBackend implements RigBackend {
  _WasmBackend(this._e, this._rig);

  final _Exports _e;
  int _rig;

  JSNumber get _r => _rig.toJS;

  Float32List _view(int pointer, int kind) => _floats(_e, pointer, count(kind));

  @override
  int count(int kind) => _e.count(_r, kind.toJS).toDartInt;

  @override
  String name(int kind, int index) => _string(_e, _e.name(_r, kind.toJS, index.toJS).toDartInt);

  @override
  int jointParent(int joint) => _e.jointParent(_r, joint.toJS).toDartInt;

  @override
  int translationUnit() => _e.translationUnit(_r).toDartInt;

  @override
  int rotationUnit() => _e.rotationUnit(_r).toDartInt;

  @override
  void writeGuiControls(Float32List values) =>
      _view(_e.guiControls(_r).toDartInt, Kind.guiControls).setAll(0, values);

  @override
  void writeRawControls(Float32List values) =>
      _view(_e.rawControls(_r).toDartInt, Kind.rawControls).setAll(0, values);

  @override
  Float32List readRawControls() => Float32List.fromList(_view(_e.rawControls(_r).toDartInt, Kind.rawControls));

  @override
  void mapGuiToRaw() => _e.mapGuiToRaw(_r);

  @override
  int get lod => _e.getLod(_r).toDartInt;

  @override
  set lod(int value) => _e.setLod(_r, value.toJS);

  @override
  void calculate() => _e.calculate(_r);

  @override
  void readJointOutputs(Float32List into) =>
      into.setAll(0, _view(_e.jointOutputs(_r).toDartInt, Kind.jointOutputs));

  @override
  void readBlendShapeOutputs(Float32List into) =>
      into.setAll(0, _view(_e.blendShapeOutputs(_r).toDartInt, Kind.blendShapeOutputs));

  @override
  void readAnimatedMapOutputs(Float32List into) =>
      into.setAll(0, _view(_e.animatedMapOutputs(_r).toDartInt, Kind.animatedMapOutputs));

  @override
  Float32List readNeutralJointValues() =>
      Float32List.fromList(_view(_e.neutralJointValues(_r).toDartInt, Kind.neutralJointValues));

  @override
  Uint16List readJointAttributeIndices(int lod) {
    final countPointer = _e.alloc(4.toJS).toDartInt;
    final indices = _e.jointAttributeIndices(_r, lod.toJS, countPointer.toJS).toDartInt;
    final memory = _e.memory.buffer.toDart;
    final count = memory.asByteData().getUint32(countPointer, Endian.little);
    final result = indices == 0 ? Uint16List(0) : Uint16List.fromList(memory.asUint16List(indices, count));
    _e.free(countPointer.toJS);
    return result;
  }

  @override
  void dispose() {
    if (_rig == 0) return;
    _e.destroy(_r);
    _rig = 0;
  }
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('WebAssembly.instantiate')
external JSPromise<_Source> _instantiate(JSArrayBuffer bytes, JSObject imports);

extension type _Source(JSObject _) implements JSObject {
  external _Instance get instance;
}

extension type _Instance(JSObject _) implements JSObject {
  external _Exports get exports;
}

extension type _Memory(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

extension type _Exports(JSObject _) implements JSObject {
  external _Memory get memory;
  @JS('_initialize')
  external void initialize();
  @JS('fsrl_alloc')
  external JSNumber alloc(JSNumber size);
  @JS('fsrl_free')
  external void free(JSNumber pointer);
  @JS('fsrl_rig_create')
  external JSNumber create(JSNumber dna, JSNumber length, JSNumber calculation, JSNumber error, JSNumber errorCapacity);
  @JS('fsrl_rig_destroy')
  external void destroy(JSNumber rig);
  @JS('fsrl_count')
  external JSNumber count(JSNumber rig, JSNumber kind);
  @JS('fsrl_name')
  external JSNumber name(JSNumber rig, JSNumber kind, JSNumber index);
  @JS('fsrl_joint_parent')
  external JSNumber jointParent(JSNumber rig, JSNumber joint);
  @JS('fsrl_translation_unit')
  external JSNumber translationUnit(JSNumber rig);
  @JS('fsrl_rotation_unit')
  external JSNumber rotationUnit(JSNumber rig);
  @JS('fsrl_gui_controls')
  external JSNumber guiControls(JSNumber rig);
  @JS('fsrl_raw_controls')
  external JSNumber rawControls(JSNumber rig);
  @JS('fsrl_map_gui_to_raw')
  external void mapGuiToRaw(JSNumber rig);
  @JS('fsrl_set_lod')
  external void setLod(JSNumber rig, JSNumber lod);
  @JS('fsrl_get_lod')
  external JSNumber getLod(JSNumber rig);
  @JS('fsrl_calculate')
  external void calculate(JSNumber rig);
  @JS('fsrl_joint_outputs')
  external JSNumber jointOutputs(JSNumber rig);
  @JS('fsrl_blend_shape_outputs')
  external JSNumber blendShapeOutputs(JSNumber rig);
  @JS('fsrl_animated_map_outputs')
  external JSNumber animatedMapOutputs(JSNumber rig);
  @JS('fsrl_neutral_joint_values')
  external JSNumber neutralJointValues(JSNumber rig);
  @JS('fsrl_joint_attribute_indices')
  external JSNumber jointAttributeIndices(JSNumber rig, JSNumber lod, JSNumber count);
}
