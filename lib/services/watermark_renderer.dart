import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:markify/shared/models/watermark.dart';

/// Unified rendering engine — single source of truth for all watermark output.
class WatermarkRenderer {
  // ── Public API ─────────────────────────────────────────────────────────────

  /// Composites all visible [watermarks] onto [baseImage] in-place.
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
    }
    return result;
  }

  /// Saves each visible watermark as a PNG and returns descriptors
  /// that tell FFmpeg where to overlay each PNG onto the video.
  static Future<List<FfmpegOverlayDescriptor>> buildFfmpegDescriptors({
    required List<Watermark> watermarks,
    required int videoW,
    required int videoH,
    required String tempDir,
  }) async {
    try {
      final descriptors = <FfmpegOverlayDescriptor>[];
      int counter = 0;

      for (final wm in watermarks) {
        if (!wm.isVisible) continue;
        
        // Yield to keep UI smooth during heavy rasterization
        await Future.delayed(Duration.zero);
        
        final wmImg = await _buildRaster(wm, videoW, videoH);
        if (wmImg == null) continue;

        final path = '$tempDir/wm_overlay_$counter.png';
        await File(path).writeAsBytes(img.encodePng(wmImg));

        // Calculate Top-Left position in video pixel space
        final double cx = wm.normalizedCenterX * videoW;
        final double cy = wm.normalizedCenterY * videoH;
        final int x = (cx - wmImg.width / 2.0).round();
        final int y = (cy - wmImg.height / 2.0).round();

        descriptors.add(FfmpegOverlayDescriptor(
          imagePath: path,
          x: x,
          y: y,
          width: wmImg.width,
          height: wmImg.height,
          animationType: wm.animationType,
          animationSpeed: wm.animationSpeed,
          videoW: videoW,
          videoH: videoH,
        ));
        counter++;
      }
      return descriptors;
    } catch (e) {
      debugPrint('[WatermarkRenderer] Build descriptors error: $e');
      rethrow;
    }
  }


  // ── Raster builder ─────────────────────────────────────────────────────────

  static Future<img.Image?> _buildRaster(Watermark wm, int imageW, int imageH) async {
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

  static Future<img.Image?> _rasterizeText(TextWatermark wm, int imageW, int imageH) async {
    final int targetW = (wm.normalizedWidth * imageW).round().clamp(1, imageW * 4);
    final int targetH = (wm.normalizedHeight * imageH).round().clamp(1, imageH * 4);

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

    final double scale = math.min(targetW / textPainter.width, targetH / textPainter.height);
    final int renderW = (textPainter.width * scale).round().clamp(1, 16383);
    final int renderH = (textPainter.height * scale).round().clamp(1, 16383);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
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

  static Future<img.Image?> _rasterizeLogo(LogoWatermark wm, int imageW, int imageH) async {
    final file = File(wm.imagePath);
    if (!file.existsSync()) return null;
    final sourceImg = img.decodeImage(await file.readAsBytes());
    if (sourceImg == null) return null;

    final int targetW = (wm.normalizedWidth * imageW).round().clamp(1, imageW * 4);
    final int targetH = (wm.normalizedHeight * imageH).round().clamp(1, imageH * 4);

    final double fitScale = math.min(targetW / sourceImg.width, targetH / sourceImg.height);
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

  static img.Image _compositeOnto(img.Image base, img.Image wm, Watermark info) {
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
