import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:markify/features/editor/models/editor_state.dart';
import 'package:markify/services/watermark_renderer.dart';

/// Exports the current [EditorState] as a PNG-encoded [Uint8List].
///
/// Uses [WatermarkRenderer] — the same engine as the preview canvas —
/// so the output is pixel-accurate.
class ImageExporter {
  static Future<Uint8List?> export({required EditorState state}) async {
    if (state.image == null) return null;

    final tempDir = await getTemporaryDirectory();
    final inputPath = '${tempDir.path}/export_base.png';
    final inputFile = File(inputPath);
    await inputFile.writeAsBytes(state.image!);

    // Decode base image
    final sourceBytes = await inputFile.readAsBytes();
    final baseImg = img.decodeImage(sourceBytes);
    if (baseImg == null) return null;

    // Render all visible watermarks using the unified renderer
    final visibleLayers = state.layers.where((l) => l.isVisible).toList();
    final result = await WatermarkRenderer.renderOntoImage(
      baseImage: baseImg,
      watermarks: visibleLayers,
    );

    return Uint8List.fromList(img.encodePng(result));
  }
}
