// Build hook for flutter_scene_riglogic.
//
// Builds the OpenRigLogic C ABI (native/) with CMake for the target and
// registers it as a bundled code asset, loaded at runtime through the
// @Native bindings in lib/src/backend_io.dart. Web builds use the
// WebAssembly module instead (see lib/src/backend_web.dart) and need no
// code asset.
//
// Requirements for a source build: CMake 3.15+ and a C++14 compiler for the
// target. Android targets also need ANDROID_NDK_HOME (or ANDROID_NDK_ROOT);
// iOS and macOS targets need Xcode. Prebuilt binaries, as
// flutter_scene_rapier ships them, are future work.

import 'package:code_assets/code_assets.dart';
import 'package:flutter_scene_riglogic/src/native_build.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final file = await buildNativeLibrary(
      packageRoot: input.packageRoot,
      buildDir: input.outputDirectoryShared.resolve('cmake/${code.targetOS.name}-${code.targetArchitecture.name}/'),
      os: code.targetOS,
      architecture: code.targetArchitecture,
      code: code,
    );
    output.assets.code.add(
      CodeAsset(package: input.packageName, name: nativeLibraryName, linkMode: DynamicLoadingBundled(), file: file),
    );
    output.dependencies.addAll(nativeSourceDependencies(input.packageRoot));
  });
}
