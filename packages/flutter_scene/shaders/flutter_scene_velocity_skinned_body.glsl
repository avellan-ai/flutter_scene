// Shared body for the skinned velocity vertex shaders, which render the
// deformation velocity of skinned moving objects.
//
// Reads current joints texture and previous frame joints texture to compute
// current and previous deformed clip positions. Defining
// FLUTTER_SCENE_SKIN_12_INFLUENCES first reads the 168-byte layout's two
// extra joint/weight sets; without it the body compiles byte-for-byte to the
// 4-influence shader.

uniform VelocityFrameInfo {
  mat4 current_view_projection;
  mat4 previous_view_projection;
  vec4 current_previous_jitter; // xy: current jitter NDC, zw: previous jitter NDC
} frame_info;

uniform VelocitySkinnedModelInfo {
  mat4 current_model_transform;
  mat4 previous_model_transform;
  float current_joint_texture_size;
  float previous_joint_texture_size;
  float enable_skinning;
  float padding;
} model_info;

uniform sampler2D current_joints_texture;
uniform sampler2D previous_joints_texture;

in vec3 position;
in vec4 joints;
in vec4 weights;
#ifdef FLUTTER_SCENE_SKIN_12_INFLUENCES
in vec4 joints_1;
in vec4 weights_1;
in vec4 joints_2;
in vec4 weights_2;
#endif

out vec4 v_current_clip;
out vec4 v_previous_clip;
out vec4 v_static_clip;

const int kMatrixTexelStride = 4;

mat4 GetJoint(sampler2D tex, float tex_size, float joint_index) {
  float texel_size_uv = 1.0 / tex_size;
  float matrix_start = joint_index * float(kMatrixTexelStride);
  float x = mod(matrix_start, tex_size);
  float y = floor(matrix_start / tex_size);
  y = (y + 0.5) * texel_size_uv;
  return mat4(
    texture(tex, vec2((x + 0.5) * texel_size_uv, y)),
    texture(tex, vec2((x + 1.5) * texel_size_uv, y)),
    texture(tex, vec2((x + 2.5) * texel_size_uv, y)),
    texture(tex, vec2((x + 3.5) * texel_size_uv, y))
  );
}

void main() {
  vec4 pos = vec4(position, 1.0);
  vec4 cur_deformed = pos;
  vec4 prev_deformed = pos;

  if (model_info.enable_skinning > 0.5) {
    // Normalized as in flutter_scene_skinned_body.glsl so both passes deform
    // to the same positions.
#ifdef FLUTTER_SCENE_SKIN_12_INFLUENCES
    float weight_sum = weights.x + weights.y + weights.z + weights.w +
                       dot(weights_1, vec4(1.0)) + dot(weights_2, vec4(1.0));
#else
    float weight_sum = weights.x + weights.y + weights.z + weights.w;
#endif
    vec4 w = weight_sum > 0.0 ? weights / weight_sum : vec4(1.0, 0.0, 0.0, 0.0);

    mat4 cur_skin =
      GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints.x) * w.x +
      GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints.y) * w.y +
      GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints.z) * w.z +
      GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints.w) * w.w;

    mat4 prev_skin =
      GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints.x) * w.x +
      GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints.y) * w.y +
      GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints.z) * w.z +
      GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints.w) * w.w;

#ifdef FLUTTER_SCENE_SKIN_12_INFLUENCES
    // Empty trailing sets skip their fetches, as in the color pass.
    if (weights_1 != vec4(0.0)) {
      vec4 w1 = weight_sum > 0.0 ? weights_1 / weight_sum : vec4(0.0);
      cur_skin +=
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_1.x) * w1.x +
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_1.y) * w1.y +
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_1.z) * w1.z +
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_1.w) * w1.w;
      prev_skin +=
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_1.x) * w1.x +
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_1.y) * w1.y +
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_1.z) * w1.z +
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_1.w) * w1.w;
    }
    if (weights_2 != vec4(0.0)) {
      vec4 w2 = weight_sum > 0.0 ? weights_2 / weight_sum : vec4(0.0);
      cur_skin +=
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_2.x) * w2.x +
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_2.y) * w2.y +
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_2.z) * w2.z +
        GetJoint(current_joints_texture, model_info.current_joint_texture_size, joints_2.w) * w2.w;
      prev_skin +=
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_2.x) * w2.x +
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_2.y) * w2.y +
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_2.z) * w2.z +
        GetJoint(previous_joints_texture, model_info.previous_joint_texture_size, joints_2.w) * w2.w;
    }
#endif

    cur_deformed = cur_skin * pos;
    prev_deformed = prev_skin * pos;
  }

  vec4 cur_world = model_info.current_model_transform * cur_deformed;
  vec4 prev_world = model_info.previous_model_transform * prev_deformed;

  v_current_clip = frame_info.current_view_projection * cur_world;
  v_previous_clip = frame_info.previous_view_projection * prev_world;
  v_static_clip = frame_info.previous_view_projection * cur_world;

  gl_Position = v_current_clip;
}
