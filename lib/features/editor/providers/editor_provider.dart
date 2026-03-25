import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:markify/features/editor/models/editor_state.dart';
import 'package:markify/shared/models/watermark.dart';

// ─── Intents ──────────────────────────────────────────────────────────────────
class UndoIntent extends Intent { const UndoIntent(); }
class RedoIntent extends Intent { const RedoIntent(); }
class DeleteIntent extends Intent { const DeleteIntent(); }

// ─── History ──────────────────────────────────────────────────────────────────
class HistoryManager {
  final List<EditorState> _undoStack = [];
  final List<EditorState> _redoStack = [];
  static const int _maxHistory = 50;

  void save(EditorState state) {
    _undoStack.add(state);
    _redoStack.clear();
    if (_undoStack.length > _maxHistory) {
      _undoStack.removeAt(0);
    }
  }

  EditorState? undo(EditorState current) {
    if (_undoStack.isEmpty) return null;
    _redoStack.add(current);
    return _undoStack.removeLast();
  }

  EditorState? redo(EditorState current) {
    if (_redoStack.isEmpty) return null;
    _undoStack.add(current);
    return _redoStack.removeLast();
  }
}

// ─── Provider ─────────────────────────────────────────────────────────────────
final editorProvider = StateNotifierProvider<EditorNotifier, EditorState>((ref) {
  return EditorNotifier();
});

// ─── Notifier ─────────────────────────────────────────────────────────────────
class EditorNotifier extends StateNotifier<EditorState> {
  final HistoryManager _history = HistoryManager();
  static const _uuid = Uuid();

  EditorNotifier() : super(EditorState(layers: []));

  // ── Undo / Redo ─────────────────────────────────────────────────────────────
  void undo() {
    final prev = _history.undo(state);
    if (prev != null) state = prev;
  }

  void redo() {
    final next = _history.redo(state);
    if (next != null) state = next;
  }

  // ── Media Loading ────────────────────────────────────────────────────────────
  void setMedia(Uint8List previewBytes, List<String> paths) async {
    _history.save(state);

    if (paths.isEmpty) return;
    final path = paths.first;

    final ext = path.split('.').last.toLowerCase();
    final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
    Uint8List? thumbnailBytes;

    if (isVideo) {
      try {
        final tempDir = await getTemporaryDirectory();
        final thumbPath =
            '${tempDir.path}/thumb_${DateTime.now().millisecondsSinceEpoch}.jpg';
        
        bool thumbSuccess = false;

        // Try System FFmpeg (CLI) first on Windows as a fallback for MissingPluginException
        if (Platform.isWindows) {
          try {
            final process = await Process.run('ffmpeg.exe', [
              '-y', '-i', path, '-vframes', '1', '-q:v', '2', thumbPath
            ]);
            thumbSuccess = process.exitCode == 0;
          } catch (_) { /* System FFmpeg missing */ }
        }

        // Try FFmpegKit Plugin 
        if (!thumbSuccess && !Platform.isWindows) {
          try {
            final session = await FFmpegKit.execute('-y -i "$path" -vframes 1 -q:v 2 "$thumbPath"');
            final returnCode = await session.getReturnCode();
            thumbSuccess = ReturnCode.isSuccess(returnCode);
          } catch (_) { /* Plugin missing or crashed */ }
        }
        
        if (thumbSuccess) {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            thumbnailBytes = await thumbFile.readAsBytes();
          }
        }
      } catch (e) {
        debugPrint('[EditorNotifier] Hybrid thumbnail generation failed: $e');
      }
    } else {
      thumbnailBytes = previewBytes;
    }

    Size mediaSize = const Size(1280, 720); // Default fallback
    if (thumbnailBytes != null) {
      try {
        final codec = await ui.instantiateImageCodec(thumbnailBytes);
        final frame = await codec.getNextFrame();
        mediaSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
      } catch (e) {
        debugPrint('[EditorNotifier] Image decoding failed: $e');
        if (!isVideo) return; 
      }
    }

