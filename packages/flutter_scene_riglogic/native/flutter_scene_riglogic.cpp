#include "flutter_scene_riglogic.h"

#include <riglogic/RigLogic.h>

#include <algorithm>
#include <cstdlib>
#include <initializer_list>
#include <cstring>
#include <string>
#include <vector>

namespace {

void setError(char* error, uint32_t capacity, const char* message) {
    if (error == nullptr || capacity == 0) return;
    const std::size_t n = std::min<std::size_t>(std::strlen(message), capacity - 1);
    std::memcpy(error, message, n);
    error[n] = '\0';
}

// OpenRigLogic sizes the joint output buffer as a uint16 count of floats
// (RigMetadata), so larger rigs would overflow it.
constexpr std::uint32_t kMaxJointOutputs = 65535u;

// Everything the runtime needs except geometry.
const dna::DataLayer kRuntimeLayers = dna::DataLayer::Behavior | dna::DataLayer::RBFBehavior |
                                      dna::DataLayer::MachineLearnedBehavior |
                                      dna::DataLayer::TwistSwingBehavior | dna::DataLayer::JointBehaviorMetadata;

template<typename Get>
std::vector<std::string> names(std::uint16_t count, Get get) {
    std::vector<std::string> out;
    out.reserve(count);
    for (std::uint16_t i = 0; i < count; ++i) {
        const auto view = get(i);
        out.emplace_back(view.data(), view.size());
    }
    return out;
}

template<typename T>
uint32_t copyOut(rl4::ConstArrayView<T> view, T* out, uint32_t capacity) {
    const auto n = static_cast<uint32_t>(view.size());
    if (out != nullptr) std::memcpy(out, view.data(), sizeof(T) * std::min(n, capacity));
    return n;
}

void interleave(float* out, std::initializer_list<rl4::ConstArrayView<float>> columns) {
    const std::size_t stride = columns.size();
    std::size_t c = 0;
    for (const auto& column : columns) {
        for (std::size_t i = 0; i < column.size(); ++i) out[i * stride + c] = column[i];
        ++c;
    }
}

}  // namespace

struct FsrlDna {
    rl4::MemoryStream* stream = nullptr;
    dna::BinaryStreamReader* reader = nullptr;

    ~FsrlDna() {
        if (reader != nullptr) dna::BinaryStreamReader::destroy(reader);
        if (stream != nullptr) rl4::MemoryStream::destroy(stream);
    }
};

struct FsrlRig {
    rl4::RigLogic* rigLogic = nullptr;
    rl4::RigInstance* instance = nullptr;
    std::vector<std::string> guiNames, rawNames, jointNames, blendShapeNames, animatedMapNames, meshNames;
    std::vector<std::vector<std::uint16_t>> lodMeshes;
    std::vector<std::int32_t> jointParents;
    std::int32_t translationUnit = 0;
    std::int32_t axes[3] = {0, 2, 4};
    std::int32_t rotationUnit = 0;

    ~FsrlRig() {
        if (instance != nullptr) rl4::RigInstance::destroy(instance);
        if (rigLogic != nullptr) rl4::RigLogic::destroy(rigLogic);
    }
};

