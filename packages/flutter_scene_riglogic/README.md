# flutter_scene_riglogic

MetaHuman-compatible facial rigs for [flutter_scene](https://fscene.dev). It loads a `.dna` rig and evaluates it every frame with Epic Games' [OpenRigLogic](https://github.com/EpicGames/OpenRigLogic) (RigLogic and DNA, MIT): the same runtime rig evaluation Unreal Engine uses for MetaHumans.

It runs natively through `dart:ffi` (a library the build hook compiles from source) and on the web as a standalone WebAssembly module with the same C ABI.

> Status: rig evaluation, DNA import (skinned meshes and skeleton) and joint-driven heads work. Morph targets and wrinkle maps are exposed as weights but not yet applied, and flutter_scene skins with four influences per vertex (the converter writes up to twelve, heaviest first).

## A DNA head in a scene

In the app's `hook/build.dart`, next to flutter_scene's `buildScenes`:

```dart
import 'package:flutter_scene_riglogic/build_hooks.dart';

await buildDnaScenes(buildInput: input, buildOutput: output, lods: [1, 3]);
```

Every `.dna` under `assets/` becomes a skinned scene (the skeleton in its neutral pose and the meshes of the chosen LODs). List the `.dna` itself as an asset too, then:

```dart
final head = await RigLogicHead.load('assets/rigs/character.dna');
head.lod = 1;
scene.add(head.node);
head.node.addComponent(RigLogicComponent(head, beforeUpdate: (dt) {
  head.rig.rawControls[jawOpen] = 0.6; // write controls every frame
}));
```

`RigLogicHead` composes RigLogic's joint deltas onto the neutral pose every frame (translation plus delta, rotation neutral times delta, scale plus delta), converted to the engine's axes. The build hook compiles the package's native library for the host with CMake to read the DNA.

## Use

```dart
import 'package:flutter_scene_riglogic/flutter_scene_riglogic.dart';

await RigLogicRig.ensureInitialized(); // loads the wasm module on the web
final rig = RigLogicRig.fromDna(dnaBytes);

rig.rawControls[rig.rawControlNames.indexOf('CTRL_expressions.jawOpen')] = 0.6;
rig.lod = 1;
rig.calculate();

rig.jointOutputs;       // per joint: translation xyz, quaternion xyzw, scale xyz (deltas from neutral)
rig.blendShapeOutputs;  // blend shape channel weights
rig.animatedMapOutputs; // wrinkle map weights
```

Joint outputs are deltas from `neutralJointValues`, in the DNA's units (`translationUnit`). Normalize rotations before use: the vector kernels do not always return unit quaternions.

### Speed (September 2026, a MetaHuman-sized synthetic rig: 870 joints, 269 raw controls, 545 correctives, about 1.15 M matrix values)

Per frame, including writing every control and copying every output, on an Intel Core Ultra 7 desktop:

| | LOD0 | LOD1 | LOD3 |
|---|---|---|---|
| Native, vector kernel | 106 µs | 67 µs | 29 µs |
| Native, scalar | | 147 µs | 74 µs |
| Web, dart2js | 229 µs | 156 µs | 80 µs |
| Web, dart2wasm | 236 µs | 163 µs | 85 µs |

`dart run tool/bench.dart <rig.dna>` repeats the native measurement.

## Building

- **Native:** the build hook runs CMake 3.15+ with a C++14 compiler for the target. Android also needs `ANDROID_NDK_HOME`; iOS and macOS need Xcode. Prebuilt binaries are future work.
- **Web:** build the module with Emscripten and serve it next to the app (or set `--dart-define=FLUTTER_SCENE_RIGLOGIC_WASM_URL=<url>`):

  ```sh
  emcmake cmake -S native -B build-wasm -DCMAKE_BUILD_TYPE=Release
  cmake --build build-wasm
  # serve build-wasm/flutter_scene_riglogic_native.wasm
  ```

- **Test rigs:** `native/tools/make_dna.cpp` writes synthetic rigs (`cmake --build <dir> --target make_dna`, then `make_dna fixture out.dna` or `make_dna metahuman-scale out.dna`).

## MetaHuman licensing

This package contains no MetaHuman characters. Characters you load are governed by their own terms: MetaHumans made with MetaHuman Creator fall under the Unreal Engine EULA and the [MetaHuman license](https://www.metahuman.com/license) (use in any engine, a seat license above the revenue threshold when rendered outside Unreal, and no use of MetaHuman characters or curves to train or test AI). Content from Fab follows its Fab license.
