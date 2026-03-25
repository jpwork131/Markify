import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:markify/services/video_watermark_service.dart';
import 'package:markify/services/watermark_renderer.dart';
import 'package:markify/shared/models/watermark.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

enum TaskStatus { pending, processing, completed, failed }

class ProcessingTask {
  final String id;
  final String inputPath;
  final String outputPath;
  final List<Watermark> watermarks;
  final bool isVideo;
  TaskStatus status;
  double progress;
  String? error;

  ProcessingTask({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.watermarks,
    required this.isVideo,
    this.status = TaskStatus.pending,
    this.progress = 0.0,
    this.error,
  });
}

class QueueProgress {
  final int total;
  final int completed;
  final int failed;
  final int processing;
  final List<ProcessingTask> tasks;
  final bool isPaused;

  QueueProgress({
    required this.total,
    required this.completed,
    required this.failed,
    required this.processing,
    required this.tasks,
    required this.isPaused,
  });

  double get overallProgress => total == 0 ? 0.0 : (completed + failed) / total;
}

class QueueProcessor {
  static final QueueProcessor _instance = QueueProcessor._internal();
  factory QueueProcessor() => _instance;
  QueueProcessor._internal();

  final List<ProcessingTask> _queue = [];
  final Set<String> _activeTaskIds = {};
  bool _isPaused = false;
  int _maxConcurrency = 1;

  final StreamController<QueueProgress> _controller = StreamController<QueueProgress>.broadcast();
  Stream<QueueProgress> get progressStream => _controller.stream;

  void setMaxConcurrency(int limit) {
    _maxConcurrency = limit;
  }

  void addToQueue({
    required List<String> paths,
    required String outputDir,
    required Map<String, List<Watermark>> taskConfigs,
  }) {
    for (var path in paths) {
      final ext = p.extension(path).toLowerCase().replaceAll('.', '');
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
      final id = '${DateTime.now().microsecondsSinceEpoch}_${path.hashCode}';
      final outputFileName = 'watermarked_${p.basenameWithoutExtension(path)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final outputPath = p.join(outputDir, outputFileName);

      // Ensure directory exists
      final dir = Directory(outputDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final task = ProcessingTask(
        id: id,
        inputPath: path,
        outputPath: outputPath,
        watermarks: taskConfigs[path] ?? [],
        isVideo: isVideo,
      );
      _queue.add(task);
    }
    _notify();
    _processNext();
  }

  void pause() {
    _isPaused = true;
    _notify();
  }

  void resume() {
    _isPaused = false;
    _notify();
    _processNext();
  }

  void clearQueue() {
    _queue.removeWhere((t) => t.status == TaskStatus.pending);
    _notify();
  }

  void _notify() {
    final completed = _queue.where((t) => t.status == TaskStatus.completed).length;
    final failed = _queue.where((t) => t.status == TaskStatus.failed).length;
    final processing = _queue.where((t) => t.status == TaskStatus.processing).length;

    _controller.add(QueueProgress(
      total: _queue.length,
      completed: completed,
      failed: failed,
      processing: processing,
      tasks: List.unmodifiable(_queue),
      isPaused: _isPaused,
    ));
  }

  void _processNext() {
    if (_isPaused) return;
    if (_activeTaskIds.length >= _maxConcurrency) return;

    final nextTasks = _queue.where((t) => t.status == TaskStatus.pending).toList();
    if (nextTasks.isEmpty) return;

    final nextTask = nextTasks.first;

    _activeTaskIds.add(nextTask.id);
    nextTask.status = TaskStatus.processing;
    _notify();

    _executeTask(nextTask, retryCount: 1).then((_) {
      _activeTaskIds.remove(nextTask.id);
      _notify();
      _processNext();
    });

    if (_activeTaskIds.length < _maxConcurrency) {
      _processNext();
    }
  }

  Future<void> _executeTask(ProcessingTask task, {int retryCount = 0}) async {
    try {
      if (task.isVideo) {
        await _processVideoTask(task);
      } else {
        await _processImageTask(task);
      }
      task.status = TaskStatus.completed;
      task.progress = 1.0;
    } catch (e) {
      debugPrint('[QueueProcessor] Task failed: ${task.inputPath} - $e');
      if (retryCount > 0) {
        debugPrint('[QueueProcessor] Retrying task: ${task.inputPath}');
        await _executeTask(task, retryCount: retryCount - 1);
      } else {
        task.status = TaskStatus.failed;
        task.error = e.toString();
      }
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _processVideoTask(ProcessingTask task) async {
    final dims = await VideoWatermarkService.probeVideoDimensions(task.inputPath);
    if (dims == null) throw Exception('Could not probe video dimensions');

    final success = await VideoWatermarkService.applyWatermarks(
      inputVideoPath: task.inputPath,
      watermarks: task.watermarks,
      outputPath: task.outputPath,
      videoWidth: dims.$1,
      videoHeight: dims.$2,
      onProgress: (p) {
        task.progress = p;
        _notify();
      },
    );

    if (!success) throw Exception('FFmpeg processing failed');
  }

  Future<void> _processImageTask(ProcessingTask task) async {
    // 1. Read bytes
    final bytes = await File(task.inputPath).readAsBytes();
    
    // 2. Decode
    img.Image? baseImg = img.decodeImage(bytes);
    if (baseImg == null) throw Exception('Could not decode image');

    // 3. Render
    img.Image? processedImg = await WatermarkRenderer.renderOntoImage(
      baseImage: baseImg,
      watermarks: task.watermarks,
    );

    // 4. Encode and save
    final encoded = img.encodePng(processedImg);
    await File(task.outputPath).writeAsBytes(encoded);
    
    // Explicitly nullify to help GC
    baseImg = null;
    processedImg = null;
    task.progress = 1.0;
  }

  void dispose() {
    _controller.close();
  }
}
