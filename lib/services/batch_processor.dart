import 'dart:async';
import 'dart:io';
import 'package:markify/features/editor/models/editor_state.dart';
import 'package:markify/services/queue_processor.dart';
import 'package:markify/services/watermark_renderer.dart';
import 'package:markify/shared/models/watermark.dart';

/// Thin coordinator between the editor and the [QueueProcessor].
/// Responsible for:
///  1. Translating editor state into per-file watermark configs.
///  2. Pre-warming the logo cache for distinct PNG watermarks.
///  3. Reporting per-job progress and the final [BatchSummary].
class BatchProcessor {
  final List<String> paths;
  final EditorState configState;
  final String outputDir;
  final void Function(int current, int total) onProgress;
  final void Function(int success, int failed) onComplete;

  /// Optional: override concurrency (1–4 workers). Defaults to 2.
  final int maxConcurrency;

  BatchProcessor({
    required this.paths,
    required this.configState,
    required this.outputDir,
    required this.onProgress,
    required this.onComplete,
    this.maxConcurrency = 1,
  });

  Future<void> processBatch() async {
    final Map<String, List<Watermark>> configs = {};
    for (var path in paths) {
      configs[path] = configState.fileLayers[path] ?? [];
    }

    final queue = QueueProcessor();
    queue.configPool(maxConcurrency);

    // ── Pre-warm logo (PNG) cache ───────────────────────────────────────────
    // Collect all distinct watermarks used across this batch.
    // prewarmLogoCache deduplicates by path+size, so redundant calls are
    // cheap (cache hit). This avoids 100× repeated disk reads during the run.
    // We use the first video's dimensions as the representative resolution;
    // each job still passes its own dims to buildFfmpegDescriptors, so the
    // actual rendered sizes will always be correct.
    // For batches with heterogeneous resolutions, a multi-resolution prewarm
    // can be added here if needed.
    final allWatermarks = configs.values.expand((wms) => wms).toSet().toList();
    if (allWatermarks.isNotEmpty) {
      // Best-effort prewarm: skip if we can't get dimensions for the first file
      try {
        if (paths.isNotEmpty) {
          // Use a representative resolution (1920×1080) for prewarm.
          // Actual per-job dims are used during rendering — this prewarm only
          // reduces the first-hit disk I/O cost for logos.
          await WatermarkRenderer.prewarmLogoCache(
            watermarks: allWatermarks,
            videoW: 1920,
            videoH: 1080,
          );
        }
      } catch (_) {
        // Non-fatal: jobs will still build descriptors correctly on demand.
      }
    }

    // ── Enqueue and observe ─────────────────────────────────────────────────
    final batchId = queue.addBatch(paths, outputDir, configs);

    final completer = Completer<void>();
    StreamSubscription? stateSub;
    StreamSubscription? summarySub;

    // Listen for per-job progress updates
    stateSub = queue.stateStream.listen((state) {
      final allJobs = [
        ...state.pendingQueue,
        ...state.activeWorkers,
        ...state.completedJobs,
        ...state.failedJobs,
      ];

      final batchJobs =
          allJobs.where((j) => paths.contains(j.inputPath)).toList();

      final finishedCount = batchJobs
          .where((j) =>
              j.status == JobStatus.completed ||
              j.status == JobStatus.failed)
          .length;

      onProgress(finishedCount, batchJobs.length);
    });

    // Listen for the batch summary (emitted once all jobs finish)
    summarySub = queue.summaryStream.listen((summary) {
      stateSub?.cancel();
      summarySub?.cancel();
      onComplete(summary.succeeded, summary.failed);
      if (!completer.isCompleted) completer.complete();
    });

    return completer.future;
  }

  /// Kept for API compatibility — all processing is via [QueueProcessor].
  Future<File?> processSingleFile(File file, int index) async {
    throw UnimplementedError('Use QueueProcessor for all processing tasks.');
  }
}
