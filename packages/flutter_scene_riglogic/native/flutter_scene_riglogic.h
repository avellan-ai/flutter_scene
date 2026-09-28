// C ABI over OpenRigLogic (RigLogic and the DNA reader) for flutter_scene.
//
// The same functions are exported by the native dynamic library (dart:ffi)
// and by the WebAssembly module (where pointers are offsets into linear
// memory). Every function is plain C types only.
//
// A rig owns one parsed DNA (without geometry), one RigLogic and one
// RigInstance. Controls are written through the float views returned by
// fsrl_gui_controls / fsrl_raw_controls; outputs are read through the views
// returned after fsrl_calculate. Views stay valid for the rig's lifetime.

#ifndef FLUTTER_SCENE_RIGLOGIC_H_
#define FLUTTER_SCENE_RIGLOGIC_H_

#include <stdint.h>

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#define FSRL_API EMSCRIPTEN_KEEPALIVE
#elif defined(_WIN32)
#define FSRL_API __declspec(dllexport)
#else
#define FSRL_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FsrlRig FsrlRig;

// Counts and name tables, selected by kind.
enum FsrlKind {
  FSRL_GUI_CONTROLS = 0,
  FSRL_RAW_CONTROLS = 1,
  FSRL_PSD_CONTROLS = 2,
  FSRL_ML_CONTROLS = 3,
  FSRL_RBF_CONTROLS = 4,
  FSRL_JOINTS = 5,
  FSRL_BLEND_SHAPE_CHANNELS = 6,
  FSRL_ANIMATED_MAPS = 7,
  FSRL_LODS = 8,
  FSRL_JOINT_OUTPUTS = 9,        // floats in the joint output view
  FSRL_BLEND_SHAPE_OUTPUTS = 10,  // floats in the blend shape output view
  FSRL_ANIMATED_MAP_OUTPUTS = 11, // floats in the animated map output view
  FSRL_NEUTRAL_JOINT_VALUES = 12, // floats in the neutral joint value view
  FSRL_JOINT_ATTRIBUTES = 13,     // floats per joint in outputs (10: t, q, s)
  FSRL_MESHES = 14,
};

// Calculation types, mirroring rl4::CalculationType.
enum FsrlCalculation {
  FSRL_CALC_SCALAR = 0,
  FSRL_CALC_SSE = 1,
  FSRL_CALC_AVX = 2,
  FSRL_CALC_NEON = 3,
  FSRL_CALC_ANY_VECTOR = 4,
};

FSRL_API void* fsrl_alloc(uint32_t size);
FSRL_API void fsrl_free(void* pointer);

// Parses DNA bytes and builds the rig. Returns null on failure and writes the
// reason, null-terminated, into `error` (at most `errorCapacity` bytes; either
// may be null/0). The bytes are copied.
FSRL_API FsrlRig* fsrl_rig_create(const uint8_t* dna, uint32_t length, int32_t calculation, char* error,
                                  uint32_t errorCapacity);
FSRL_API void fsrl_rig_destroy(FsrlRig* rig);

FSRL_API uint32_t fsrl_count(const FsrlRig* rig, int32_t kind);
// Names for GUI controls, raw controls, joints, blend shape channels and
// animated maps. Returns null for an out-of-range index or other kinds.
FSRL_API const char* fsrl_name(const FsrlRig* rig, int32_t kind, uint32_t index);
// Parent joint index, or -1 for a root.
FSRL_API int32_t fsrl_joint_parent(const FsrlRig* rig, uint32_t joint);
// Rotation of the rig's joint outputs: 0 Euler angles, 1 quaternions.
FSRL_API int32_t fsrl_rotation_type(const FsrlRig* rig);
// DNA units: 0 cm / 1 m, and 0 degrees / 1 radians.
FSRL_API int32_t fsrl_translation_unit(const FsrlRig* rig);
FSRL_API int32_t fsrl_rotation_unit(const FsrlRig* rig);

FSRL_API float* fsrl_gui_controls(FsrlRig* rig);
FSRL_API float* fsrl_raw_controls(FsrlRig* rig);
FSRL_API void fsrl_map_gui_to_raw(FsrlRig* rig);

// LODs outside [0, lod count) are ignored.
FSRL_API void fsrl_set_lod(FsrlRig* rig, uint32_t lod);
FSRL_API uint32_t fsrl_get_lod(const FsrlRig* rig);

FSRL_API void fsrl_calculate(FsrlRig* rig);

