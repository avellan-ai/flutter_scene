import 'dart:typed_data';

import 'backend.dart';
import 'backend_io.dart' if (dart.library.js_interop) 'backend_web.dart' as platform;

/// Which RigLogic kernel evaluates joints. Scalar is exact on every
/// platform and is the only one on the web; the vector kernels are faster
/// natively (SSE on x86-64, NEON on arm64) but differ slightly in the last
/// digits.
enum RigLogicCalculation { scalar, sse, avx, neon, anyVector }

/// A MetaHuman-compatible facial rig: a DNA file evaluated by Epic's
/// OpenRigLogic every frame.
///
/// Write controls (raw controls directly, or GUI controls followed by
/// [mapGuiToRaw]), call [calculate], then read [jointOutputs],
/// [blendShapeOutputs] and [animatedMapOutputs].
///
/// Joint outputs are deltas from the neutral pose, [jointAttributeCount]
/// floats per joint: translation x, y, z (in [translationUnit]), a rotation
/// quaternion x, y, z, w, and scale x, y, z. Normalize the quaternion before
/// use; the vector kernels do not always return unit length.
class RigLogicRig {
  RigLogicRig._(this._backend)
      : guiControlNames = _names(_backend, Kind.guiControls),
        rawControlNames = _names(_backend, Kind.rawControls),
        jointNames = _names(_backend, Kind.joints),
        blendShapeNames = _names(_backend, Kind.blendShapeChannels),
        animatedMapNames = _names(_backend, Kind.animatedMaps),
        jointParents = List.unmodifiable([
          for (var i = 0; i < _backend.count(Kind.joints); i++) _backend.jointParent(i),
        ]),
        lodCount = _backend.count(Kind.lods),
        jointAttributeCount = _backend.count(Kind.jointAttributes),
        translationUnit = _backend.translationUnit() == 0 ? RigLogicLengthUnit.centimeters : RigLogicLengthUnit.meters,
        neutralJointValues = _backend.readNeutralJointValues(),
        guiControls = Float32List(_backend.count(Kind.guiControls)),
        rawControls = Float32List(_backend.count(Kind.rawControls)),
        jointOutputs = Float32List(_backend.count(Kind.jointOutputs)),
        blendShapeOutputs = Float32List(_backend.count(Kind.blendShapeOutputs)),
        animatedMapOutputs = Float32List(_backend.count(Kind.animatedMapOutputs));

  /// Loads the WebAssembly module on the web; completes at once natively.
  static Future<void> ensureInitialized() => platform.ensureBackendReady();

  /// Parses [dna] (a binary .dna file) and builds the rig. Geometry in the
  /// file is ignored here.
  factory RigLogicRig.fromDna(Uint8List dna, {RigLogicCalculation calculation = RigLogicCalculation.scalar}) =>
      RigLogicRig._(platform.createBackend(dna, calculation.index));

  final RigBackend _backend;

  final List<String> guiControlNames;
  final List<String> rawControlNames;
  final List<String> jointNames;
  final List<String> blendShapeNames;
  final List<String> animatedMapNames;

  /// Parent joint index per joint, -1 for roots.
  final List<int> jointParents;
  final int lodCount;
  final int jointAttributeCount;
  final RigLogicLengthUnit translationUnit;

  /// The neutral pose, laid out like [jointOutputs].
  final Float32List neutralJointValues;

  /// Inputs: edit in place, then [calculate] (after [mapGuiToRaw] for GUI).
  final Float32List guiControls;
  final Float32List rawControls;

  /// Outputs of the last [calculate].
  final Float32List jointOutputs;
  final Float32List blendShapeOutputs;
  final Float32List animatedMapOutputs;

  bool _disposed = false;

  RigBackend get _live {
    if (_disposed) throw StateError('This RigLogicRig has been disposed.');
    return _backend;
  }

  void _checkLod(int value) {
    if (value < 0 || value >= lodCount) throw RangeError.range(value, 0, lodCount - 1, 'lod');
  }

  int get lod => _live.lod;
  set lod(int value) {
    _checkLod(value);
    _live.lod = value;
  }

  /// Joint output indices that can change at [lod]; the others stay zero.
  Uint16List jointAttributeIndices(int lod) {
    _checkLod(lod);
    return _live.readJointAttributeIndices(lod);
  }

  /// Maps [guiControls] onto [rawControls] through the rig's GUI table.
  void mapGuiToRaw() {
    final backend = _live;
    backend.writeGuiControls(guiControls);
    backend.mapGuiToRaw();
    rawControls.setAll(0, backend.readRawControls());
  }

  /// Evaluates the rig from [rawControls] and refreshes the outputs.
  void calculate() {
    final backend = _live;
    backend.writeRawControls(rawControls);
    backend.calculate();
    backend.readJointOutputs(jointOutputs);
    backend.readBlendShapeOutputs(blendShapeOutputs);
    backend.readAnimatedMapOutputs(animatedMapOutputs);
  }

  /// Frees the native rig. Every other member except the name lists and the
  /// last outputs throws [StateError] afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _backend.dispose();
  }

  static List<String> _names(RigBackend backend, int kind) =>
      List.unmodifiable([for (var i = 0; i < backend.count(kind); i++) backend.name(kind, i)]);
}

enum RigLogicLengthUnit { centimeters, meters }
