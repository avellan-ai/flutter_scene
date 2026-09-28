/// The flutter_scene scene id of a `.dna` asset converted by
/// buildDnaScenes: pass it to `loadScene`.
String dnaSceneId(String dnaPath) {
  if (!dnaPath.endsWith('.dna')) throw ArgumentError.value(dnaPath, 'dnaPath', 'must end with .dna');
  return '.dart_tool/flutter_scene_riglogic/${dnaPath.substring(0, dnaPath.length - 4)}';
}
