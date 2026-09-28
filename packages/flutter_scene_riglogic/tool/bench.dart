// ignore_for_file: avoid_print
// Times rig evaluation through the Dart API, per LOD and kernel:
//   dart run tool/bench.dart path/to/rig.dna
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_scene_riglogic/flutter_scene_riglogic.dart';

void main(List<String> args) {
  final dna = File(args.single).readAsBytesSync();
  for (final calculation in [RigLogicCalculation.scalar, RigLogicCalculation.anyVector]) {
    final rig = RigLogicRig.fromDna(dna, calculation: calculation);
    final random = math.Random(1);
    for (var lod = 0; lod < rig.lodCount; lod++) {
      rig.lod = lod;
      const frames = 400;
      final watch = Stopwatch();
      for (var f = 0; f < frames + 50; f++) {
        for (var i = 0; i < rig.rawControls.length; i++) {
          rig.rawControls[i] = random.nextDouble();
        }
        if (f == 50) watch.start();
        rig.calculate();
      }
      watch.stop();
      print('${calculation.name} LOD$lod: ${(watch.elapsedMicroseconds / frames).toStringAsFixed(1)} us/frame');
    }
    rig.dispose();
  }
}
