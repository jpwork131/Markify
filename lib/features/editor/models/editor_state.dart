import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:markify/shared/models/watermark.dart';

class EditorState {
  /// Raw bytes of the preview image (or extracted video thumbnail).
  final Uint8List? image;

  /// Original file path (image or video) currently previewed.
  final String? mediaPath;

  /// List of all selected file paths for batch processing.
  final List<String> mediaPaths;

  /// True if [mediaPath] points to a video file.
  final bool isVideo;

  /// Actual pixel dimensions of the original image (or video frame).
  final Size? mediaSize;

  /// Map of file path to its specific list of watermark layers.
  final Map<String, List<Watermark>> fileLayers;

  /// List of watermark layers (for the currently selected mediaPath).
  final List<Watermark> layers;

  /// The currently selected layer id.
  final String? selectedLayerId;

  /// Current zoom level of the interactive viewer.
  final double zoomLevel;

  EditorState({
    this.image,
    this.mediaPath,
    this.mediaPaths = const [],
    this.isVideo = false,
    this.mediaSize,
    this.fileLayers = const {},
    required this.layers,
    this.selectedLayerId,
    this.zoomLevel = 1.0,
  });

  EditorState copyWith({
    Uint8List? image,
    String? mediaPath,
    List<String>? mediaPaths,
    bool? isVideo,
    Size? mediaSize,
    Map<String, List<Watermark>>? fileLayers,
    List<Watermark>? layers,
    String? selectedLayerId,
    double? zoomLevel,
    // Pass explicit null to clear selectedLayerId
    bool clearSelectedLayer = false,
  }) {
    return EditorState(
      image: image ?? this.image,
      mediaPath: mediaPath ?? this.mediaPath,
      mediaPaths: mediaPaths ?? this.mediaPaths,
      isVideo: isVideo ?? this.isVideo,
      mediaSize: mediaSize ?? this.mediaSize,
      fileLayers: fileLayers ?? this.fileLayers,
      layers: layers ?? List.unmodifiable(this.layers.map((e) => e)),
      selectedLayerId: clearSelectedLayer ? null : (selectedLayerId ?? this.selectedLayerId),
      zoomLevel: zoomLevel ?? this.zoomLevel,
    );
  }

  Watermark? get selectedLayer {
    if (selectedLayerId == null) return null;
    try {
      return layers.firstWhere((layer) => layer.id == selectedLayerId);
    } catch (_) {
      return null;
    }
  }
}
