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
  final packagePath = packageRoot.toFilePath(windows: false);
  final sources = <File>[];
  var watched = Directory.fromUri(packageRoot.resolve(discoveryRoot));
  if (watched.existsSync()) {
    // A directory dependency is hashed as the names of its direct children,
    // so every directory the listing walks is declared.
    buildOutput.dependencies.add(watched.uri);
    for (final entity in watched.listSync(recursive: true, followLinks: false)) {
      if (entity is Directory) buildOutput.dependencies.add(entity.uri);
      if (entity is File && entity.path.endsWith('.dna')) sources.add(entity);
    }
  } else {
    // Watch the nearest existing parent, so creating the root reruns the hook.
    while (!watched.existsSync() && watched.parent.path != watched.path) {
      watched = watched.parent;
    }
    buildOutput.dependencies.add(watched.uri);
  }
  sources.sort((a, b) => a.path.compareTo(b.path));

  final generated = <String>[];
  if (sources.isNotEmpty) {
    final ourRoot = (await Isolate.resolvePackageUri(Uri.parse('package:flutter_scene_riglogic/')))!.resolve('../');
    final library = await buildNativeLibrary(
      packageRoot: ourRoot,
      buildDir: buildInput.outputDirectoryShared.resolve('flutter_scene_riglogic/host-${hostOS.name}-${hostArchitecture.name}/'),
      os: hostOS,
      architecture: hostArchitecture,
    );
    buildOutput.dependencies.addAll(nativeSourceDependencies(ourRoot));

    for (final source in sources) {
      // Decoded and package-relative, as the app names the asset.
      final relative = source.uri.toFilePath(windows: false).substring(packagePath.length);
      // buildScenes resolves its inputs as URI references, where these
      // would start a query or fragment or read as an escape.
      if (relative.contains(RegExp('[#?%]'))) {
        throw FormatException('DNA file names cannot contain #, ? or %: $relative');
      }
      final sceneId = dnaSceneId(relative);
      final output = File.fromUri(packageRoot.resolve(Uri(path: '$sceneId.glb').path));
      final dna = readDnaOnHost(library.toFilePath(), await source.readAsBytes());
      final glb = dnaToGlb(dna, name: relative, lods: lods);
      // An unchanged conversion keeps its file, so the scene import that
      // depends on it stays cached.
      if (!output.existsSync() || !_same(output.readAsBytesSync(), glb)) {
        await output.parent.create(recursive: true);
        await output.writeAsBytes(glb);
      }
      buildOutput.dependencies.add(source.uri);
      generated.add('$sceneId.glb');
    }
  }

  // Conversions of DNA files that are gone would otherwise stay registered.
  // Only this discovery root's share of the output tree is pruned, so calls
  // for other roots keep theirs.
  final root = discoveryRoot.endsWith('/') ? discoveryRoot : '$discoveryRoot/';
  final owned = Directory.fromUri(packageRoot.resolve(Uri(path: '$dnaSceneRoot/$root').path));
  if (owned.existsSync()) {
    final keep = {for (final path in generated) File.fromUri(packageRoot.resolve(Uri(path: path).path)).path};
    for (final file in owned.listSync(recursive: true, followLinks: false).whereType<File>()) {
      if (file.path.endsWith('.glb') && !keep.contains(file.path)) file.deleteSync();
    }
  }
  buildScenes(buildInput: buildInput, buildOutput: buildOutput, inputFilePaths: generated);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
