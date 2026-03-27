import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:markify/shared/models/watermark.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

// Top-level function for isolates.
// gzip level 0/1 is significantly faster than default for temporary storage.
List<int> _encodePngFast(img.Image image) => img.encodePng(image, level: 1);

// ADDED: Fast JPEG encoder optimized for batch processing.
// Quality 85 provides excellent visual quality while maintaining 3-4x faster
// encoding than default quality 95. Perfect for bulk watermarked exports.
List<int> _encodeJpgFast(img.Image image) => img.encodeJpg(image, quality: 85);

// Track per-job cache associations for cleanup
final Map<String, Map<String, bool>> _jobCacheMap = {};

/// Unified rendering engine — single source of truth for all watermark output.
class WatermarkRenderer {
  // ── PNG Watermark Cache ────────────────────────────────────────────────────
  // Pre-loaded once per distinct PNG path; reused across all videos in a batch.
  // Key: "${imagePath}|${targetW}x${targetH}"
  static final Map<String, img.Image> _logoCache = {};

  /// Call before starting a batch to pre-warm the logo cache for all
  /// [LogoWatermark]s used, at the specified [videoW]×[videoH] resolution.
  /// This avoids repeated disk I/O and resize operations per-job.
  static Future<void> prewarmLogoCache({
    required List<Watermark> watermarks,
    required int videoW,
    required int videoH,
  }) async {
    for (final wm in watermarks) {
      if (wm is! LogoWatermark || !wm.isVisible) continue;
      final targetW = (wm.normalizedWidth * videoW).round().clamp(
        1,
        videoW * 4,
      );
      final targetH = (wm.normalizedHeight * videoH).round().clamp(
        1,
        videoH * 4,
      );
      final key = '${wm.imagePath}|${targetW}x$targetH';
      if (!_logoCache.containsKey(key)) {
        final cached = await _buildLogoRaster(wm, videoW, videoH);
        if (cached != null) _logoCache[key] = cached;
      }
    }
  }

