// Skinned vertex shader for meshes with more than four joint influences per
// vertex (up to 12, the 168-byte layout). The shared skinned body with the two
// extra joint/weight sets switched on; 4-influence meshes keep SkinnedVertex.
#define FLUTTER_SCENE_SKIN_12_INFLUENCES
#include <material_vertex.glsl>
#include <flutter_scene_skinned_body.glsl>
