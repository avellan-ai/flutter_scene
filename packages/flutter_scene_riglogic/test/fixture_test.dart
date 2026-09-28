import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene_riglogic/flutter_scene_riglogic.dart';
import 'package:test/test.dart';

// test/fixtures/fixture.dna is written by native/tools/make_dna.cpp
// (`make_dna fixture`); its header comment gives the rig these values follow.
void main() {
  late RigLogicRig rig;

  setUp(() async {
    await RigLogicRig.ensureInitialized();
    rig = RigLogicRig.fromDna(File('test/fixtures/fixture.dna').readAsBytesSync());
  });

  tearDown(() => rig.dispose());

  test('reads names, hierarchy and sizes', () {
    expect(rig.guiControlNames, ['gui_jaw', 'gui_smile']);
    expect(rig.rawControlNames, ['jawOpen', 'smile', 'blink']);
    expect(rig.jointNames, ['root', 'jaw']);
    expect(rig.jointParents, [-1, 0]);
    expect(rig.blendShapeNames, ['jawOpen_shape', 'jawSmile_corrective']);
    expect(rig.animatedMapNames, ['wrinkle_smile']);
    expect(rig.lodCount, 1);
    expect(rig.jointAttributeCount, 10);
    expect(rig.translationUnit, RigLogicLengthUnit.centimeters);
    expect(rig.jointOutputs.length, 20);
  });

  test('rejects out-of-range LODs and use after dispose', () {
    expect(() => rig.lod = 1, throwsRangeError);
    expect(() => rig.jointAttributeIndices(1), throwsRangeError);
    final other = RigLogicRig.fromDna(File('test/fixtures/fixture.dna').readAsBytesSync())..dispose();
    expect(other.calculate, throwsStateError);
    expect(() => other.lod, throwsStateError);
  });

  test('reports why a DNA fails to load', () {
    expect(() => RigLogicRig.fromDna(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });

  test('maps GUI controls onto raw controls', () {
    rig.guiControls
      ..[0] = 0.8
      ..[1] = 0.6;
    rig.mapGuiToRaw();
    expect(rig.rawControls[0], closeTo(0.8, 1e-6));
    expect(rig.rawControls[1], closeTo(0.3, 1e-6));
  });

  for (final (jaw, smile) in [(0.0, 0.0), (0.25, 0.15), (0.5, 0.3), (1.0, 0.6)]) {
    test('evaluates jaw $jaw smile $smile', () {
      rig.rawControls
        ..[0] = jaw
        ..[1] = smile;
      rig.calculate();
      final psd = jaw * smile;
      final jawT = rig.jointOutputs.sublist(10, 13);
      final jawQ = rig.jointOutputs.sublist(13, 17);
      expect(jawT[1], closeTo(-2 * jaw + 0.5 * psd, 1e-5));
      final half = (20 * jaw) * math.pi / 360;
      expect(jawQ[0], closeTo(math.sin(half), 1e-5));
      expect(jawQ[3], closeTo(math.cos(half), 1e-5));
      expect(rig.blendShapeOutputs[0], closeTo(jaw, 1e-6));
      expect(rig.blendShapeOutputs[1], closeTo(psd, 1e-6));
      expect(rig.animatedMapOutputs[0], closeTo((2 * smile - 0.5).clamp(0, 1), 1e-6));
    });
  }
}
