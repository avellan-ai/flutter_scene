/// Rig evaluation only, with no Flutter dependency: DNA files evaluated by
/// Epic's OpenRigLogic (MIT) natively and on the web. Plain Dart programs
/// (benchmarks, tools, tests) import this; Flutter apps import
/// `flutter_scene_riglogic.dart`, which adds the scene integration.
library;

export 'src/rig.dart' show RigLogicCalculation, RigLogicLengthUnit, RigLogicRig;
