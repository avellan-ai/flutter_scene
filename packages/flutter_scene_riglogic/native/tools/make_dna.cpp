// Writes synthetic DNA rigs with OpenRigLogic's DNA writer. None of them
// contain MetaHuman data, so they can ship as test fixtures.
//
//   make_dna fixture out.dna          small rig with hand-computable outputs
//   make_dna metahuman-scale out.dna  a head sized like a MetaHuman face
//
// Both use DNA's MetaHuman conventions: centimetres, degrees, rotation order
// xyz, and axes x = the character's left, y = up, z = front (the same frame
// as glTF).
//
// The fixture (one LOD, no geometry):
//   GUI gui_jaw, gui_smile. raw0 = gui_jaw on [0, 1]; raw1 = 0.5 * gui_smile.
//   raw controls: jawOpen (0), smile (1), blink (2); PSD 3 = jawOpen * smile.
//   joints: root (0) and jaw (1, child of root, neutral t = (0, 10, 2)).
//   jaw ty delta = -2 * jawOpen + 0.5 * psd; jaw rx delta = 20 degrees * jawOpen.
//   blend shape 0 = jawOpen, blend shape 1 = psd.
//   animated map 0 = clamp(2 * smile - 0.5, 0, 1) on [0, 1].
//
// The metahuman-scale head has MetaHuman's counts (174 GUI and 269 raw
// controls, 545 correctives, 870 joints in 8 LODs, about 1.1 M joint matrix
// values, 782 blend shape channels, 82 animated maps) and a procedural head:
// an ellipsoid with a mouth slit and eye holes, two eyeballs, one mesh per
// LOD (24k, 12k, 6k, 2.5k, ... vertices) skinned with 12, 8 or 4 influences.
// Four controls do something recognisable; the rest move filler joints a
// little:
//   jawOpen (raw 0)   jaw rotates open by 22 degrees
//   lipsPress (raw 1) upper and lower lips press together
//   blinkL (raw 2)    the character's left upper lid closes over the eye
//   blinkR (raw 3)    the right upper lid closes

#include <riglogic/RigLogic.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

