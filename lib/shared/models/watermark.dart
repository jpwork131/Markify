import 'package:flutter/material.dart';

enum AnimationType {
  none,
  leftToRight,
  topToBottom,
  diagonal,
  bounce,
  circular,
  zigZag,
}

/// Single source of truth for all watermark properties.
///
/// ALL positional/size values are normalized to [0.0, 1.0] relative to the
/// *rendered image bounds* (NOT the screen/canvas widget size).
///
/// - [normalizedCenterX] / [normalizedCenterY]: center of the watermark.
///   0.0 = left/top edge of image, 1.0 = right/bottom edge of image.
/// - [normalizedWidth] / [normalizedHeight]: size relative to image dimensions.
///   1.0 = full image width/height.
/// - [rotation]: in degrees, clockwise positive.
/// - [opacity]: 0.0 (transparent) to 1.0 (opaque).
abstract class Watermark {
  final String id;

  /// Center X as fraction of rendered image width. Range: [0, 1].
  final double normalizedCenterX;

  /// Center Y as fraction of rendered image height. Range: [0, 1].
  final double normalizedCenterY;

  /// Width as fraction of rendered image width.
  final double normalizedWidth;

  /// Height as fraction of rendered image height.
  final double normalizedHeight;

  final double rotation; // degrees
  final double opacity;
  final bool isVisible;

  // Animation support
  final AnimationType animationType;
  final double animationSpeed;

  const Watermark({
    required this.id,
    required this.normalizedCenterX,
    required this.normalizedCenterY,
    required this.normalizedWidth,
    required this.normalizedHeight,
    this.rotation = 0.0,
    this.opacity = 0.8,
    this.isVisible = true,
    this.animationType = AnimationType.none,
    this.animationSpeed = 1.0,
  });

  Watermark copyWith({
    String? id,
    double? normalizedCenterX,
    double? normalizedCenterY,
    double? normalizedWidth,
    double? normalizedHeight,
    double? rotation,
    double? opacity,
    bool? isVisible,
    AnimationType? animationType,
    double? animationSpeed,
  });
}

class TextWatermark extends Watermark {
  final String text;
  final double fontSize; // stored in normalized units (fraction of image height)
  final Color color;
  final FontWeight fontWeight;
  final String? fontFamily;

  const TextWatermark({
    required super.id,
    required super.normalizedCenterX,
    required super.normalizedCenterY,
    required super.normalizedWidth,
    required super.normalizedHeight,
    super.rotation,
    super.opacity,
    super.isVisible,
    super.animationType,
    super.animationSpeed,
    required this.text,
    this.fontSize = 0.05, // 5% of image height by default
    this.color = Colors.white,
    this.fontWeight = FontWeight.bold,
    this.fontFamily,
  });

  @override
  TextWatermark copyWith({
    String? id,
    double? normalizedCenterX,
    double? normalizedCenterY,
    double? normalizedWidth,
    double? normalizedHeight,
    double? rotation,
    double? opacity,
    bool? isVisible,
    AnimationType? animationType,
    double? animationSpeed,
    String? text,
    double? fontSize,
    Color? color,
    FontWeight? fontWeight,
    String? fontFamily,
  }) {
    return TextWatermark(
      id: id ?? this.id,
      normalizedCenterX: normalizedCenterX ?? this.normalizedCenterX,
      normalizedCenterY: normalizedCenterY ?? this.normalizedCenterY,
      normalizedWidth: normalizedWidth ?? this.normalizedWidth,
      normalizedHeight: normalizedHeight ?? this.normalizedHeight,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      isVisible: isVisible ?? this.isVisible,
      animationType: animationType ?? this.animationType,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      fontWeight: fontWeight ?? this.fontWeight,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }
}

class LogoWatermark extends Watermark {
  final String imagePath;

  const LogoWatermark({
    required super.id,
    required super.normalizedCenterX,
    required super.normalizedCenterY,
    required super.normalizedWidth,
    required super.normalizedHeight,
    super.rotation,
    super.opacity,
    super.isVisible,
    super.animationType,
    super.animationSpeed,
    required this.imagePath,
  });

  @override
  LogoWatermark copyWith({
    String? id,
    double? normalizedCenterX,
    double? normalizedCenterY,
    double? normalizedWidth,
    double? normalizedHeight,
    double? rotation,
    double? opacity,
    bool? isVisible,
    AnimationType? animationType,
    double? animationSpeed,
    String? imagePath,
  }) {
    return LogoWatermark(
      id: id ?? this.id,
      normalizedCenterX: normalizedCenterX ?? this.normalizedCenterX,
      normalizedCenterY: normalizedCenterY ?? this.normalizedCenterY,
      normalizedWidth: normalizedWidth ?? this.normalizedWidth,
      normalizedHeight: normalizedHeight ?? this.normalizedHeight,
      rotation: rotation ?? this.rotation,
      opacity: opacity ?? this.opacity,
      isVisible: isVisible ?? this.isVisible,
      animationType: animationType ?? this.animationType,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      imagePath: imagePath ?? this.imagePath,
    );
  }
}