  /// Clear all caches and temporary overlay files.
  /// Call after an entire batch completes to free memory and disk space.
  static Future<void> clearAllCaches() async {
    _logoCache.clear();
    _sourceImageCache.clear();
    _overlayFileCache.clear();
    _jobCacheMap.clear();
    try {
      final tempDir = await getTemporaryDirectory();
      final globalTemp = Directory(p.join(tempDir.path, 'global_overlays'));
      if (globalTemp.existsSync()) {
        await globalTemp.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('[WatermarkRenderer] Cleanup error: $e');
    }
  }

  /// Clear only the overlay PNG files cached for a specific job.
  /// Keeps logo cache and source images for batch deduplication.
  /// ADDED: Aggressive per-job memory cleanup.
  static Future<void> clearJobCaches(String jobId) async {
    final cacheKeys = _jobCacheMap[jobId];
    if (cacheKeys != null) {
      for (final key in cacheKeys.keys) {
        final entry = _overlayFileCache[key];
        if (entry != null) {
          try {
            if (File(entry.path).existsSync()) {
              await File(entry.path).delete();
            }
            _overlayFileCache.remove(key);
          } catch (e) {
            debugPrint('[WatermarkRenderer] Job cache cleanup error: $e');
          }
        }
      }
      _jobCacheMap.remove(jobId);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Composites all visible [watermarks] onto [baseImage] in-place.
  /// ADDED: UI yield between each layer to prevent event loop starvation.
  static Future<img.Image> renderOntoImage({
    required img.Image baseImage,
    required List<Watermark> watermarks,
  }) async {
    img.Image result = baseImage;
    for (final wm in watermarks) {
      if (!wm.isVisible) continue;
      final wmImg = await _buildRaster(wm, result.width, result.height);
      if (wmImg == null) continue;
      result = _compositeOnto(result, wmImg, wm);
      // Yield to UI thread between layers
      await Future.delayed(Duration.zero);
    }
    return result;
  }

  // ── PNG Overlay Cache (Cross-Job) ──────────────────────────────────────────
  // Caches final PNG files for specific Watermark + Resolution combinations.
  static final Map<String, _OverlayCacheEntry> _overlayFileCache = {};

  /// Saves each visible watermark as a PNG and returns descriptors
  /// that tell FFmpeg where to overlay each PNG onto the video.
  /// ADDED: Persistent jobId tracking for per-job cache cleanup.
  static Future<List<FfmpegOverlayDescriptor>> buildFfmpegDescriptors({
    required List<Watermark> watermarks,
    required int videoW,
    required int videoH,
    required String tempDir,
    String? jobId,
  }) async {
    try {
      final descriptors = <FfmpegOverlayDescriptor>[];
      if (jobId != null && !_jobCacheMap.containsKey(jobId)) {
        _jobCacheMap[jobId] = {};
      }

      for (final wm in watermarks) {
        if (!wm.isVisible) continue;

        // Yield to keep UI event loop responsive
        await Future.delayed(Duration.zero);

        final cacheKey = '${wm.hashCode}|${videoW}x$videoH';
        _OverlayCacheEntry? entry = _overlayFileCache[cacheKey];

        // Track this cache entry for per-job cleanup
        if (jobId != null) {
          _jobCacheMap[jobId]![cacheKey] = true;
        }

        // If not in cache or file missing, render it
        if (entry == null || !File(entry.path).existsSync()) {
          final wmImg = await _buildRaster(wm, videoW, videoH);
          if (wmImg == null) continue;

          final globalTemp = Directory(
            p.join(p.dirname(tempDir), 'global_overlays'),
          );
          if (!globalTemp.existsSync()) globalTemp.createSync(recursive: true);

          final overlayPath = p.join(
            globalTemp.path,
            'ov_${wm.hashCode}_${videoW}x$videoH.png',
          );

          // Speed optimization: Encode PNG with low compression (level 1)
          // and run in an isolate (compute) to keep UI responsive.
          final pngBytes = await compute(_encodePngFast, wmImg);
          await File(overlayPath).writeAsBytes(pngBytes);

          entry = _OverlayCacheEntry(
            path: overlayPath,
            width: wmImg.width,
            height: wmImg.height,
          );
          _overlayFileCache[cacheKey] = entry;
        }

        // Calculate Top-Left position in video pixel space using cached dimensions
        final double cx = wm.normalizedCenterX * videoW;
        final double cy = wm.normalizedCenterY * videoH;
        final int x = (cx - entry.width / 2.0).round();
        final int y = (cy - entry.height / 2.0).round();

        descriptors.add(
          FfmpegOverlayDescriptor(
            imagePath: entry.path,
            x: x,
            y: y,
            width: entry.width,
            height: entry.height,
            animationType: wm.animationType,
            animationSpeed: wm.animationSpeed,
            videoW: videoW,
            videoH: videoH,
          ),
        );
      }
      return descriptors;
    } catch (e) {
      debugPrint('[WatermarkRenderer] Build descriptors error: $e');
      rethrow;
    }
  }

  // ── Raster builder ─────────────────────────────────────────────────────────

  static Future<img.Image?> _buildRaster(
    Watermark wm,
    int imageW,
    int imageH,
  ) async {
    img.Image? base;
    if (wm is TextWatermark) {
      base = await _rasterizeText(wm, imageW, imageH);
    } else if (wm is LogoWatermark) {
      base = await _rasterizeLogo(wm, imageW, imageH);
    }

    if (base == null) return null;

    if (wm.opacity < 1.0) {
      _applyOpacity(base, wm.opacity);
    }

    if (wm.rotation != 0.0) {
      base = img.copyRotate(base, angle: wm.rotation);
    }

    return base;
  }

  static Future<img.Image?> _rasterizeText(
    TextWatermark wm,
    int imageW,
    int imageH,
  ) async {
    final int targetW = (wm.normalizedWidth * imageW).round().clamp(
      1,
      imageW * 4,
    );
    final int targetH = (wm.normalizedHeight * imageH).round().clamp(
      1,
      imageH * 4,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: wm.text,
        style: TextStyle(
          fontSize: 100, // Large base size for clarity
          color: wm.color,
          fontWeight: wm.fontWeight,
          fontFamily: wm.fontFamily,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final double scale = math.min(
      targetW / textPainter.width,
      targetH / textPainter.height,
    );
    final int renderW = (textPainter.width * scale).round().clamp(1, 16383);
    final int renderH = (textPainter.height * scale).round().clamp(1, 16383);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(scale);
    textPainter.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(renderW, renderH);
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;

    final baseImg = img.decodeImage(byteData.buffer.asUint8List());
    if (baseImg == null) return null;

    final result = img.Image(width: targetW, height: targetH, numChannels: 4);
    img.compositeImage(
      result,
      baseImg,
      dstX: ((targetW - renderW) / 2).round(),
      dstY: ((targetH - renderH) / 2).round(),
    );
    return result;
  }

  /// Returns a cached copy of the rasterized logo, or builds & caches it.
  /// Cloning the cached image is cheap (shallow copy of pixel data reference
  /// until a write is needed) and ensures that opacity/rotation mutations
  /// in [_buildRaster] do not corrupt the shared cache entry.
  static Future<img.Image?> _rasterizeLogo(
    LogoWatermark wm,
    int imageW,
    int imageH,
  ) async {
    final targetW = (wm.normalizedWidth * imageW).round().clamp(1, imageW * 4);
    final targetH = (wm.normalizedHeight * imageH).round().clamp(1, imageH * 4);
    final key = '${wm.imagePath}|${targetW}x$targetH';

    if (_logoCache.containsKey(key)) {
      // Return a clone so per-video opacity/rotation mutations don't corrupt cache
      return _logoCache[key]!.clone();
    }

    final built = await _buildLogoRaster(wm, imageW, imageH);
    if (built != null) {
      _logoCache[key] = built;
      return built.clone();
    }
    return null;
  }

  static final Map<String, img.Image> _sourceImageCache = {};

  static Future<img.Image?> _buildLogoRaster(
    LogoWatermark wm,
    int imageW,
    int imageH,
  ) async {
    img.Image? sourceImg = _sourceImageCache[wm.imagePath];

    if (sourceImg == null) {
      final file = File(wm.imagePath);
      if (!file.existsSync()) return null;
      sourceImg = img.decodeImage(await file.readAsBytes());
      if (sourceImg != null) {
        _sourceImageCache[wm.imagePath] = sourceImg;
      }
    }

    if (sourceImg == null) return null;

    final int targetW = (wm.normalizedWidth * imageW).round().clamp(
      1,
      imageW * 4,
    );
    final int targetH = (wm.normalizedHeight * imageH).round().clamp(
      1,
      imageH * 4,
    );

    final double fitScale = math.min(
      targetW / sourceImg.width,
      targetH / sourceImg.height,
    );
    final int fitW = (sourceImg.width * fitScale).round().clamp(1, targetW);
    final int fitH = (sourceImg.height * fitScale).round().clamp(1, targetH);

    final resized = img.copyResize(sourceImg, width: fitW, height: fitH);
    final canvas = img.Image(width: targetW, height: targetH, numChannels: 4);
    img.compositeImage(
      canvas,
      resized,
      dstX: ((targetW - fitW) / 2).round(),
      dstY: ((targetH - fitH) / 2).round(),
    );
    return canvas;
  }

  static img.Image _compositeOnto(
    img.Image base,
    img.Image wm,
    Watermark info,
  ) {
    final double cx = info.normalizedCenterX * base.width;
    final double cy = info.normalizedCenterY * base.height;
    final int dstX = (cx - wm.width / 2.0).round();
    final int dstY = (cy - wm.height / 2.0).round();

    return img.compositeImage(
      base,
      wm,
      dstX: dstX,
      dstY: dstY,
      blend: img.BlendMode.alpha,
    );
  }

  static void _applyOpacity(img.Image image, double opacity) {
    for (final pixel in image) {
      pixel.a = pixel.a * opacity;
    }
  }
}

class _OverlayCacheEntry {
  final String path;
  final int width;
  final int height;

  _OverlayCacheEntry({
    required this.path,
    required this.width,
    required this.height,
  });
}

class FfmpegOverlayDescriptor {
  final String imagePath;
  final int x;
  final int y;
  final int width;
  final int height;
  final AnimationType animationType;
  final double animationSpeed;
  final int videoW;
  final int videoH;

  const FfmpegOverlayDescriptor({
    required this.imagePath,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.animationType,
    required this.animationSpeed,
    required this.videoW,
    required this.videoH,
  });
}