namespace {

using u16 = std::uint16_t;
using u32 = std::uint32_t;

struct Vec {
    float x, y, z;
};

Vec operator-(Vec a, Vec b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

float length(Vec v) {
    return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

struct Mesh {
    std::string name;
    std::vector<dna::Position> positions;
    std::vector<dna::Normal> normals;
    std::vector<dna::TextureCoordinate> uvs;
    std::vector<std::vector<u32>> faces;  // vertex (= layout) indices
    u16 maxInfluences = 4;
    std::vector<std::vector<float>> weights;
    std::vector<std::vector<u16>> weightJoints;
};

struct Rig {
    std::vector<std::string> gui, raw, joints, blendShapes, animatedMaps;
    std::vector<u16> parents;
    std::vector<dna::Vector3> neutralT, neutralR;
    u16 lodCount = 1;
    std::vector<u16> g2rIn, g2rOut;
    std::vector<float> g2rFrom, g2rTo, g2rSlope, g2rCut;
    u16 psdCount = 0;
    std::vector<u16> psdRows, psdCols;
    std::vector<float> psdValues;
    struct Group {
        std::vector<u16> lods, inputs, outputs, jointIndices;
        std::vector<float> values;  // row-major, outputs x inputs
    };
    std::vector<Group> groups;
    std::vector<u16> jointsPerLOD;  // LOD l keeps the first N joints
    std::vector<u16> bsLODs, bsIn, bsOut, bsPerLOD;
    std::vector<u16> amLODs, amIn, amOut, amPerLOD;
    std::vector<float> amFrom, amTo, amSlope, amCut;
    std::vector<Mesh> meshes;
    std::vector<std::vector<u16>> meshesPerLOD;
};

void write(const Rig& rig, const char* path, const char* name) {
    auto stream = rl4::makeScoped<rl4::FileStream>(path, rl4::FileStream::AccessMode::Write, rl4::FileStream::OpenMode::Binary);
    auto w = rl4::makeScoped<rl4::BinaryStreamWriter>(stream.get());
    const auto n16 = [](std::size_t n) { return static_cast<u16>(n); };

    w->setName(name);
    w->setArchetype(dna::Archetype::other);
    w->setGender(dna::Gender::other);
    w->setAge(0);
    w->setTranslationUnit(dna::TranslationUnit::cm);
    w->setRotationUnit(dna::RotationUnit::degrees);
    w->setCoordinateSystem({tdm::axis_dir::left, tdm::axis_dir::up, tdm::axis_dir::front});
    w->setRotationSequence(tdm::rot_seq::xyz);
    w->setLODCount(rig.lodCount);
    w->setDBMaxLOD(0);
    w->setDBComplexity("SYNTHETIC");
    w->setDBName("flutter_scene_riglogic");

    for (u16 i = 0; i < rig.gui.size(); ++i) w->setGUIControlName(i, rig.gui[i].c_str());
    for (u16 i = 0; i < rig.raw.size(); ++i) w->setRawControlName(i, rig.raw[i].c_str());
    for (u16 i = 0; i < rig.joints.size(); ++i) w->setJointName(i, rig.joints[i].c_str());
    for (u16 i = 0; i < rig.blendShapes.size(); ++i) w->setBlendShapeChannelName(i, rig.blendShapes[i].c_str());
    for (u16 i = 0; i < rig.animatedMaps.size(); ++i) w->setAnimatedMapName(i, rig.animatedMaps[i].c_str());
    for (u16 i = 0; i < rig.meshes.size(); ++i) w->setMeshName(i, rig.meshes[i].name.c_str());

    for (u16 lod = 0; lod < rig.lodCount; ++lod) {
        const auto prefix = [](u16 n) {
            std::vector<u16> v(n);
            for (u16 i = 0; i < n; ++i) v[i] = i;
            return v;
        };
        auto joints = prefix(rig.jointsPerLOD[lod]);
        w->setJointIndices(lod, joints.data(), n16(joints.size()));
        w->setLODJointMapping(lod, lod);
        auto shapes = prefix(rig.bsPerLOD[lod]);
        w->setBlendShapeChannelIndices(lod, shapes.data(), n16(shapes.size()));
        w->setLODBlendShapeChannelMapping(lod, lod);
        auto maps = prefix(rig.amPerLOD[lod]);
        w->setAnimatedMapIndices(lod, maps.data(), n16(maps.size()));
        w->setLODAnimatedMapMapping(lod, lod);
        const auto& meshes = rig.meshesPerLOD.empty() ? std::vector<u16>{} : rig.meshesPerLOD[lod];
        w->setMeshIndices(lod, meshes.data(), n16(meshes.size()));
        w->setLODMeshMapping(lod, lod);
    }

    w->setJointHierarchy(rig.parents.data(), n16(rig.parents.size()));
    w->setNeutralJointTranslations(rig.neutralT.data(), n16(rig.neutralT.size()));
    w->setNeutralJointRotations(rig.neutralR.data(), n16(rig.neutralR.size()));

    w->setGUIToRawInputIndices(rig.g2rIn.data(), n16(rig.g2rIn.size()));
    w->setGUIToRawOutputIndices(rig.g2rOut.data(), n16(rig.g2rOut.size()));
    w->setGUIToRawFromValues(rig.g2rFrom.data(), n16(rig.g2rFrom.size()));
    w->setGUIToRawToValues(rig.g2rTo.data(), n16(rig.g2rTo.size()));
    w->setGUIToRawSlopeValues(rig.g2rSlope.data(), n16(rig.g2rSlope.size()));
    w->setGUIToRawCutValues(rig.g2rCut.data(), n16(rig.g2rCut.size()));

    w->setPSDCount(rig.psdCount);
    w->setPSDRowIndices(rig.psdRows.data(), n16(rig.psdRows.size()));
    w->setPSDColumnIndices(rig.psdCols.data(), n16(rig.psdCols.size()));
    w->setPSDValues(rig.psdValues.data(), n16(rig.psdValues.size()));

    w->setJointRowCount(n16(rig.joints.size() * 9));
    w->setJointColumnCount(n16(rig.raw.size() + rig.psdCount));
    for (u16 g = 0; g < rig.groups.size(); ++g) {
        const auto& group = rig.groups[g];
        w->setJointGroupLODs(g, group.lods.data(), n16(group.lods.size()));
        w->setJointGroupInputIndices(g, group.inputs.data(), n16(group.inputs.size()));
        w->setJointGroupOutputIndices(g, group.outputs.data(), n16(group.outputs.size()));
        w->setJointGroupValues(g, group.values.data(), static_cast<u32>(group.values.size()));
        w->setJointGroupJointIndices(g, group.jointIndices.data(), n16(group.jointIndices.size()));
    }

    w->setBlendShapeChannelLODs(rig.bsLODs.data(), n16(rig.bsLODs.size()));
    w->setBlendShapeChannelInputIndices(rig.bsIn.data(), n16(rig.bsIn.size()));
    w->setBlendShapeChannelOutputIndices(rig.bsOut.data(), n16(rig.bsOut.size()));

    w->setAnimatedMapLODs(rig.amLODs.data(), n16(rig.amLODs.size()));
    w->setAnimatedMapInputIndices(rig.amIn.data(), n16(rig.amIn.size()));
    w->setAnimatedMapOutputIndices(rig.amOut.data(), n16(rig.amOut.size()));
    w->setAnimatedMapFromValues(rig.amFrom.data(), n16(rig.amFrom.size()));
    w->setAnimatedMapToValues(rig.amTo.data(), n16(rig.amTo.size()));
    w->setAnimatedMapSlopeValues(rig.amSlope.data(), n16(rig.amSlope.size()));
    w->setAnimatedMapCutValues(rig.amCut.data(), n16(rig.amCut.size()));

    for (u16 m = 0; m < rig.meshes.size(); ++m) {
        const Mesh& mesh = rig.meshes[m];
        const auto count = static_cast<u32>(mesh.positions.size());
        w->setVertexPositions(m, mesh.positions.data(), count);
        w->setVertexNormals(m, mesh.normals.data(), count);
        w->setVertexTextureCoordinates(m, mesh.uvs.data(), count);
        std::vector<dna::VertexLayout> layouts(count);
        for (u32 i = 0; i < count; ++i) layouts[i] = {i, i, i};
        w->setVertexLayouts(m, layouts.data(), count);
        for (u32 f = 0; f < mesh.faces.size(); ++f) {
            w->setFaceVertexLayoutIndices(m, f, mesh.faces[f].data(), static_cast<u32>(mesh.faces[f].size()));
        }
        w->setMaximumInfluencePerVertex(m, mesh.maxInfluences);
        for (u32 v = 0; v < count; ++v) {
            w->setSkinWeightsValues(m, v, mesh.weights[v].data(), n16(mesh.weights[v].size()));
            w->setSkinWeightsJointIndices(m, v, mesh.weightJoints[v].data(), n16(mesh.weightJoints[v].size()));
        }
    }

    w->write();
}

Rig fixture() {
    Rig r;
    r.gui = {"gui_jaw", "gui_smile"};
    r.raw = {"jawOpen", "smile", "blink"};
    r.joints = {"root", "jaw"};
    r.parents = {0, 0};
    r.neutralT = {{0.0f, 0.0f, 0.0f}, {0.0f, 10.0f, 2.0f}};
    r.neutralR = {{0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}};
    r.lodCount = 1;
    r.g2rIn = {0, 1};
    r.g2rOut = {0, 1};
    r.g2rFrom = {0.0f, 0.0f};
    r.g2rTo = {1.0f, 1.0f};
    r.g2rSlope = {1.0f, 0.5f};
    r.g2rCut = {0.0f, 0.0f};
    r.psdCount = 1;
    r.psdRows = {3, 3};
    r.psdCols = {0, 1};
    r.psdValues = {1.0f, 1.0f};
    Rig::Group g;
    g.lods = {2};
    g.inputs = {0, 3};
    g.outputs = {1 * 9 + 1, 1 * 9 + 3};  // jaw ty, jaw rx
    g.values = {-2.0f, 0.5f, 20.0f, 0.0f};
    g.jointIndices = {1};
    r.groups = {g};
    r.jointsPerLOD = {2};
    r.blendShapes = {"jawOpen_shape", "jawSmile_corrective"};
    r.bsPerLOD = {2};
    r.bsLODs = {2};
    r.bsIn = {0, 3};
    r.bsOut = {0, 1};
    r.animatedMaps = {"wrinkle_smile"};
    r.amPerLOD = {1};
    r.amLODs = {1};
    r.amIn = {1};
    r.amOut = {0};
    r.amFrom = {0.0f};
    r.amTo = {1.0f};
    r.amSlope = {2.0f};
    r.amCut = {-0.5f};
    return r;
}

// The head is an ellipsoid centred on the head joint.
constexpr float kRx = 7.5f, kRy = 10.5f, kRz = 9.0f;
constexpr float kMouthY = -5.0f, kMouthHalfWidth = 2.6f;
constexpr float kEyeX = 3.2f, kEyeY = 2.0f, kEyeHalfWidth = 1.35f, kEyeHalfHeight = 0.75f;

Vec onHead(float theta, float phi) {
    return {kRx * std::sin(theta) * std::sin(phi), kRy * std::cos(theta), kRz * std::sin(theta) * std::cos(phi)};
}

Vec frontSurface(float x, float y) {
    const float t = 1.0f - (x * x) / (kRx * kRx) - (y * y) / (kRy * kRy);
    return {x, y, kRz * std::sqrt(std::max(t, 0.0f))};
}

enum Side { kUpper, kLower, kAny };

struct JointInfo {
    Vec world;
    float boost;
    float radius;  // cm of skin this joint reaches
    Side side;
};

// An ellipsoid grid with the mouth slit and eye holes cut, `rows` x `cols`.
Mesh headMesh(const std::string& name, int rows, int cols) {
    Mesh m;
    m.name = name;
    auto index = [cols](int r, int c) { return static_cast<u32>(r * (cols + 1) + c); };
    for (int r = 0; r <= rows; ++r) {
        const float theta = 0.02f + 3.1f * r / rows;  // leaves small holes at the poles
        for (int c = 0; c <= cols; ++c) {
            // The UV seam is at the back of the head.
            const float phi = -3.14159265f + 6.2831853f * c / cols;
            const Vec p = onHead(theta, phi);
            m.positions.push_back({p.x, p.y, p.z});
            const Vec n{p.x / (kRx * kRx), p.y / (kRy * kRy), p.z / (kRz * kRz)};
            const float len = length(n);
            m.normals.push_back({n.x / len, n.y / len, n.z / len});
            m.uvs.push_back({static_cast<float>(c) / cols, 1.0f - static_cast<float>(r) / rows});
        }
    }
    auto inEye = [](Vec p) {
        const float dx = std::fabs(p.x) - kEyeX, dy = p.y - kEyeY;
        return p.z > 0 && (dx * dx) / (kEyeHalfWidth * kEyeHalfWidth) + (dy * dy) / (kEyeHalfHeight * kEyeHalfHeight) < 1.0f;
    };
    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < cols; ++c) {
            const u32 a = index(r, c), b = index(r, c + 1), d = index(r + 1, c), e = index(r + 1, c + 1);
            const auto& pa = m.positions[a];
            const auto& pd = m.positions[d];
            const Vec centre{(pa.x + pd.x) / 2, (pa.y + pd.y) / 2, (pa.z + pd.z) / 2};
            // The mouth slit: no faces between the row just above and the row just below the lip line.
            const bool mouth = pa.y >= kMouthY && pd.y < kMouthY && std::fabs(centre.x) < kMouthHalfWidth && centre.z > 0;
            if (mouth || inEye(centre)) continue;
            // Counter-clockwise seen from outside.
            m.faces.push_back({a, d, e, b});
        }
    }
    return m;
}

Mesh eyeMesh(const std::string& name, float side) {
    Mesh m;
    m.name = name;
    const int rows = 16, cols = 24;
    const float radius = 1.3f;
    const Vec surface = frontSurface(side * kEyeX, kEyeY);
    const Vec centre{surface.x, surface.y, surface.z - 1.5f};
    for (int r = 0; r <= rows; ++r) {
        const float theta = 3.14159265f * r / rows;
        for (int c = 0; c <= cols; ++c) {
            const float phi = 6.2831853f * c / cols;
            const Vec n{std::sin(theta) * std::sin(phi), std::cos(theta), std::sin(theta) * std::cos(phi)};
            m.positions.push_back({centre.x + radius * n.x, centre.y + radius * n.y, centre.z + radius * n.z});
            m.normals.push_back({n.x, n.y, n.z});
            m.uvs.push_back({static_cast<float>(c) / cols, 1.0f - static_cast<float>(r) / rows});
        }
    }
    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < cols; ++c) {
            const u32 a = r * (cols + 1) + c, b = a + 1, d = a + cols + 1, e = d + 1;
            m.faces.push_back({a, d, e, b});
        }
    }
    m.maxInfluences = 1;
    for (std::size_t i = 0; i < m.positions.size(); ++i) {
        m.weights.push_back({1.0f});
        m.weightJoints.push_back({0});  // the head joint
    }
    return m;
}

