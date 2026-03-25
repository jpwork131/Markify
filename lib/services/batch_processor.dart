import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:markify/features/editor/models/editor_state.dart';
import 'package:markify/services/video_watermark_service.dart';
import 'package:markify/services/watermark_renderer.dart';

import 'package:path/path.dart' as p;

class BatchProcessor {
  final List<String> paths;
  final EditorState configState;
  final String outputDir;
  final void Function(int current, int total) onProgress;
  final void Function(int success, int failed) onComplete;

  BatchProcessor({
    required this.paths,
    required this.configState,
    required this.outputDir,
    required this.onProgress,
    required this.onComplete,
  });

  Future<void> processBatch() async {
    int successCount = 0;
    int failedCount = 0;

    try {
      for (int i = 0; i < paths.length; i++) {
        onProgress(i, paths.length);
        final file = File(paths[i]);
        try {
          final result = await processSingleFile(file, i);
          if (result != null) {
            successCount++;
          } else {
            failedCount++;
          }
        } catch (e) {
          debugPrint('[BatchProcessor] Error on file $i: $e');
          failedCount++;
        }
        // Allow UI thread to breathe
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } catch (e) {
      debugPrint('[BatchProcessor] CRITICAL BATCH ERROR: $e');
      failedCount = paths.length - successCount;
    } finally {
      onProgress(paths.length, paths.length);
      onComplete(successCount, failedCount);
    }
  }

  Future<File?> processSingleFile(File file, int index) async {
    final path = file.path;
    final ext = path.split('.').last.toLowerCase();
    final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
    final outputFileName = 'watermarked_${index + 1}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final outputPath = p.join(outputDir, outputFileName);

    final currentLayers = configState.fileLayers[path] ?? [];


    if (isVideo) {
      final dims = await VideoWatermarkService.probeVideoDimensions(path);
      if (dims == null) return null;
      
      final success = await VideoWatermarkService.applyWatermarks(
        inputVideoPath: path,
        watermarks: currentLayers,
        outputPath: outputPath,
        videoWidth: dims.$1,
        videoHeight: dims.$2,
      );
      if (success) return File(outputPath);
      return null;
    } else {
      // 1. Read bytes
      final bytes = await file.readAsBytes();
      
      // 2. Decode (Can be slow, so we yield before)
      await Future.delayed(Duration.zero);
      final baseImg = img.decodeImage(bytes);
      if (baseImg == null) return null;

      // 3. Render (Must be on main isolate because it uses dart:ui for text)
      final result = await WatermarkRenderer.renderOntoImage(
        baseImage: baseImg,
        watermarks: currentLayers,
      );

      // 4. Encode (Can be slow, so we yield before)
      await Future.delayed(Duration.zero);
      final resultBytes = Uint8List.fromList(img.encodePng(result));
      
      final outFile = File(outputPath);
      await outFile.writeAsBytes(resultBytes);
      return outFile;
    }
  }
}


