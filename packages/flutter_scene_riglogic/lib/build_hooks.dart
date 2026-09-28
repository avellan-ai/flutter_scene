/// Build-time support for DNA characters: call [buildDnaScenes] from an
/// app's `hook/build.dart` (next to flutter_scene's `buildScenes`) to turn
/// every `.dna` under `assets/` into a scene the app loads with
/// `loadScene(dnaSceneId('assets/x.dna'))`.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

import 'src/dna_host.dart';
import 'src/dna_scene_id.dart';
import 'src/dna_to_glb.dart';
import 'src/native_build.dart';

export 'src/dna_scene_id.dart' show dnaSceneId;

/// Converts each `.dna` under [discoveryRoot] into a skinned glTF (the
/// skeleton in its neutral pose and the meshes of [lods], or of every LOD
/// when null) under `.dart_tool/flutter_scene_riglogic/`, then imports those
/// with flutter_scene's [buildScenes].
///
/// The DNA is read with the package's native library, built for the host
/// with CMake on first use. Runtime rig evaluation still needs the `.dna`
/// itself, listed as an asset.
Future<void> buildDnaScenes({
  required BuildInput buildInput,
  required BuildOutputBuilder buildOutput,
  String discoveryRoot = 'assets/',
  List<int>? lods,
}) async {
  final packageRoot = buildInput.packageRoot;
  final root = Directory.fromUri(packageRoot.resolve(discoveryRoot));
  if (!root.existsSync()) return;
  buildOutput.dependencies.add(root.uri);
  final sources = <File>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) buildOutput.dependencies.add(entity.uri);
    if (entity is File && entity.path.endsWith('.dna')) sources.add(entity);
  }
  if (sources.isEmpty) return;

  final ourRoot = (await Isolate.resolvePackageUri(Uri.parse('package:flutter_scene_riglogic/')))!.resolve('../');
  final library = await buildNativeLibrary(
    packageRoot: ourRoot,
    buildDir: buildInput.outputDirectoryShared.resolve('flutter_scene_riglogic/host-${hostOS.name}-${hostArchitecture.name}/'),
    os: hostOS,
    architecture: hostArchitecture,
  );
  buildOutput.dependencies.addAll(nativeSourceDependencies(ourRoot));

  final generated = <String>[];
  for (final source in sources) {
    final relative = source.uri.path.substring(packageRoot.path.length);
    final sceneId = dnaSceneId(relative);
    final output = File.fromUri(packageRoot.resolve('$sceneId.glb'));
    await output.parent.create(recursive: true);
    final dna = readDnaOnHost(library.toFilePath(), await source.readAsBytes());
    await output.writeAsBytes(dnaToGlb(dna, name: relative, lods: lods));
    buildOutput.dependencies.add(source.uri);
    generated.add('$sceneId.glb');
  }
  buildScenes(buildInput: buildInput, buildOutput: buildOutput, inputFilePaths: generated);
}