float ramp(float value, float from, float to) {
    const float t = std::min(std::max((value - from) / (to - from), 0.0f), 1.0f);
    return t * t * (3 - 2 * t);
}

// Skins every vertex to the `influences` highest scoring joints among the
// first `jointLimit`. Joints only reach skin within their radius; the head
// joint anchors everything with a small constant score, and the jaw carries
// the lower face with a smooth falloff below the mouth. Next to the mouth slit
// no weight crosses it.
void skin(Mesh& mesh, const std::vector<JointInfo>& joints, u16 head, u16 jaw, u16 jointLimit, u16 influences) {
    mesh.maxInfluences = influences;
    for (const auto& p : mesh.positions) {
        const Vec v{p.x, p.y, p.z};
        const bool nearSlit = v.z > 0 && std::fabs(v.x) < kMouthHalfWidth + 0.8f && std::fabs(v.y - kMouthY) < 1.5f;
        std::vector<std::pair<float, u16>> scored;
        scored.push_back({0.05f, head});
        const float jawWeight = ramp(-v.y, -kMouthY + 0.1f, -kMouthY + 2.5f) * (1 - ramp(std::fabs(v.x), 4.0f, 6.5f)) *
                                ramp(v.z, -3.0f, 0.0f);
        if (jawWeight > 0 && jaw < jointLimit) scored.push_back({jawWeight, jaw});
        for (u16 j = 0; j < jointLimit; ++j) {
            if (j == head || j == jaw) continue;
            const JointInfo& info = joints[j];
            if (nearSlit && info.side == kUpper && v.y < kMouthY) continue;
            if (nearSlit && info.side == kLower && v.y >= kMouthY) continue;
            const float d = length(v - info.world);
            if (d >= info.radius) continue;
            const float falloff = 1 - d / info.radius;
            scored.push_back({info.boost * falloff * falloff, j});
        }
        const std::size_t keep = std::min<std::size_t>(influences, scored.size());
        std::partial_sort(scored.begin(), scored.begin() + keep, scored.end(),
                          [](const auto& a, const auto& b) { return a.first > b.first; });
        float total = 0;
        for (std::size_t i = 0; i < keep; ++i) total += scored[i].first;
        std::vector<float> weights;
        std::vector<u16> jointIndices;
        for (std::size_t i = 0; i < keep; ++i) {
            weights.push_back(scored[i].first / total);
            jointIndices.push_back(scored[i].second);
        }
        mesh.weights.push_back(weights);
        mesh.weightJoints.push_back(jointIndices);
    }
}

