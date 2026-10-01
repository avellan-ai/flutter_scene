// Optional heightfield tracing, adapted from bdero/flutter_scene 83f59698.
// Include only in materials that use height relief. Native normal mapping stays
// unchanged, including its compiled shader identity and cost.
vec3 PerturbParallaxNormal(sampler2D normal_tex, vec3 normal,
                          highp vec3 view_vector, highp vec2 displaced_uv,
                          highp vec2 frame_uv, float scale) {
  vec3 mapped = texture(normal_tex, displaced_uv).xyz * 255.0 / 127.0 - 128.0 / 127.0;
  mapped.xy *= scale;
  return normalize(TangentFrame(normal, -view_vector, frame_uv) * mapped);
}

const int kParallaxMaxSteps = 64;

highp vec2 ParallaxOcclusionOffset(sampler2D height_tex, vec3 normal,
                                   highp vec3 view_vector, highp vec2 uv,
                                   vec2 scale, int steps, vec4 uv_bounds) {
  mat3 frame = TangentFrame(normal, -view_vector, uv);
  // The derivative frame is only scale-invariant, so unitize before
  // projecting. The floors keep a degenerate frame finite.
  highp vec3 tangent = frame[0];
  highp vec3 bitangent = frame[1];
  tangent *= inversesqrt(max(dot(tangent, tangent), 1e-20));
  bitangent *= inversesqrt(max(dot(bitangent, bitangent), 1e-20));
  highp vec3 view_dir = GetViewDirection();
  highp vec3 view_ts = vec3(dot(view_dir, tangent), dot(view_dir, bitangent),
                            dot(view_dir, normal));
  // A grazing ray travels far across the surface per layer; floor the slope
  // so the march spans a bounded UV distance instead of smearing.
  steps = clamp(steps, 1, kParallaxMaxSteps);
  highp float layer_depth = 1.0 / float(steps);
  highp vec2 delta_uv =
      view_ts.xy / max(view_ts.z, 0.05) * scale * layer_depth;
  // Explicit gradients from the undisplaced coordinates, since an implicit
  // mip selection inside the loop is undefined under divergent control flow.
  highp vec2 dx = dFdx(uv);
  highp vec2 dy = dFdy(uv);
  highp vec2 current_uv = uv;
  highp float current_depth = 0.0;
  highp float surface_depth = 1.0 - textureGrad(height_tex, uv, dx, dy).a;
  highp float previous_depth = 0.0;
  highp float previous_surface_depth = surface_depth;
  // Constant bound with a dynamic break; the loop shape every backend
  // accepts (see SampleShadow for the Direct3D note on early returns).
  for (int i = 0; i < kParallaxMaxSteps; i++) {
    if (i >= steps || current_depth >= surface_depth) break;
    previous_depth = current_depth;
    previous_surface_depth = surface_depth;
    current_uv = clamp(current_uv - delta_uv, uv_bounds.xy, uv_bounds.zw);
    current_depth += layer_depth;
    surface_depth = 1.0 - textureGrad(height_tex, current_uv, dx, dy).a;
  }
  // The ray is below the surface at the current layer and above it at the
  // previous one; the crossing is where the two signed distances agree.
  highp float after = surface_depth - current_depth;
  highp float before = previous_surface_depth - previous_depth;
  highp float weight = clamp(after / min(after - before, -1e-6), 0.0, 1.0);
  highp vec2 hit_uv = clamp(mix(current_uv, current_uv + delta_uv, weight),
                             uv_bounds.xy, uv_bounds.zw);
  return hit_uv - uv;
}
