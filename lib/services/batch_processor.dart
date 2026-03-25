import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:markify/features/editor/models/editor_state.dart';
import 'package:markify/services/video_watermark_service.dart';
import 'package:markify/services/watermark_renderer.dart';
import 'package:markify/services/queue_processor.dart';
import 'package:markify/shared/models/watermark.dart';

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
    final Map<String, List<Watermark>> configs = {};
    for (var path in paths) {
      configs[path] = configState.fileLayers[path] ?? [];
    }

    final queue = QueueProcessor();
    queue.addToQueue(
      paths: paths,
      outputDir: outputDir,
      taskConfigs: configs,
    );

    // To maintain existing behavior of processBatch awaiting completion,
    // we listen to the progress stream until this specific batch is completed.
    // However, the queue is centralized and shared.
    
    final completer = Completer<void>();
    StreamSubscription? subscription;
    
    subscription = queue.progressStream.listen((progress) {
      // Find tasks belonging to THIS batch
      final batchTasks = progress.tasks.where((t) => paths.contains(t.inputPath)).toList();
      final finishedCount = batchTasks.where((t) => t.status == TaskStatus.completed || t.status == TaskStatus.failed).length;
      final successCount = batchTasks.where((t) => t.status == TaskStatus.completed).length;
      final failedCount = batchTasks.where((t) => t.status == TaskStatus.failed).length;
      
      onProgress(finishedCount, batchTasks.length);
      
      if (finishedCount == batchTasks.length && batchTasks.isNotEmpty) {
        subscription?.cancel();
        onComplete(successCount, failedCount);
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  // Not strictly needed anymore as it's handled by QueueProcessor, 
  // but kept for compatibility if needed.
  Future<File?> processSingleFile(File file, int index) async {
    // This could just call QueueProcessor with a single item
    // For now we'll keep it as it is or proxy it.
    throw UnimplementedError("Use QueueProcessor for all processing tasks.");
  }
}