Rig metahumanScale() {
    std::mt19937 rng(20260928);
    std::uniform_real_distribution<float> unit(0.0f, 1.0f), small(-0.5f, 0.5f);
    Rig r;
    const u16 guiCount = 174, rawCount = 269, psdCount = 545, jointCount = 870;
    const u16 bsCount = 782, amCount = 82;
    r.jointsPerLOD = {870, 617, 413, 301, 84, 70, 41, 26};
    r.lodCount = static_cast<u16>(r.jointsPerLOD.size());

    // Joints: the 46 that matter first, so every LOD down to 3 keeps them.
    std::vector<JointInfo> info;
    auto addJoint = [&](const std::string& name, u16 parent, Vec world, float boost, float radius, Side side) {
        const Vec parentWorld = r.joints.empty() ? Vec{0, 0, 0} : info[parent].world;
        r.joints.push_back(name);
        r.parents.push_back(parent);
        const Vec local = world - parentWorld;
        r.neutralT.push_back({local.x, local.y, local.z});
        r.neutralR.push_back({0.0f, 0.0f, 0.0f});
        info.push_back({world, boost, radius, side});
        return static_cast<u16>(r.joints.size() - 1);
    };
    const u16 head = addJoint("FACIAL_C_Head", 0, {0, 0, 0}, 0.0f, 0.0f, kAny);
    const u16 jaw = addJoint("FACIAL_C_Jaw", head, {0, -2.0f, -1.0f}, 0.0f, 0.0f, kLower);
    std::vector<u16> upperLips, lowerLips, upperLids[2], lowerLids[2];
    for (int i = 0; i < 10; ++i) {
        const float x = -kMouthHalfWidth + 2 * kMouthHalfWidth * (i + 0.5f) / 10;
        upperLips.push_back(addJoint("FACIAL_UpperLip_" + std::to_string(i), head, frontSurface(x, kMouthY + 0.35f), 3.0f, 1.3f, kUpper));
    }
    for (int i = 0; i < 10; ++i) {
        const float x = -kMouthHalfWidth + 2 * kMouthHalfWidth * (i + 0.5f) / 10;
        lowerLips.push_back(addJoint("FACIAL_LowerLip_" + std::to_string(i), jaw, frontSurface(x, kMouthY - 0.35f), 3.0f, 1.3f, kLower));
    }
    for (int s = 0; s < 2; ++s) {
        const float side = s == 0 ? 1.0f : -1.0f;  // 0 is the character's left (+x)
        const char* tag = s == 0 ? "L" : "R";
        for (int i = 0; i < 6; ++i) {
            const float x = side * (kEyeX - kEyeHalfWidth + 2 * kEyeHalfWidth * (i + 0.5f) / 6);
            upperLids[s].push_back(addJoint(std::string("FACIAL_") + tag + "_EyelidUpper_" + std::to_string(i), head,
                                            frontSurface(x, kEyeY + kEyeHalfHeight + 0.25f), 12.0f, 1.0f, kUpper));
        }
        for (int i = 0; i < 6; ++i) {
            const float x = side * (kEyeX - kEyeHalfWidth + 2 * kEyeHalfWidth * (i + 0.5f) / 6);
            lowerLids[s].push_back(addJoint(std::string("FACIAL_") + tag + "_EyelidLower_" + std::to_string(i), head,
                                            frontSurface(x, kEyeY - kEyeHalfHeight - 0.25f), 8.0f, 0.7f, kUpper));
        }
    }
    const u16 semanticCount = static_cast<u16>(r.joints.size());
    // Filler joints over the front of the face, in random order so every LOD
    // keeps a spread of them.
    std::vector<Vec> spots;
    for (int i = 0; spots.size() < jointCount - semanticCount; ++i) {
        const float x = (unit(rng) * 2 - 1) * kRx * 0.95f, y = (unit(rng) * 2 - 1) * kRy * 0.9f;
        if ((x * x) / (kRx * kRx) + (y * y) / (kRy * kRy) < 0.9f) spots.push_back(frontSurface(x, y));
    }
    for (std::size_t i = 0; i < spots.size(); ++i) {
        const Side side = (spots[i].y < kMouthY && std::fabs(spots[i].x) < 6.0f) ? kLower : kUpper;
        addJoint("FACIAL_Region_" + std::to_string(i), side == kLower ? jaw : head, spots[i], 1.0f, 2.0f, side);
    }

    const char* semantic[] = {"CTRL_expressions.jawOpen", "CTRL_expressions.lipsPress", "CTRL_expressions.eyeBlinkL",
                              "CTRL_expressions.eyeBlinkR"};
    for (u16 i = 0; i < rawCount; ++i) r.raw.push_back(i < 4 ? semantic[i] : "CTRL_expressions.raw_" + std::to_string(i));
    for (u16 i = 0; i < guiCount; ++i) r.gui.push_back(i < 4 ? std::string("CTRL_gui.") + semantic[i] + "" : "CTRL_gui_" + std::to_string(i));
    for (u16 i = 0; i < guiCount; ++i) {
        r.g2rIn.push_back(i);
        r.g2rOut.push_back(static_cast<u16>(i % rawCount));
        r.g2rFrom.push_back(0.0f);
        r.g2rTo.push_back(1.0f);
        r.g2rSlope.push_back(1.0f);
        r.g2rCut.push_back(0.0f);
    }
    // Correctives combine filler controls only, so the four recognisable
    // controls stay exactly what they say.
    r.psdCount = psdCount;
    for (u16 k = 0; k < psdCount; ++k) {
        const u16 a = static_cast<u16>(4 + static_cast<u16>(unit(rng) * (rawCount - 4)) % (rawCount - 4));
        u16 b = static_cast<u16>(4 + static_cast<u16>(unit(rng) * (rawCount - 4)) % (rawCount - 4));
        if (b == a) b = static_cast<u16>(a + 1 < rawCount ? a + 1 : 4);
        for (u16 c : {a, b}) {
            r.psdRows.push_back(static_cast<u16>(rawCount + k));
            r.psdCols.push_back(c);
            r.psdValues.push_back(1.0f);
        }
    }

    auto lodRows = [&](const std::vector<u16>& outputs) {
        std::vector<u16> lods;
        for (u16 lod = 0; lod < r.lodCount; ++lod) {
            u16 rows = 0;
            for (u16 out : outputs) rows = static_cast<u16>(rows + ((out / 9) < r.jointsPerLOD[lod] ? 1 : 0));
            lods.push_back(rows);
        }
        return lods;
    };
    // Group rows must be ordered so each LOD is a prefix: joints are already
    // ordered by LOD, so sorting outputs by joint keeps that.
    auto semanticGroup = [&](std::vector<std::pair<u16, float>> rows, u16 input) {
        std::sort(rows.begin(), rows.end());
        Rig::Group g;
        for (auto& [out, value] : rows) {
            g.outputs.push_back(out);
            g.values.push_back(value);
            const u16 joint = static_cast<u16>(out / 9);
            if (g.jointIndices.empty() || g.jointIndices.back() != joint) g.jointIndices.push_back(joint);
        }
        g.inputs = {input};
        g.lods = lodRows(g.outputs);
        r.groups.push_back(std::move(g));
    };
    semanticGroup({{static_cast<u16>(jaw * 9 + 3), 22.0f}}, 0);  // jaw rx
    std::vector<std::pair<u16, float>> press;
    for (u16 j : upperLips) press.push_back({static_cast<u16>(j * 9 + 1), -0.35f});
    for (u16 j : lowerLips) press.push_back({static_cast<u16>(j * 9 + 1), 0.35f});
    semanticGroup(press, 1);
    for (int s = 0; s < 2; ++s) {
        std::vector<std::pair<u16, float>> blink;
        for (u16 j : upperLids[s]) {
            blink.push_back({static_cast<u16>(j * 9 + 1), -(2 * kEyeHalfHeight + 0.35f)});
            blink.push_back({static_cast<u16>(j * 9 + 2), 0.25f});
        }
        for (u16 j : lowerLids[s]) blink.push_back({static_cast<u16>(j * 9 + 1), 0.15f});
        semanticGroup(blink, static_cast<u16>(2 + s));
    }
    // Filler: groups of 7 joints x 6 attributes, 220 inputs each, small values.
    const u16 inputCount = rawCount + psdCount;
    std::vector<u16> fillerInputs;
    for (u16 i = 4; i < inputCount; ++i) fillerInputs.push_back(i);
    for (u16 joint = semanticCount; joint < jointCount;) {
        Rig::Group g;
        for (u16 j = 0; j < 7 && joint < jointCount; ++j, ++joint) {
            g.jointIndices.push_back(joint);
            for (u16 attr : {0, 1, 2, 3, 4, 5}) g.outputs.push_back(static_cast<u16>(joint * 9 + attr));
        }
        std::shuffle(fillerInputs.begin(), fillerInputs.end(), rng);
        g.inputs.assign(fillerInputs.begin(), fillerInputs.begin() + 220);
        std::sort(g.inputs.begin(), g.inputs.end());
        for (std::size_t row = 0; row < g.outputs.size(); ++row) {
            const bool rotation = (g.outputs[row] % 9) >= 3;
            for (std::size_t col = 0; col < g.inputs.size(); ++col) g.values.push_back(small(rng) * (rotation ? 0.02f : 0.002f));
        }
        g.lods = lodRows(g.outputs);
        r.groups.push_back(std::move(g));
    }

    for (u16 i = 0; i < bsCount; ++i) {
        r.blendShapes.push_back("shape_" + std::to_string(i));
        r.bsIn.push_back(static_cast<u16>(unit(rng) * inputCount) % inputCount);
        r.bsOut.push_back(i);
    }
    r.bsPerLOD.assign(r.lodCount, 0);
    r.bsPerLOD[0] = bsCount;
    r.bsLODs.assign(r.lodCount, 0);
    r.bsLODs[0] = bsCount;
    for (u16 i = 0; i < amCount; ++i) {
        r.animatedMaps.push_back("wrinkle_" + std::to_string(i));
        r.amIn.push_back(static_cast<u16>(unit(rng) * inputCount) % inputCount);
        r.amOut.push_back(i);
        r.amFrom.push_back(0.0f);
        r.amTo.push_back(1.0f);
        r.amSlope.push_back(1.0f);
        r.amCut.push_back(0.0f);
    }
    r.amPerLOD.assign(r.lodCount, 0);
    r.amPerLOD[0] = r.amPerLOD[1] = amCount;
    r.amLODs.assign(r.lodCount, 0);
    r.amLODs[0] = r.amLODs[1] = amCount;

    // Geometry: one head per LOD with MetaHuman's vertex counts and influence
    // limits, plus eyeballs shared by every LOD.
    struct Level {
        int rows, cols;
        u16 influences;
    };
    const Level levels[] = {{130, 184, 12}, {92, 130, 12}, {65, 92, 12}, {42, 60, 8},
                            {30, 42, 8},    {20, 28, 8},   {14, 19, 4}, {10, 13, 4}};
    r.meshes.push_back(eyeMesh("eyeLeft", 1.0f));
    r.meshes.push_back(eyeMesh("eyeRight", -1.0f));
    r.meshesPerLOD.resize(r.lodCount);
    for (u16 lod = 0; lod < r.lodCount; ++lod) {
        Mesh headGeometry = headMesh("head_lod" + std::to_string(lod), levels[lod].rows, levels[lod].cols);
        skin(headGeometry, info, head, jaw, r.jointsPerLOD[lod], levels[lod].influences);
        r.meshesPerLOD[lod] = {static_cast<u16>(r.meshes.size()), 0, 1};
        r.meshes.push_back(std::move(headGeometry));
    }
    return r;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: make_dna fixture|metahuman-scale out.dna\n");
        return 2;
    }
    if (std::strcmp(argv[1], "fixture") == 0) {
        write(fixture(), argv[2], "fixture");
    } else if (std::strcmp(argv[1], "metahuman-scale") == 0) {
        write(metahumanScale(), argv[2], "metahuman-scale");
    } else {
        std::fprintf(stderr, "unknown rig %s\n", argv[1]);
        return 2;
    }
    if (!rl4::Status::isOk()) {
        std::fprintf(stderr, "%s\n", rl4::Status::get().message);
        return 1;
    }
    return 0;
}
