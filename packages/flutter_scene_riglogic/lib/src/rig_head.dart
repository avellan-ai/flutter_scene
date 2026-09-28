import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'dna_scene_id.dart';
import 'rig.dart';

/// A DNA character in a flutter_scene scene: the skinned meshes and skeleton
/// that buildDnaScenes converted, driven every frame by its RigLogic rig.
///
/// Write the rig's controls ([rig].rawControls, or guiControls plus
/// mapGuiToRaw), then call [update] (or attach a [RigLogicComponent]).
/// Joint deltas are composed onto the neutral pose: translation plus delta,
/// rotation neutral times delta, scale plus delta. [blendShapeWeights] and
/// [animatedMapWeights] are exposed for morph targets and wrinkle-map
/// materials.
class RigLogicHead {
  RigLogicHead._(this.node, this.rig, this._joints, this._meshNodes, this._axes, this._unit)
      : _neutral = [
          for (final joint in _joints)
            joint == null ? null : (joint.position, joint.rotation, joint.scale),
        ] {
    lod = 0;
  }

  /// Loads `dnaAsset` (listed as an asset) for the rig and its converted
  /// scene for the meshes and skeleton.
  static Future<RigLogicHead> load(
    String dnaAsset, {
    AssetBundle? bundle,
    RigLogicCalculation calculation = RigLogicCalculation.scalar,
  }) async {
    await RigLogicRig.ensureInitialized();
    final data = await (bundle ?? rootBundle).load(dnaAsset);
    final rig = RigLogicRig.fromDna(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), calculation: calculation);
    try {
      final node = await loadScene(dnaSceneId(dnaAsset), bundle: bundle);
      return RigLogicHead._(
        node,
        rig,
        [for (final name in rig.jointNames) node.getChildByName(name)],
        [for (final name in rig.meshNames) node.getChildByName(name)],
        _engineAxes(rig.axes),
        rig.translationUnit == RigLogicLengthUnit.centimeters ? 0.01 : 1.0,
      );
    } catch (_) {
      rig.dispose();
      rethrow;
    }
  }

  final Node node;
  final RigLogicRig rig;
  final List<Node?> _joints;
  final List<(vm.Vector3, vm.Quaternion, vm.Vector3)?> _neutral;
  final List<Node?> _meshNodes;

  /// DNA axes to engine axes: glTF's axes, then the importer's z mirror.
  final vm.Matrix3 _axes;
  final double _unit;
  List<int> _animated = const [];
  final _translation = vm.Vector3.zero();
  final _scale = vm.Vector3.zero();

  int get lod => rig.lod;

  /// Switches the rig's LOD, shows only that LOD's meshes (meshes that were
  /// not converted stay absent), and returns joints the LOD no longer animates
  /// to their neutral pose.
  set lod(int value) {
    rig.lod = value;
    final shown = rig.lodMeshes(value).toSet();
    for (var m = 0; m < _meshNodes.length; m++) {
      _meshNodes[m]?.visible = shown.contains(m);
    }
    final animated = {for (final index in rig.jointAttributeIndices(value)) index ~/ rig.jointAttributeCount};
    for (var j = 0; j < _joints.length; j++) {
      final neutral = _neutral[j];
      if (neutral != null && !animated.contains(j)) {
        _joints[j]!.localTransform = vm.Matrix4.compose(neutral.$1, neutral.$2, neutral.$3);
      }
    }
    _animated = [
      for (final j in animated)
        if (_joints[j] != null) j,
    ]..sort();
  }

  Float32List get blendShapeWeights => rig.blendShapeOutputs;
  Float32List get animatedMapWeights => rig.animatedMapOutputs;

  /// How long the last [update] spent evaluating the rig and posing the
  /// skeleton, in microseconds.
  ({int evaluate, int pose}) get lastUpdateMicros => (evaluate: _evaluateMicros, pose: _poseMicros);
  int _evaluateMicros = 0, _poseMicros = 0;
  final _watch = Stopwatch();

  /// Evaluates the rig from its controls and poses the skeleton.
  void update() {
    _watch
      ..reset()
      ..start();
    rig.calculate();
    _evaluateMicros = _watch.elapsedMicroseconds;
    final out = rig.jointOutputs;
    final stride = rig.jointAttributeCount;
    final a = _axes.storage;
    for (final j in _animated) {
      final (t, q, s) = _neutral[j]!;
      final o = stride * j;
      final dx = out[o], dy = out[o + 1], dz = out[o + 2];
      _translation.setValues(
        t.x + (a[0] * dx + a[3] * dy + a[6] * dz) * _unit,
        t.y + (a[1] * dx + a[4] * dy + a[7] * dz) * _unit,
        t.z + (a[2] * dx + a[5] * dy + a[8] * dz) * _unit,
      );
      // A reflection maps a rotation quaternion's vector part v to -Rv.
      final qx = out[o + 3], qy = out[o + 4], qz = out[o + 5];
      final delta = vm.Quaternion(
        -(a[0] * qx + a[3] * qy + a[6] * qz),
        -(a[1] * qx + a[4] * qy + a[7] * qz),
        -(a[2] * qx + a[5] * qy + a[8] * qz),
        out[o + 6],
      );
      final rotation = (q * delta)..normalize();
      final sx = out[o + 7], sy = out[o + 8], sz = out[o + 9];
      _scale.setValues(
        s.x + (a[0].abs() * sx + a[3].abs() * sy + a[6].abs() * sz),
        s.y + (a[1].abs() * sx + a[4].abs() * sy + a[7].abs() * sz),
        s.z + (a[2].abs() * sx + a[5].abs() * sy + a[8].abs() * sz),
      );
      _joints[j]!.localTransform = vm.Matrix4.compose(_translation, rotation, _scale);
    }
    _poseMicros = _watch.elapsedMicroseconds - _evaluateMicros;
    _watch.stop();
  }

  void dispose() => rig.dispose();

  static vm.Matrix3 _engineAxes(List<int> axes) {
    vm.Vector3 direction(int axis) => switch (axis) {
          0 => vm.Vector3(1, 0, 0),
          1 => vm.Vector3(-1, 0, 0),
          2 => vm.Vector3(0, 1, 0),
          3 => vm.Vector3(0, -1, 0),
          4 => vm.Vector3(0, 0, 1),
          5 => vm.Vector3(0, 0, -1),
          _ => throw FormatException('Unknown DNA axis direction $axis'),
        };
    final toGltf = vm.Matrix3.columns(direction(axes[0]), direction(axes[1]), direction(axes[2]));
    // flutter_scene's offline importer bakes a z mirror into imported scenes.
    return vm.Matrix3.columns(vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0), vm.Vector3(0, 0, -1)) * toGltf;
  }
}

/// Updates a [RigLogicHead] once per frame. Attach it to any node.
class RigLogicComponent extends Component {
  RigLogicComponent(this.head, {this.beforeUpdate});

  final RigLogicHead head;

  /// Called with the frame's delta before the rig is evaluated, to write
  /// controls.
  final void Function(double deltaSeconds)? beforeUpdate;

  @override
  void update(double deltaSeconds) {
    beforeUpdate?.call(deltaSeconds);
    head.update();
  }
}