    state = EditorState(
      image: thumbnailBytes,
      mediaPath: path,
      mediaPaths: paths,
      isVideo: isVideo,
      mediaSize: mediaSize,
      layers: [], // Initially empty, will populate as user edits
      fileLayers: { for (var p in paths) p : [] },
    );
  }

  void switchPreviewFile(String path) async {
    final state_ = state;
    if (state_.mediaPath == path) return;

    // 1. Save current layers to fileLayers map
    final currentPath = state_.mediaPath;
    final Map<String, List<Watermark>> updatedFileLayers = Map.from(state_.fileLayers);
    if (currentPath != null) {
      updatedFileLayers[currentPath] = state_.layers;
    }

    // 2. Load context for the new file
    final ext = path.split('.').last.toLowerCase();
    final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
    Uint8List? thumbnailBytes;

    if (isVideo) {
      try {
        final tempDir = await getTemporaryDirectory();
        final thumbPath =
            '${tempDir.path}/thumb_${DateTime.now().millisecondsSinceEpoch}.jpg';
        
        bool thumbSuccess = false;
        if (Platform.isWindows) {
          try {
            final process = await Process.run('ffmpeg.exe', [
              '-y', '-i', path, '-vframes', '1', '-q:v', '2', thumbPath
            ]);
            thumbSuccess = process.exitCode == 0;
          } catch (_) { }
        }
        
        if (thumbSuccess) {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            thumbnailBytes = await thumbFile.readAsBytes();
          }
        }
      } catch (e) {
        debugPrint('[EditorNotifier] Switch thumbnail failed: $e');
      }
    } else {
      thumbnailBytes = await File(path).readAsBytes();
    }

    Size mediaSize = const Size(1280, 720);
    if (thumbnailBytes != null) {
      try {
        final codec = await ui.instantiateImageCodec(thumbnailBytes);
        final frame = await codec.getNextFrame();
        mediaSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
      } catch (e) { }
    }

    final List<Watermark> layersFromCache = updatedFileLayers[path] ?? [];

    state = state.copyWith(
      image: thumbnailBytes,
      mediaPath: path,
      isVideo: isVideo,
      mediaSize: mediaSize,
      fileLayers: updatedFileLayers,
      layers: layersFromCache,
      clearSelectedLayer: true,
    );
  }

  // ── Add Layers ───────────────────────────────────────────────────────────────
  void addTextWatermark() {
    _history.save(state);
    final id = _uuid.v4();

    final layer = TextWatermark(
      id: id,
      normalizedCenterX: 0.5,
      normalizedCenterY: 0.5,
      normalizedWidth: 0.4,  // 40% of image width
      normalizedHeight: 0.08, // 8% of image height
      text: 'Watermark',
      fontSize: 0.06, // 6% of image height → consistent at all resolutions
    );

    final updatedLayers = [...state.layers, layer];
    final Map<String, List<Watermark>> updatedFileLayers = Map.from(state.fileLayers);
    if (state.mediaPath != null) {
      updatedFileLayers[state.mediaPath!] = updatedLayers;
    }

    state = state.copyWith(
      layers: updatedLayers,
      selectedLayerId: id,
      fileLayers: updatedFileLayers,
    );
  }

  void addLogoWatermark(String imagePath) {
    _history.save(state);
    final id = _uuid.v4();

    final layer = LogoWatermark(
      id: id,
      normalizedCenterX: 0.5,
      normalizedCenterY: 0.5,
      normalizedWidth: 0.3,   // 30% of image width
      normalizedHeight: 0.15, // 15% of image height
      imagePath: imagePath,
    );

    final updatedLayers = [...state.layers, layer];
    final Map<String, List<Watermark>> updatedFileLayers = Map.from(state.fileLayers);
    if (state.mediaPath != null) {
      updatedFileLayers[state.mediaPath!] = updatedLayers;
    }

    state = state.copyWith(
      layers: updatedLayers,
      selectedLayerId: id,
      fileLayers: updatedFileLayers,
    );
  }

  // ── Update / Delete ──────────────────────────────────────────────────────────
  void selectLayer(String? id) {
    state = state.copyWith(selectedLayerId: id, clearSelectedLayer: id == null);
  }

  void saveHistory() => _history.save(state);

  void updateLayer(Watermark updatedLayer, {bool snap = false, bool saveToHistory = true}) {
    Watermark finalLayer = updatedLayer;

    if (snap) {
      const snapThreshold = 0.01;
      double cx = finalLayer.normalizedCenterX;
      double cy = finalLayer.normalizedCenterY;
      if ((cx - 0.5).abs() < snapThreshold) cx = 0.5;
      if ((cy - 0.5).abs() < snapThreshold) cy = 0.5;
      finalLayer = finalLayer.copyWith(normalizedCenterX: cx, normalizedCenterY: cy);
    }

    if (saveToHistory) _history.save(state);
    
    final updatedLayers = state.layers
        .map((l) => l.id == finalLayer.id ? finalLayer : l)
        .toList();
    
    final Map<String, List<Watermark>> updatedFileLayers = Map.from(state.fileLayers);
    if (state.mediaPath != null) {
      updatedFileLayers[state.mediaPath!] = updatedLayers;
    }

    state = state.copyWith(
      layers: updatedLayers,
      selectedLayerId: finalLayer.id,
      fileLayers: updatedFileLayers,
    );
  }

  void deleteLayer(String id) {
    _history.save(state);
    final updatedLayers = state.layers.where((l) => l.id != id).toList();

    final Map<String, List<Watermark>> updatedFileLayers = Map.from(state.fileLayers);
    if (state.mediaPath != null) {
      updatedFileLayers[state.mediaPath!] = updatedLayers;
    }

    state = state.copyWith(
      layers: updatedLayers,
      selectedLayerId: state.selectedLayerId == id ? null : state.selectedLayerId,
      clearSelectedLayer: state.selectedLayerId == id,
      fileLayers: updatedFileLayers,
    );
  }

  void reorderLayers(int oldIndex, int newIndex) {
    _history.save(state);
    final layers = [...state.layers];
    if (oldIndex < newIndex) newIndex -= 1;
    final item = layers.removeAt(oldIndex);
    layers.insert(newIndex, item);

    final Map<String, List<Watermark>> updatedFileLayers = Map.from(state.fileLayers);
    if (state.mediaPath != null) {
      updatedFileLayers[state.mediaPath!] = layers;
    }

    state = state.copyWith(layers: layers, fileLayers: updatedFileLayers);
  }

  void setZoom(double zoom) {
    state = state.copyWith(zoomLevel: zoom);
  }

  void updateMediaSize(Size size) {
    state = state.copyWith(mediaSize: size);
  }

  void applyCurrentToAll() {
    _history.save(state);
    final Map<String, List<Watermark>> updatedFileLayers = {};
    for (var path in state.mediaPaths) {
      updatedFileLayers[path] = List.from(state.layers.map((l) => l.copyWith(id: _uuid.v4())));
    }
    state = state.copyWith(fileLayers: updatedFileLayers);
  }

  void reset() {
    state = EditorState(layers: []);
  }
}
