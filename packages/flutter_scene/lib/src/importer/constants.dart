/// Bytes per vertex in the unskinned vertex layout: position (`vec3`),
/// normal (`vec3`), two tex coords (`vec2` each), color (`vec4`), and tangent
/// (`vec4`), 18 floats.
///
/// Match this layout exactly when emitting unskinned vertex buffers.
const int kUnskinnedPerVertexSize = 72;

/// Bytes per vertex in the skinned vertex layout: the unskinned 18
/// floats plus 4 joint indices and 4 joint weights, 26 floats.
///
/// Match this layout exactly when emitting skinned vertex buffers.
const int kSkinnedPerVertexSize = 104;

/// Bytes per vertex in the wide skinned layout for meshes with more than four
/// joint influences: the skinned 26 floats plus two more sets of 4 joint
/// indices and 4 weights (`joints_1`, `weights_1`, `joints_2`, `weights_2`),
/// 42 floats.
///
/// Match this layout exactly when emitting 12-influence vertex buffers.
const int kSkinned12PerVertexSize = 168;

/// The most joint influences per vertex a skinned mesh carries.
///
/// The importer keeps a vertex's twelve largest weights when a glTF authors
/// more.
const int kMaxSkinInfluences = 12;
