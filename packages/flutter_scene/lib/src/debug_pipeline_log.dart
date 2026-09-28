// Diagnostics for pipelines a backend fails to build (such as a GPU driver's
// shader compiler crashing): with --dart-define=FLUTTER_SCENE_LOG_PIPELINES=true,
// every pipeline build is logged with its shader names before it starts.

import 'package:flutter/foundation.dart';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

const bool logPipelineBuilds = bool.fromEnvironment(
  'FLUTTER_SCENE_LOG_PIPELINES',
);

final Expando<String> _shaderNames = Expando('shader names');

/// Records [name] for [shader], so pipeline logs can name it.
gpu.Shader nameShader(gpu.Shader shader, String name) {
  if (logPipelineBuilds) _shaderNames[shader] ??= name;
  return shader;
}

/// Names every shader of the base bundle.
void nameBaseShaders(gpu.ShaderLibrary library) {
  if (!logPipelineBuilds) return;
  for (final name in _baseShaderNames) {
    final shader = library[name];
    if (shader != null) nameShader(shader, name);
  }
}

String shaderName(gpu.Shader shader) =>
    _shaderNames[shader] ?? 'shader#${identityHashCode(shader)}';

void logPipelineBuild(
  gpu.Shader vertex,
  gpu.Shader fragment,
  int layoutId,
  String Function()? context,
) {
  if (!logPipelineBuilds) return;
  debugPrint(
    'FLUTTER_SCENE_PIPELINE build ${shaderName(vertex)} + ${shaderName(fragment)} layout $layoutId'
    '${context != null ? ' (${context()})' : ''}',
  );
}

const _baseShaderNames = <String>[
  'UnskinnedVertex',
  'SkinnedVertex',
  'MorphedUnskinnedVertex',
  'MorphedSkinnedVertex',
  'UnskinnedDepthVertex',
  'UnlitFragment',
  'BillboardVertex',
  'LineSegmentsVertex',
  'SpriteFragment',
  'StandardFragment',
  'StandardCubeFragment',
  'StandardLightmapFragment',
  'StandardLightmapCubeFragment',
  'StandardNoShadowFragment',
  'StandardNoShadowCubeFragment',
  'StandardLightmapNoShadowFragment',
  'StandardLightmapNoShadowCubeFragment',
  'DepthOnlyFragment',
  'DepthOnlyMaskedFragment',
  'ShadowCopyFragment',
  'ShadowCatcherBlurFragment',
  'DofCocFragment',
  'DofDilateFragment',
  'DofGatherFragment',
  'DofPostFilterFragment',
  'DofCompositeFragment',
  'LinearDepthFragment',
  'LinearDepthMaskedFragment',
  'MaskFragment',
  'DebugSurfaceFragment',
  'OutlineFragment',
  'GodRaysFragment',
  'ScreenDistortionFragment',
  'SsaoFragment',
  'GtaoFragment',
  'DepthDownsampleFragment',
  'SsaoBlurFragment',
  'SsrFragment',
  'SsrCompositeFragment',
  'LinearDepthNormalFragment',
  'LinearDepthNormalMaskedFragment',
  'FullscreenVertex',
  'ResolveFragment',
  'FxaaFragment',
  'PrefilterEnvFragment',
  'PrefilterRadianceCubeFragment',
  'AutoExposureSeedFragment',
  'AutoExposureAdaptFragment',
  'BloomThresholdFragment',
  'BloomDownsampleFragment',
  'BloomUpsampleFragment',
  'SkyboxVertex',
  'SkyboxEnvironmentFragment',
  'SkyboxEnvironmentCubeFragment',
  'CubeToEquirectFragment',
  'ShProjectFragment',
  'ShCompositeFragment',
  'SkyGradientFragment',
  'SkyPhysicalFragment',
  'SplatsVertex',
  'SplatsFragment',
  'CopyFragment',
  'SmaaEdgesFragment',
  'SmaaWeightsFragment',
  'SmaaBlendFragment',
  'LensFlareFragment',
  'IrradianceInjectVertex',
  'IrradianceInjectFragment',
  'IrradianceInjectDepthFragment',
  'IrradianceBlendFragment',
  'IrradianceBlendDepthFragment',
  'IrradianceFilterFragment',
  'IrradianceStripFragment',
  'VelocityUnskinnedVertex',
  'VelocitySkinnedVertex',
  'VelocityFragment',
  'TaaFragment',
  'DisplayReferredCompositeFragment',
];