FSRL_API const float* fsrl_joint_outputs(const FsrlRig* rig);
FSRL_API const float* fsrl_blend_shape_outputs(const FsrlRig* rig);
FSRL_API const float* fsrl_animated_map_outputs(const FsrlRig* rig);
FSRL_API const float* fsrl_neutral_joint_values(const FsrlRig* rig);
// Joint output attribute indices that vary at a LOD (into the joint output
// view); the count is written to *count. Returns null with a count of 0 for
// a LOD out of range.
FSRL_API const uint16_t* fsrl_joint_attribute_indices(const FsrlRig* rig, uint32_t lod, uint32_t* count);
// Mesh indices a LOD draws (names via fsrl_name with FSRL_MESHES); returns
// the count, writing at most `capacity`.
FSRL_API uint32_t fsrl_lod_meshes(const FsrlRig* rig, uint32_t lod, uint16_t* out, uint32_t capacity);

// ---------------------------------------------------------------------------
// DNA geometry, for converters (build time) and tools. A FsrlDna holds every
// layer, geometry included. Arrays are copied into caller-provided buffers.

typedef struct FsrlDna FsrlDna;

enum FsrlDnaKind {
  FSRL_DNA_LODS = 0,
  FSRL_DNA_MESHES = 1,
  FSRL_DNA_JOINTS = 2,
};

enum FsrlMeshKind {
  FSRL_MESH_POSITIONS = 0,
  FSRL_MESH_TEXTURE_COORDINATES = 1,
  FSRL_MESH_NORMALS = 2,
  FSRL_MESH_LAYOUTS = 3,
  FSRL_MESH_FACES = 4,
  FSRL_MESH_MAX_INFLUENCES = 5,
  FSRL_MESH_BLEND_SHAPE_TARGETS = 6,
};

// Returns null on failure, writing the reason like fsrl_rig_create.
FSRL_API FsrlDna* fsrl_dna_open(const uint8_t* dna, uint32_t length, char* error, uint32_t errorCapacity);
FSRL_API void fsrl_dna_close(FsrlDna* dna);
FSRL_API uint32_t fsrl_dna_count(const FsrlDna* dna, int32_t kind);
FSRL_API const char* fsrl_dna_joint_name(const FsrlDna* dna, uint32_t joint);
FSRL_API int32_t fsrl_dna_joint_parent(const FsrlDna* dna, uint32_t joint);
// Writes the coordinate system (three tdm::axis_dir values: left 0, right 1,
// up 2, down 3, front 4, back 5), then translation unit, rotation unit and
// rotation sequence: six int32s.
FSRL_API void fsrl_dna_conventions(const FsrlDna* dna, int32_t* out6);
// Neutral joint translations and Euler rotations, six floats per joint, in DNA units.
FSRL_API void fsrl_dna_neutral_joints(const FsrlDna* dna, float* out);
FSRL_API uint32_t fsrl_dna_lod_meshes(const FsrlDna* dna, uint32_t lod, uint16_t* out, uint32_t capacity);
FSRL_API uint32_t fsrl_dna_lod_joints(const FsrlDna* dna, uint32_t lod, uint16_t* out, uint32_t capacity);
FSRL_API const char* fsrl_dna_mesh_name(const FsrlDna* dna, uint32_t mesh);
FSRL_API uint32_t fsrl_dna_mesh_count(const FsrlDna* dna, uint32_t mesh, int32_t kind);
// Positions, normals (xyz) and texture coordinates (uv), interleaved.
FSRL_API void fsrl_dna_mesh_positions(const FsrlDna* dna, uint32_t mesh, float* out);
FSRL_API void fsrl_dna_mesh_normals(const FsrlDna* dna, uint32_t mesh, float* out);
FSRL_API void fsrl_dna_mesh_texture_coordinates(const FsrlDna* dna, uint32_t mesh, float* out);
// Vertex layouts: position, texture coordinate and normal index per layout.
FSRL_API void fsrl_dna_mesh_layouts(const FsrlDna* dna, uint32_t mesh, uint32_t* out3);
// Layout indices of one face (a polygon); returns the corner count, writing
// at most `capacity` of them.
FSRL_API uint32_t fsrl_dna_mesh_face(const FsrlDna* dna, uint32_t mesh, uint32_t face, uint32_t* out, uint32_t capacity);
// Skin weights of one vertex (a position index); returns the influence count.
FSRL_API uint32_t fsrl_dna_mesh_skin(const FsrlDna* dna, uint32_t mesh, uint32_t vertex, float* weights, uint16_t* joints,
                                     uint32_t capacity);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_SCENE_RIGLOGIC_H_
