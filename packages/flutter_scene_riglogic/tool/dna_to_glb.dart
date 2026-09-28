// ignore_for_file: avoid_print
// Converts a DNA file to the skinned glTF buildDnaScenes produces:
//   dart run tool/dna_to_glb.dart in.dna out.glb --lib <native library> [--lods 1,3]
import 'dart:io';

import 'package:flutter_scene_riglogic/src/dna_host.dart';
import 'package:flutter_scene_riglogic/src/dna_to_glb.dart';

void main(List<String> args) {
  final lib = args[args.indexOf('--lib') + 1];
  final lodsIndex = args.indexOf('--lods');
  final lods = lodsIndex < 0 ? null : args[lodsIndex + 1].split(',').map(int.parse).toList();
  final dna = readDnaOnHost(lib, File(args[0]).readAsBytesSync());
  final glb = dnaToGlb(dna, name: args[0], lods: lods);
  File(args[1]).writeAsBytesSync(glb);
  print('${args[1]}: ${glb.length} bytes, ${dna.jointNames.length} joints, lods ${lods ?? 'all'}');
}
