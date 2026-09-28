// Builds the OpenRigLogic C ABI (native/) with CMake. Shared by the package's
// build hook (the target platform) and buildDnaScenes (the host, which
// converts .dna files at build time).

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:code_assets/code_assets.dart';

const nativeLibraryName = 'flutter_scene_riglogic_native';

/// Configures and builds the library for [os]/[architecture] in [buildDir]
/// and returns the library file. [code] supplies Android/iOS/macOS SDK
/// details when building for a target; it is null for host builds.
Future<Uri> buildNativeLibrary({
  required Uri packageRoot,
  required Uri buildDir,
  required OS os,
  required Architecture architecture,
  CodeConfig? code,
}) async {
  await Directory.fromUri(buildDir).create(recursive: true);
  await _run('cmake', [
    '-S', packageRoot.resolve('native/').toFilePath(),
    '-B', buildDir.toFilePath(),
    '-DCMAKE_BUILD_TYPE=Release',
    ..._targetArgs(os, architecture, code),
  ]);
  await _run('cmake', ['--build', buildDir.toFilePath(), '--target', nativeLibraryName, '--config', 'Release', '--parallel']);
  final file = buildDir.resolve(os.dylibFileName(nativeLibraryName));
  if (!File.fromUri(file).existsSync()) {
    throw StateError('CMake did not produce ${file.toFilePath()}');
  }
  return file;
}

/// Every file the native build reads: the shim and the vendored OpenRigLogic
/// sources, so a submodule update or an edit reruns the build.
List<Uri> nativeSourceDependencies(Uri packageRoot) {
  final files = <Uri>[];
  for (final dir in ['native/', 'third_party/OpenRigLogic/']) {
    final root = Directory.fromUri(packageRoot.resolve(dir));
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (path.contains('${Platform.pathSeparator}.git') || path.contains('/tests/') || path.contains('/benchmarks/')) continue;
      if (path.endsWith('.cpp') || path.endsWith('.h') || path.endsWith('.txt') || path.endsWith('.cmake') || path.endsWith('.in')) {
        files.add(entity.uri);
      }
    }
  }
  return files;
}

OS get hostOS => switch (Platform.operatingSystem) {
  'linux' => OS.linux,
  'macos' => OS.macOS,
  'windows' => OS.windows,
  final other => throw UnsupportedError('No host build for $other'),
};

Architecture get hostArchitecture => switch (Abi.current()) {
  Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => Architecture.x64,
  Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => Architecture.arm64,
  final other => throw UnsupportedError('No host build for $other'),
};

List<String> _targetArgs(OS os, Architecture architecture, CodeConfig? code) {
  switch (os) {
    case OS.android:
      final ndk = Platform.environment['ANDROID_NDK_HOME'] ?? Platform.environment['ANDROID_NDK_ROOT'];
      if (ndk == null) {
        throw StateError('Building flutter_scene_riglogic for Android needs ANDROID_NDK_HOME.');
      }
      final abi = switch (architecture) {
        Architecture.arm64 => 'arm64-v8a',
        Architecture.arm => 'armeabi-v7a',
        Architecture.x64 => 'x86_64',
        Architecture.ia32 => 'x86',
        _ => throw UnsupportedError('Android $architecture'),
      };
      return [
        '-DCMAKE_TOOLCHAIN_FILE=$ndk/build/cmake/android.toolchain.cmake',
        '-DANDROID_ABI=$abi',
        '-DANDROID_PLATFORM=android-${code!.android.targetNdkApi}',
      ];
    case OS.iOS:
      final simulator = code!.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      return [
        '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_OSX_SYSROOT=${simulator ? 'iphonesimulator' : 'iphoneos'}',
        '-DCMAKE_OSX_ARCHITECTURES=${architecture == Architecture.arm64 ? 'arm64' : 'x86_64'}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.iOS.targetVersion}',
        if (architecture == Architecture.x64) '-DRL_BUILD_WITH_SSE=ON',
      ];
    case OS.macOS:
      return [
        '-DCMAKE_OSX_ARCHITECTURES=${architecture == Architecture.arm64 ? 'arm64' : 'x86_64'}',
        if (code != null) '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}',
        if (architecture == Architecture.x64) '-DRL_BUILD_WITH_SSE=ON',
      ];
    case OS.linux:
    case OS.windows:
      if (architecture != hostArchitecture) {
        throw UnsupportedError(
          'flutter_scene_riglogic builds $os libraries for the host architecture ($hostArchitecture) only; '
          '$architecture needs a cross toolchain, which the hook does not configure yet.',
        );
      }
      return [if (architecture == Architecture.x64) '-DRL_BUILD_WITH_SSE=ON'];
    default:
      throw UnsupportedError('flutter_scene_riglogic has no source build for $os yet.');
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(executable, arguments, '${result.stdout}\n${result.stderr}', result.exitCode);
  }
}