extern "C" {

void* fsrl_alloc(uint32_t size) {
    return std::malloc(size);
}

void fsrl_free(void* pointer) {
    std::free(pointer);
}

FsrlRig* fsrl_rig_create(const uint8_t* dnaBytes, uint32_t length, int32_t calculation, char* error,
                         uint32_t errorCapacity) {
    auto stream = rl4::makeScoped<rl4::MemoryStream>(length);
    stream->open();
    stream->write(reinterpret_cast<const char*>(dnaBytes), length);
    stream->seek(0);
    auto reader = rl4::makeScoped<rl4::BinaryStreamReader>(stream.get(), kRuntimeLayers);
    reader->read();
    if (!rl4::Status::isOk()) {
        setError(error, errorCapacity, rl4::Status::get().message);
        return nullptr;
    }
    if (static_cast<std::uint32_t>(reader->getJointCount()) * 10u > kMaxJointOutputs) {
        setError(error, errorCapacity, "rig has more joints than OpenRigLogic's joint output buffer can hold (6553)");
        return nullptr;
    }
    if (calculation < FSRL_CALC_SCALAR || calculation > FSRL_CALC_ANY_VECTOR) {
        setError(error, errorCapacity, "unknown calculation type");
        return nullptr;
    }

    rl4::Configuration config;
    config.calculationType = static_cast<rl4::CalculationType>(calculation);
    // Half floats need F16C or ARM FP16 and are unavailable on the web.
    config.floatingPointType = rl4::FloatingPointType::Float;
    // flutter_scene nodes rotate by quaternion.
    config.rotationType = rl4::RotationType::Quaternions;

    auto* rig = new FsrlRig();
    rig->rigLogic = rl4::RigLogic::create(reader.get(), config);
    if (rig->rigLogic == nullptr || !rl4::Status::isOk()) {
        setError(error, errorCapacity, rl4::Status::isOk() ? "RigLogic::create failed" : rl4::Status::get().message);
        delete rig;
        return nullptr;
    }
    rig->instance = rl4::RigInstance::create(rig->rigLogic);

    const dna::Reader* r = reader.get();
    rig->guiNames = names(r->getGUIControlCount(), [r](std::uint16_t i) { return r->getGUIControlName(i); });
    rig->rawNames = names(r->getRawControlCount(), [r](std::uint16_t i) { return r->getRawControlName(i); });
    rig->jointNames = names(r->getJointCount(), [r](std::uint16_t i) { return r->getJointName(i); });
    rig->blendShapeNames =
        names(r->getBlendShapeChannelCount(), [r](std::uint16_t i) { return r->getBlendShapeChannelName(i); });
    rig->animatedMapNames = names(r->getAnimatedMapCount(), [r](std::uint16_t i) { return r->getAnimatedMapName(i); });
    rig->meshNames = names(r->getMeshCount(), [r](std::uint16_t i) { return r->getMeshName(i); });
    for (std::uint16_t lod = 0; lod < r->getLODCount(); ++lod) {
        const auto meshes = r->getMeshIndicesForLOD(lod);
        rig->lodMeshes.emplace_back(meshes.begin(), meshes.end());
    }
    for (std::uint16_t i = 0; i < r->getJointCount(); ++i) {
        const auto parent = r->getJointParentIndex(i);
        // DNA marks a root with an out-of-range parent (0xFFFF) or with itself.
        const bool root = parent == i || parent >= r->getJointCount();
        rig->jointParents.push_back(root ? -1 : static_cast<std::int32_t>(parent));
    }
    rig->translationUnit = static_cast<std::int32_t>(r->getTranslationUnit());
    const auto system = r->getCoordinateSystem();
    rig->axes[0] = static_cast<std::int32_t>(system.x);
    rig->axes[1] = static_cast<std::int32_t>(system.y);
    rig->axes[2] = static_cast<std::int32_t>(system.z);
    rig->rotationUnit = static_cast<std::int32_t>(r->getRotationUnit());
    return rig;
}

void fsrl_rig_destroy(FsrlRig* rig) {
    delete rig;
}

uint32_t fsrl_count(const FsrlRig* rig, int32_t kind) {
    switch (kind) {
        case FSRL_GUI_CONTROLS: return rig->instance->getGUIControlCount();
        case FSRL_RAW_CONTROLS: return rig->instance->getRawControlCount();
        case FSRL_PSD_CONTROLS: return rig->instance->getPSDControlCount();
        case FSRL_ML_CONTROLS: return rig->instance->getMLControlCount();
        case FSRL_RBF_CONTROLS: return rig->instance->getRBFControlCount();
        case FSRL_JOINTS: return static_cast<uint32_t>(rig->jointNames.size());
        case FSRL_BLEND_SHAPE_CHANNELS: return static_cast<uint32_t>(rig->blendShapeNames.size());
        case FSRL_ANIMATED_MAPS: return static_cast<uint32_t>(rig->animatedMapNames.size());
        case FSRL_LODS: return rig->rigLogic->getLODCount();
        case FSRL_JOINT_OUTPUTS: return static_cast<uint32_t>(rig->instance->getJointOutputs().size());
        case FSRL_BLEND_SHAPE_OUTPUTS: return static_cast<uint32_t>(rig->instance->getBlendShapeOutputs().size());
        case FSRL_ANIMATED_MAP_OUTPUTS: return static_cast<uint32_t>(rig->instance->getAnimatedMapOutputs().size());
        case FSRL_NEUTRAL_JOINT_VALUES: return static_cast<uint32_t>(rig->rigLogic->getNeutralJointValues().size());
        case FSRL_JOINT_ATTRIBUTES: return 10u;
        case FSRL_MESHES: return static_cast<uint32_t>(rig->meshNames.size());
        default: return 0u;
    }
}

uint32_t fsrl_lod_meshes(const FsrlRig* rig, uint32_t lod, uint16_t* out, uint32_t capacity) {
    if (lod >= rig->lodMeshes.size()) return 0u;
    const auto& meshes = rig->lodMeshes[lod];
    const auto n = static_cast<uint32_t>(meshes.size());
    if (out != nullptr) std::memcpy(out, meshes.data(), sizeof(std::uint16_t) * std::min(n, capacity));
    return n;
}

const char* fsrl_name(const FsrlRig* rig, int32_t kind, uint32_t index) {
    const std::vector<std::string>* table = nullptr;
    switch (kind) {
        case FSRL_GUI_CONTROLS: table = &rig->guiNames; break;
        case FSRL_RAW_CONTROLS: table = &rig->rawNames; break;
        case FSRL_JOINTS: table = &rig->jointNames; break;
        case FSRL_BLEND_SHAPE_CHANNELS: table = &rig->blendShapeNames; break;
        case FSRL_ANIMATED_MAPS: table = &rig->animatedMapNames; break;
        case FSRL_MESHES: table = &rig->meshNames; break;
        default: return nullptr;
    }
    return index < table->size() ? (*table)[index].c_str() : nullptr;
}

int32_t fsrl_joint_parent(const FsrlRig* rig, uint32_t joint) {
    return joint < rig->jointParents.size() ? rig->jointParents[joint] : -1;
}

int32_t fsrl_rotation_type(const FsrlRig*) {
    return 1;
}

void fsrl_axes(const FsrlRig* rig, int32_t* out3) {
    std::memcpy(out3, rig->axes, sizeof(rig->axes));
}

int32_t fsrl_translation_unit(const FsrlRig* rig) {
    return rig->translationUnit;
}

int32_t fsrl_rotation_unit(const FsrlRig* rig) {
    return rig->rotationUnit;
}

float* fsrl_gui_controls(FsrlRig* rig) {
    return rig->instance->getGUIControlValues().data();
}

float* fsrl_raw_controls(FsrlRig* rig) {
    return rig->instance->getRawControlValues().data();
}

void fsrl_map_gui_to_raw(FsrlRig* rig) {
    rig->rigLogic->mapGUIToRawControls(rig->instance);
}

void fsrl_set_lod(FsrlRig* rig, uint32_t lod) {
    if (lod >= rig->rigLogic->getLODCount()) return;
    rig->instance->setLOD(static_cast<std::uint16_t>(lod));
}

uint32_t fsrl_get_lod(const FsrlRig* rig) {
    return rig->instance->getLOD();
}

void fsrl_calculate(FsrlRig* rig) {
    rig->rigLogic->calculate(rig->instance);
}

const float* fsrl_joint_outputs(const FsrlRig* rig) {
    return rig->instance->getJointOutputs().data();
}

const float* fsrl_blend_shape_outputs(const FsrlRig* rig) {
    return rig->instance->getBlendShapeOutputs().data();
}

const float* fsrl_animated_map_outputs(const FsrlRig* rig) {
    return rig->instance->getAnimatedMapOutputs().data();
}

const float* fsrl_neutral_joint_values(const FsrlRig* rig) {
    return rig->rigLogic->getNeutralJointValues().data();
}

const uint16_t* fsrl_joint_attribute_indices(const FsrlRig* rig, uint32_t lod, uint32_t* count) {
    if (lod >= rig->rigLogic->getLODCount()) {
        *count = 0;
        return nullptr;
    }
    const auto view = rig->rigLogic->getJointVariableAttributeIndices(static_cast<std::uint16_t>(lod));
    *count = static_cast<uint32_t>(view.size());
    return view.data();
}

FsrlDna* fsrl_dna_open(const uint8_t* bytes, uint32_t length, char* error, uint32_t errorCapacity) {
    auto* dna = new FsrlDna();
    dna->stream = rl4::MemoryStream::create(length);
    dna->stream->open();
    dna->stream->write(reinterpret_cast<const char*>(bytes), length);
    dna->stream->seek(0);
    dna->reader = dna::BinaryStreamReader::create(dna->stream, dna::DataLayer::All);
    dna->reader->read();
    if (!rl4::Status::isOk()) {
        setError(error, errorCapacity, rl4::Status::get().message);
        delete dna;
        return nullptr;
    }
    return dna;
}

void fsrl_dna_close(FsrlDna* dna) {
    delete dna;
}

uint32_t fsrl_dna_count(const FsrlDna* dna, int32_t kind) {
    const dna::Reader* r = dna->reader;
    switch (kind) {
        case FSRL_DNA_LODS: return r->getLODCount();
        case FSRL_DNA_MESHES: return r->getMeshCount();
        case FSRL_DNA_JOINTS: return r->getJointCount();
        default: return 0u;
    }
}

const char* fsrl_dna_joint_name(const FsrlDna* dna, uint32_t joint) {
    // StringView data is stored null-terminated inside the reader.
    return joint < dna->reader->getJointCount() ? dna->reader->getJointName(static_cast<std::uint16_t>(joint)).data() : nullptr;
}

int32_t fsrl_dna_joint_parent(const FsrlDna* dna, uint32_t joint) {
    const dna::Reader* r = dna->reader;
    if (joint >= r->getJointCount()) return -1;
    const auto parent = r->getJointParentIndex(static_cast<std::uint16_t>(joint));
    return (parent == joint || parent >= r->getJointCount()) ? -1 : static_cast<int32_t>(parent);
}

void fsrl_dna_conventions(const FsrlDna* dna, int32_t* out6) {
    const dna::Reader* r = dna->reader;
    const auto system = r->getCoordinateSystem();
    out6[0] = static_cast<int32_t>(system.x);
    out6[1] = static_cast<int32_t>(system.y);
    out6[2] = static_cast<int32_t>(system.z);
    out6[3] = static_cast<int32_t>(r->getTranslationUnit());
    out6[4] = static_cast<int32_t>(r->getRotationUnit());
    out6[5] = static_cast<int32_t>(r->getRotationSequence());
}

void fsrl_dna_neutral_joints(const FsrlDna* dna, float* out) {
    const dna::Reader* r = dna->reader;
    for (std::uint16_t j = 0; j < r->getJointCount(); ++j) {
        const auto t = r->getNeutralJointTranslation(j);
        const auto e = r->getNeutralJointRotation(j);
        float* o = out + 6u * j;
        o[0] = t.x;
        o[1] = t.y;
        o[2] = t.z;
        o[3] = e.x;
        o[4] = e.y;
        o[5] = e.z;
    }
}

uint32_t fsrl_dna_lod_meshes(const FsrlDna* dna, uint32_t lod, uint16_t* out, uint32_t capacity) {
    if (lod >= dna->reader->getLODCount()) return 0u;
    return copyOut(dna->reader->getMeshIndicesForLOD(static_cast<std::uint16_t>(lod)), out, capacity);
}

uint32_t fsrl_dna_lod_joints(const FsrlDna* dna, uint32_t lod, uint16_t* out, uint32_t capacity) {
    if (lod >= dna->reader->getLODCount()) return 0u;
    return copyOut(dna->reader->getJointIndicesForLOD(static_cast<std::uint16_t>(lod)), out, capacity);
}

const char* fsrl_dna_mesh_name(const FsrlDna* dna, uint32_t mesh) {
    return mesh < dna->reader->getMeshCount() ? dna->reader->getMeshName(static_cast<std::uint16_t>(mesh)).data() : nullptr;
}

uint32_t fsrl_dna_mesh_count(const FsrlDna* dna, uint32_t mesh, int32_t kind) {
    const dna::Reader* r = dna->reader;
    if (mesh >= r->getMeshCount()) return 0u;
    const auto m = static_cast<std::uint16_t>(mesh);
    switch (kind) {
        case FSRL_MESH_POSITIONS: return r->getVertexPositionCount(m);
        case FSRL_MESH_TEXTURE_COORDINATES: return r->getVertexTextureCoordinateCount(m);
        case FSRL_MESH_NORMALS: return r->getVertexNormalCount(m);
        case FSRL_MESH_LAYOUTS: return r->getVertexLayoutCount(m);
        case FSRL_MESH_FACES: return r->getFaceCount(m);
        case FSRL_MESH_MAX_INFLUENCES: return r->getMaximumInfluencePerVertex(m);
        case FSRL_MESH_BLEND_SHAPE_TARGETS: return r->getBlendShapeTargetCount(m);
        default: return 0u;
    }
}

void fsrl_dna_mesh_positions(const FsrlDna* dna, uint32_t mesh, float* out) {
    if (mesh >= dna->reader->getMeshCount()) return;
    const auto m = static_cast<std::uint16_t>(mesh);
    const dna::Reader* r = dna->reader;
    interleave(out, {r->getVertexPositionXs(m), r->getVertexPositionYs(m), r->getVertexPositionZs(m)});
}

void fsrl_dna_mesh_normals(const FsrlDna* dna, uint32_t mesh, float* out) {
    if (mesh >= dna->reader->getMeshCount()) return;
    const auto m = static_cast<std::uint16_t>(mesh);
    const dna::Reader* r = dna->reader;
    interleave(out, {r->getVertexNormalXs(m), r->getVertexNormalYs(m), r->getVertexNormalZs(m)});
}

void fsrl_dna_mesh_texture_coordinates(const FsrlDna* dna, uint32_t mesh, float* out) {
    if (mesh >= dna->reader->getMeshCount()) return;
    const auto m = static_cast<std::uint16_t>(mesh);
    const dna::Reader* r = dna->reader;
    interleave(out, {r->getVertexTextureCoordinateUs(m), r->getVertexTextureCoordinateVs(m)});
}

void fsrl_dna_mesh_layouts(const FsrlDna* dna, uint32_t mesh, uint32_t* out3) {
    if (mesh >= dna->reader->getMeshCount()) return;
    const auto m = static_cast<std::uint16_t>(mesh);
    const dna::Reader* r = dna->reader;
    const auto p = r->getVertexLayoutPositionIndices(m);
    const auto t = r->getVertexLayoutTextureCoordinateIndices(m);
    const auto n = r->getVertexLayoutNormalIndices(m);
    for (std::size_t i = 0; i < p.size(); ++i) {
        out3[3 * i + 0] = p[i];
        out3[3 * i + 1] = t[i];
        out3[3 * i + 2] = n[i];
    }
}

uint32_t fsrl_dna_mesh_face(const FsrlDna* dna, uint32_t mesh, uint32_t face, uint32_t* out, uint32_t capacity) {
    if (mesh >= dna->reader->getMeshCount() || face >= dna->reader->getFaceCount(static_cast<std::uint16_t>(mesh))) return 0u;
    return copyOut(dna->reader->getFaceVertexLayoutIndices(static_cast<std::uint16_t>(mesh), face), out, capacity);
}

uint32_t fsrl_dna_mesh_skin(const FsrlDna* dna, uint32_t mesh, uint32_t vertex, float* weights, uint16_t* joints,
                            uint32_t capacity) {
    if (mesh >= dna->reader->getMeshCount()) return 0u;
    const auto m = static_cast<std::uint16_t>(mesh);
    if (vertex >= dna->reader->getSkinWeightsCount(m)) return 0u;
    copyOut(dna->reader->getSkinWeightsJointIndices(m, vertex), joints, capacity);
    return copyOut(dna->reader->getSkinWeightsValues(m, vertex), weights, capacity);
}

}  // extern "C"
