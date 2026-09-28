// The build system hashes a directory dependency as the names of its direct
// children, so the discovery root alone misses a source added to a
// subdirectory that already existed at the last build. These check that some
// declared directory changes its listing when that happens.

import 'dart:io';

import 'package:flutter_scene/src/fmat/build_materials.dart';
import 'package:flutter_scene/src/importer/build_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('hook_discovery');
    File.fromUri(temp.uri.resolve('pubspec.yaml')).writeAsStringSync(
      'name: example_app\n'
      'environment:\n'
      "  sdk: '>=3.0.0 <5.0.0'\n",
    );
    Directory.fromUri(
      temp.uri.resolve('assets/characters/npc/'),
    ).createSync(recursive: true);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('buildScenes declares every directory below the discovery root', () {
    final outputBuilder = BuildOutputBuilder();
    buildScenes(buildInput: _buildInput(temp.uri), buildOutput: outputBuilder);

    expect(
      outputBuilder.build().dependencies,
      containsAll([
        temp.uri.resolve('assets/'),
        temp.uri.resolve('assets/characters/'),
        temp.uri.resolve('assets/characters/npc/'),
      ]),
    );
  });

  for (final path in [
    'assets/characters/new.glb',
    'assets/characters/npc/new.fscene',
    'assets/characters/new.fsceneb',
  ]) {
    test(
      'buildScenes reruns when $path appears in an existing subdirectory',
      () {
        final outputBuilder = BuildOutputBuilder();
        buildScenes(
          buildInput: _buildInput(temp.uri),
          buildOutput: outputBuilder,
        );
        final dependencies = outputBuilder.build().dependencies;
        final before = _directoryHashes(dependencies);

        File.fromUri(temp.uri.resolve(path)).createSync();

        expect(_directoryHashes(dependencies), isNot(equals(before)));
      },
    );
  }

  test(
    'buildMaterials reruns when a material appears in a subdirectory',
    () async {
      final outputBuilder = BuildOutputBuilder();
      await buildMaterials(
        buildInput: _buildInput(temp.uri),
        buildOutput: outputBuilder,
      );
      final dependencies = outputBuilder.build().dependencies;
      expect(
        dependencies,
        contains(temp.uri.resolve('assets/characters/npc/')),
      );
      final before = _directoryHashes(dependencies);

      File.fromUri(
        temp.uri.resolve('assets/characters/npc/skin.fmat'),
      ).createSync();

      expect(_directoryHashes(dependencies), isNot(equals(before)));
    },
  );

  test('discovery finds sources at any depth and sorts them', () {
    for (final path in [
      'assets/b.glb',
      'assets/characters/npc/a.fscene',
      'assets/characters/skip.png',
    ]) {
      File.fromUri(temp.uri.resolve(path)).createSync();
    }

    final discovered = discoverSources(
      temp.uri,
      discoveryRoot: 'assets',
      extensions: const ['.glb', '.fscene'],
    );
    expect(discovered.sources, [
      'assets/b.glb',
      'assets/characters/npc/a.fscene',
    ]);
    expect(discovered.directories, [
      temp.uri.resolve('assets/'),
      temp.uri.resolve('assets/characters/'),
      temp.uri.resolve('assets/characters/npc/'),
    ]);
  });

  test('a missing discovery root declares its nearest existing parent', () {
    final discovered = discoverSources(
      temp.uri,
      discoveryRoot: 'scenes/',
      extensions: const ['.glb'],
    );
    expect(discovered.sources, isEmpty);
    expect(discovered.directories, [temp.uri]);
  });
}

/// What the build system compares for each declared directory: the sorted
/// names of its direct children.
Map<Uri, String> _directoryHashes(Iterable<Uri> dependencies) => {
  for (final dependency in dependencies)
    if (dependency.path.endsWith('/'))
      dependency:
          (Directory.fromUri(dependency)
                  .listSync(followLinks: true)
                  .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
                  .toList()
                ..sort())
              .join(';'),
};

BuildInput _buildInput(Uri packageRoot) {
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: packageRoot,
      packageName: 'example_app',
      outputDirectoryShared: packageRoot.resolve('.dart_tool/hook/'),
      outputFile: packageRoot.resolve('.dart_tool/hook/output.json'),
    )
    ..setupBuildInput();
  builder.config.setupBuild(linkingEnabled: false);
  return builder.build();
}
