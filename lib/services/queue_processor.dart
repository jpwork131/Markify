import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  int retryCount;

  ProcessingTask({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.watermarks,
    required this.isVideo,
    this.status = TaskStatus.pending,
    this.progress = 0.0,
    this.error,
    this.retryCount = 0,
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

/// A "Very Strong" Queue Processor using a Worker-Pool pattern for maximum stability.
class QueueProcessor {
  static final QueueProcessor _instance = QueueProcessor._internal();
  factory QueueProcessor() => _instance;
  QueueProcessor._internal() {
    _startWorkers();
  }

  final List<ProcessingTask> _allTasks = [];
  final ListQueue<ProcessingTask> _pendingQueue = ListQueue();
  
  bool _isPaused = false;
  int _maxConcurrency = 2; // Default to 2 for balanced performance/stability
  
  final StreamController<QueueProgress> _controller = StreamController<QueueProgress>.broadcast();
  Stream<QueueProgress> get progressStream => _controller.stream;

  Timer? _notifyTimer;
  bool _isDisposed = false;

  void _startWorkers() {
    // We launch workers that will pull from the queue
    for (int i = 0; i < 3; i++) { // Support up to 3 workers max
      _workerLoop(i);
    }
  }

  void setMaxConcurrency(int limit) {
    _maxConcurrency = limit.clamp(1, 4);
    debugPrint('[QueueProcessor] Max Concurrency set to $_maxConcurrency');
  }

  void addToQueue({
    required List<String> paths,
    required String outputDir,
    required Map<String, List<Watermark>> taskConfigs,
  }) {
    for (var path in paths) {
      if (_allTasks.any((t) => t.inputPath == path && (t.status == TaskStatus.pending || t.status == TaskStatus.processing))) {
        continue;
      }

      final ext = p.extension(path).toLowerCase().replaceAll('.', '');
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
      final id = 'task_${DateTime.now().microsecondsSinceEpoch}_${path.hashCode}';
      final outputFileName = 'watermarked_${p.basenameWithoutExtension(path)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final outputPath = p.join(outputDir, outputFileName);

      final dir = Directory(outputDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final task = ProcessingTask(
        id: id,
        inputPath: path,
        outputPath: outputPath,
        watermarks: taskConfigs[path] ?? [],
        isVideo: isVideo,
      );
      
      _allTasks.add(task);
      _pendingQueue.add(task);
    }
    _throttleNotify();
  }

  void pause() {
    _isPaused = true;
    _throttleNotify();
  }

  void resume() {
    _isPaused = false;
    _throttleNotify();
  }

  void clearQueue() {
    _pendingQueue.clear();
    // Only remove pending tasks from the full list
    _allTasks.removeWhere((t) => t.status == TaskStatus.pending);
    _throttleNotify();
  }

  /// The core worker loop — very stable, no recursion, pulls tasks as needed.
  Future<void> _workerLoop(int workerId) async {
    while (!_isDisposed) {
      if (_isPaused || _pendingQueue.isEmpty || _activeCount() >= _maxConcurrency) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final task = _pendingQueue.removeFirst();
      task.status = TaskStatus.processing;
      _throttleNotify();

      try {
        await _executeWithRetry(task);
      } catch (e) {
        debugPrint('[QueueProcessor] Worker $workerId uncaught error: $e');
        task.status = TaskStatus.failed;
        task.error = 'Uncaught system error: $e';
      } finally {
        _throttleNotify();
        // Force a tiny pause and GC hint after every task completion
        _releaseTaskMemory();
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  int _activeCount() {
    return _allTasks.where((t) => t.status == TaskStatus.processing).length;
  }

  Future<void> _executeWithRetry(ProcessingTask task) async {
    const maxRetries = 2; // Total 3 attempts
    
    while (task.retryCount <= maxRetries) {
      try {
        if (task.isVideo) {
          await _processVideoTask(task);
        } else {
          await _processImageTaskThrottled(task);
        }
        task.status = TaskStatus.completed;
        task.progress = 1.0;
        return;
      } catch (e) {
        task.retryCount++;
        debugPrint('[QueueProcessor] Task Error (${task.retryCount}/$maxRetries): ${task.inputPath} - $e');
        
        if (task.retryCount > maxRetries) {
          task.status = TaskStatus.failed;
          task.error = e.toString();
          return;
        }
        await Future.delayed(Duration(seconds: 2 * task.retryCount));
      }
    }
  }

  Future<void> _processVideoTask(ProcessingTask task) async {
    // Ensure file exists before starting
    if (!File(task.inputPath).existsSync()) throw Exception('Source file missing');

    final dims = await VideoWatermarkService.probeVideoDimensions(task.inputPath);
    if (dims == null) throw Exception('Video probe failed (corrupt file or ffmpeg missing)');

    final success = await VideoWatermarkService.applyWatermarks(
      inputVideoPath: task.inputPath,
      watermarks: task.watermarks,
      outputPath: task.outputPath,
      videoWidth: dims.$1,
      videoHeight: dims.$2,
      onProgress: (p) {
        task.progress = p;
        _throttleNotify();
      },
    );

    if (!success) throw Exception('FFmpeg process returned error code');
  }

  /// Uses a dedicated semaphore logic to ensure images don't flood memory even if concurrency is high.
  static int _imageIsolateCount = 0;
  Future<void> _processImageTaskThrottled(ProcessingTask task) async {
    while (_imageIsolateCount >= 2) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _imageIsolateCount++;
    try {
      await compute(_imageWorker, {
        'input': task.inputPath,
        'output': task.outputPath,
        'watermarks': task.watermarks,
      });
      task.progress = 1.0;
    } finally {
      _imageIsolateCount--;
    }
  }

  static Future<void> _imageWorker(Map<String, dynamic> params) async {
    final String inputPath = params['input'];
    final String outputPath = params['output'];
    final List<Watermark> watermarks = params['watermarks'];

    final file = File(inputPath);
    if (!file.existsSync()) throw Exception('Input file GONE');

    final bytes = await file.readAsBytes();
    img.Image? baseImg = img.decodeImage(bytes);
    if (baseImg == null) throw Exception('Decode failed');

    img.Image? processedImg = await WatermarkRenderer.renderOntoImage(
      baseImage: baseImg,
      watermarks: watermarks,
    );

    final encoded = img.encodePng(processedImg);
    await File(outputPath).writeAsBytes(encoded);
    
    // Explicit cleanup
    baseImg = null;
    processedImg = null;
  }

  void _throttleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), _notify);
  }

  void _notify() {
    if (_isDisposed || _controller.isClosed) return;
    
    final completed = _allTasks.where((t) => t.status == TaskStatus.completed).length;
    final failed = _allTasks.where((t) => t.status == TaskStatus.failed).length;
    final processing = _allTasks.where((t) => t.status == TaskStatus.processing).length;

    _controller.add(QueueProgress(
      total: _allTasks.length,
      completed: completed,
      failed: failed,
      processing: processing,
      tasks: List.unmodifiable(_allTasks),
      isPaused: _isPaused,
    ));
  }

  void _releaseTaskMemory() {
    // Force GC awareness on native side
    SystemChannels.platform.invokeMethod('SystemSound.play', 'click');
  }

  void dispose() {
    _isDisposed = true;
    _notifyTimer?.cancel();
    _controller.close();
  }
}
