import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/gpu/render_pass_compat.dart';
import 'package:flutter_scene/src/render/frame_transients.dart';
import 'package:flutter_scene/src/render/render_graph.dart';
import 'package:flutter_scene/src/render/scene_pass.dart';
import 'package:flutter_scene/src/scene_encoder.dart' show resolvePipeline;
import 'package:flutter_scene/src/shaders.dart';

/// Copies linear HDR color before post-processing or the display transform.
/// Capture filtering can supply an explicit input, target mip and filter;
/// the default copies the current scene color at full resolution.
class SceneColorBlitPass extends RenderGraphPass {
  SceneColorBlitPass({
    required gpu.Texture output,
    gpu.Texture? input,
    int outputMipLevel = 0,
    bool linearFilter = false,
  }) : _output = output,
       _input = input,
       _outputMipLevel = outputMipLevel,
       _linearFilter = linearFilter;

  final gpu.Texture _output;
  final gpu.Texture? _input;
  final int _outputMipLevel;
  final bool _linearFilter;

  static final gpu.Shader _vertexShader =
      baseShaderLibrary['FullscreenVertex']!;
  static final gpu.Shader _fragmentShader = baseShaderLibrary['CopyFragment']!;

  static final gpu.DeviceBuffer _quadBuffer = gpu.gpuContext
      .createDeviceBufferWithCopy(
        ByteData.sublistView(
          Float32List.fromList(<double>[
            -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, //
            -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, //
          ]),
        ),
      );
  static final gpu.BufferView _quadView = gpu.BufferView(
    _quadBuffer,
    offsetInBytes: 0,
    lengthInBytes: 6 * 2 * 4,
  );

  static final gpu.SamplerOptions _nearestClamp = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.nearest,
    magFilter: gpu.MinMagFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );
  static final gpu.SamplerOptions _linearClamp = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  @override
  String get name => 'SceneColorBlitPass';

  @override
  void execute(RenderGraphContext context) {
    final input =
        _input ??
        context.blackboard.require<gpu.Texture>(kSceneColorBlackboardKey);
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final renderPass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(texture: _output, mipLevel: _outputMipLevel),
      ),
    );
    renderPass.bindPipeline(resolvePipeline(_vertexShader, _fragmentShader));
    renderPass.setColorBlendEnable(false);
    bindVertexBufferCompat(renderPass, _quadView, 6);
    renderPass.bindTexture(
      _fragmentShader.getUniformSlot('source_texture'),
      input,
      sampler: _linearFilter ? _linearClamp : _nearestClamp,
    );
    drawCompat(renderPass, 6);
    rendererSubmissions.submit(commandBuffer);
  }
}
