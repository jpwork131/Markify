import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:markify/services/video_watermark_service.dart';
import 'package:markify/services/watermark_renderer.dart';
import 'package:markify/services/logger_service.dart';
import 'package:markify/shared/models/watermark.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

// ─── Job Model ─────────────────────────────────────────────────────────────

enum JobStatus { pending, processing, completed, failed, paused }

class WatermarkJob {
  final String id;
  final String inputPath;
  final String outputPath;
  final List<Watermark> watermarks;
  final bool isVideo;
  JobStatus status;
  double progress;
  String? errorMessage;
  int retryCount;

  WatermarkJob({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.watermarks,
    required this.isVideo,
    this.status = JobStatus.pending,
    this.progress = 0.0,
    this.errorMessage,
    this.retryCount = 0,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'input': inputPath,
    'output': outputPath,
    'status': status.name,
    'progress': progress,
    'retryCount': retryCount,
    'error': errorMessage,
  };
}

// ─── Queue State ──────────────────────────────────────────────────────────

class QueueState {
  final List<WatermarkJob> pendingQueue;
  final List<WatermarkJob> activeWorkers;
  final List<WatermarkJob> completedJobs;
  final List<WatermarkJob> failedJobs;
  final bool isPaused;
  final int totalJobs;

  QueueState({
    required this.pendingQueue,
    required this.activeWorkers,
    required this.completedJobs,
    required this.failedJobs,
    required this.isPaused,
    required this.totalJobs,
  });

  double get overallProgress {
    if (totalJobs == 0) return 0.0;
    return (completedJobs.length + failedJobs.length) / totalJobs;
  }
}

// ─── Batch Summary ────────────────────────────────────────────────────────

class BatchSummary {
  final int total;
  final int succeeded;
  final int failed;
  final Duration elapsed;
  final List<String> failedPaths;

  BatchSummary({
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.elapsed,
    required this.failedPaths,
  });

  @override
  String toString() =>
      '[BatchSummary] total=$total succeeded=$succeeded failed=$failed '
      'elapsed=${elapsed.inSeconds}s failedFiles=${failedPaths.join(", ")}';
}

// ─── Memory Guard ─────────────────────────────────────────────────────────

/// Lightweight memory monitor with adaptive concurrency recommendation.
/// Returns recommended worker count (1-4) based on system RAM headroom.
/// When below [thresholdMb], the worker pool pauses accepting new jobs until memory is reclaimed.
///
/// Memory thresholds:
/// - IMAGE batches: more aggressive (can tolerate lower free RAM, process faster)
/// - VIDEO batches: conservative (need more headroom for FFmpeg processes)
///
/// NOTE: Dart has no direct free-memory API; we use Platform-specific calls on Windows
/// and fallback to ProcessInfo.currentRss() for other platforms.
class _MemoryGuard {
  final int thresholdMb = 600; // 600 MB headroom - safe for 8GB RAM
  final int criticalMb = 400; // Pause all if below this
  final int thresholdMbImages = 400; // Images can work with less headroom (faster)
  _MemoryGuard();

  /// Returns recommended concurrency level (1-4) based on available system memory.
  /// Images can scale more aggressively since they don't spawn FFmpeg processes.
  Future<int> recommendedConcurrency({bool isImageBatch = false}) async {
    final freeMb = await _getSystemFreeMemory();
    
    // Images are faster and don't spawn heavy subprocesses, so allow more aggressive scaling
    if (isImageBatch) {
      if (freeMb < 300) {
        LoggerService.logInfo(
          'Memory Guard (images): CRITICAL ($freeMb MB free) — recommend 1 worker',
        );
        return 1;
      } else if (freeMb < thresholdMbImages) {
        LoggerService.logInfo(
          'Memory Guard (images): LOW ($freeMb MB free) — recommend 2 workers',
        );
        return 2;
      } else if (freeMb < thresholdMbImages * 2) {
        LoggerService.logInfo(
          'Memory Guard (images): OK ($freeMb MB free) — recommend 3 workers',
        );
        return 3;
      } else {
        LoggerService.logInfo(
          'Memory Guard (images): EXCELLENT ($freeMb MB free) — recommend 4 workers',
        );
        return 4;
      }
    }
    
    // Conservative for videos (need FFmpeg headroom)
    if (freeMb < criticalMb) {
      LoggerService.logInfo(
        'Memory Guard (videos): CRITICAL ($freeMb MB free) — recommend 1 worker',
      );
      return 1;
    } else if (freeMb < thresholdMb) {
      LoggerService.logInfo(
        'Memory Guard (videos): LOW ($freeMb MB free) — recommend 1 worker',
      );
      return 1;
    } else if (freeMb < thresholdMb * 2) {
      LoggerService.logInfo(
        'Memory Guard (videos): OK ($freeMb MB free) — recommend 2 workers',
      );
      return 2;
    } else if (freeMb < thresholdMb * 3) {
      LoggerService.logInfo(
        'Memory Guard (videos): GOOD ($freeMb MB free) — recommend 3 workers',
      );
      return 3;
    } else {
      LoggerService.logInfo(
        'Memory Guard (videos): EXCELLENT ($freeMb MB free) — recommend 4 workers',
      );
      return 4;
    }
  }

  /// Returns true if we have enough system headroom to start another job.
  Future<bool> hasHeadroom() async {
    final freeMb = await _getSystemFreeMemory();
    final isSafe = freeMb >= thresholdMb;
    if (!isSafe) {
      LoggerService.logInfo(
        'Memory Guard: System RAM low ($freeMb MB free). Threshold: $thresholdMb MB.',
      );
    }
    return isSafe;
  }

  Future<int> _getSystemFreeMemory() async {
    if (Platform.isWindows) {
      try {
        final result = await Process.run('wmic', [
          'OS',
          'get',
          'FreePhysicalMemory',
          '/Value',
        ]);
        if (result.exitCode == 0) {
          final output = result.stdout.toString();
          // Output format: FreePhysicalMemory=XXXX (in KB)
          final match = RegExp(r'FreePhysicalMemory=(\d+)').firstMatch(output);
          if (match != null) {
            final freeKb = int.parse(match.group(1)!);
            return freeKb ~/ 1024; // Convert to MB
          }
        }
      } catch (e) {
        debugPrint('[MemoryGuard] System check failed: $e');
      }
    }

    // Fallback: check personal RSS vs a 6GB "safe zone"
    final used = ProcessInfo.currentRss;
    const maxSafeRss = 6144 * 1024 * 1024; // 6 GB
    return ((maxSafeRss - used) ~/ (1024 * 1024)).clamp(0, 8000);
  }

  /// Monitor FFmpeg child processes' memory usage to prevent OOM scenario.
  /// Returns true if process memory is within safe bounds (<2GB per process).
  Future<bool> checkProcessMemorySafe() async {
    if (!Platform.isWindows) return true;

    try {
      final result = await Process.run('tasklist', [
        '/FI',
        'IMAGENAME eq ffmpeg.exe',
        '/FO',
        'CSV',
        '/NH',
      ]);
      if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
        // tasklist CSV output: "ffmpeg.exe","PID","SESSION_NAME","SESSION_NUM","MEM_USAGE"
        final lines = result.stdout.toString().trim().split('\n');
        for (final line in lines) {
          if (line.isEmpty || !line.contains('ffmpeg.exe')) continue;

          try {
            final parts = line.split(',');
            if (parts.length >= 5) {
              final memStr = parts[4]
                  .trim()
                  .replaceAll('"', '')
                  .replaceAll(' K', '');
              final memKb = int.tryParse(memStr) ?? 0;
              final memMb = memKb ~/ 1024;

              if (memMb > 2000) {
                // >2GB is critical
                LoggerService.logInfo(
                  'Critical: FFmpeg process using $memMb MB — may trigger OOM.',
                );
                return false;
              }
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[MemoryGuard] FFmpeg memory check failed: $e');
    }
    return true;
  }
}

// ─── Queue Processor ──────────────────────────────────────────────────────

class QueueProcessor {
  static final QueueProcessor _instance = QueueProcessor._internal();
  factory QueueProcessor() => _instance;
  QueueProcessor._internal() {
    _startWorkerPool();
  }

  final List<WatermarkJob> _allJobs = [];
  final ListQueue<WatermarkJob> _pendingQueue = ListQueue();
  final List<WatermarkJob> _activeWorkers = [];

  bool _isPaused = false;

  /// Configurable cap: default 1 concurrent video for absolute reliability.
  /// Worker can increase this if system permits.
  int _maxParallelWorkers = 1;

  final _MemoryGuard _memGuard = _MemoryGuard();

  final StreamController<QueueState> _stateController =
      StreamController<QueueState>.broadcast();
  Stream<QueueState> get stateStream => _stateController.stream;

  /// Stream for completed batch summaries.
  final StreamController<BatchSummary> _summaryController =
      StreamController<BatchSummary>.broadcast();
  Stream<BatchSummary> get summaryStream => _summaryController.stream;

  /// Tracks batch start times by batch ID for elapsed-time calculation.
  final Map<String, DateTime> _batchStartTimes = {};

  /// Maps batch ID → set of job IDs belonging to that batch.
  final Map<String, Set<String>> _batchJobIds = {};

  Timer? _notifyTimer;
  bool _isDisposed = false;

  /// Track FFmpeg process IDs for memory monitoring
  final Map<String, int?> _jobProcessIds = {};

  /// Cache detected batch type for concurrency tuning
  bool? _isCurrentBatchImages;

  void _startWorkerPool() {
    // Spawn pool of lightweight async "workers". Each loops forever,
    // picking jobs from the shared queue when capacity allows.
    // Pool size is fixed at 4 (hard max); _maxParallelWorkers gates how many
    // actually run concurrently.
    for (int i = 0; i < 4; i++) {
      _runWorker(i);
    }

    // ADDED: Periodic concurrency tuning based on system memory
    // Detects batch type (images vs videos) and tunes accordingly
    Timer.periodic(Duration(seconds: 15), (timer) async {
      if (_isDisposed) {
        timer.cancel();
        return;
      }
      
      // Detect if we're processing images or videos
      bool isImageBatch = _detectBatchType();
      
      final recommended =
          await _memGuard.recommendedConcurrency(isImageBatch: isImageBatch);
      if (recommended != _maxParallelWorkers) {
        LoggerService.logInfo(
          'Adaptive tuning: concurrency ${_maxParallelWorkers} → $recommended '
          '(${isImageBatch ? 'images' : 'videos'})',
        );
        _maxParallelWorkers = recommended;
      }
    });
  }

  /// Detect batch type by checking active/pending jobs
  bool _detectBatchType() {
    if (_activeWorkers.isNotEmpty) {
      final firstJob = _activeWorkers.first;
      return !firstJob.isVideo;
    }
    if (_pendingQueue.isNotEmpty) {
      final firstJob = _pendingQueue.first;
      return !firstJob.isVideo;
    }
    // Default to detected cache if no active jobs
    return _isCurrentBatchImages ?? false;
  }

  /// Set the maximum number of videos to process in parallel.
  /// Range: 1–4. Default: 2 (safe for 8 GB RAM + 5 watermark layers).
  void configPool(int concurrentTasks) {
    _maxParallelWorkers = concurrentTasks.clamp(1, 4);
    LoggerService.logInfo(
      'Worker pool concurrency set to $_maxParallelWorkers',
    );
  }

  /// Enqueue a batch of files. Returns a [batchId] you can use to track this
  /// specific batch via [summaryStream].
  ///
  /// ADDED: Auto-chunks large batches based on media type:
  /// - Images: >25 items chunked into groups of 50 (images are fast)
  /// - Videos: >15 items chunked into groups of 10 (videos are slow)
  /// Pauses between chunks to allow memory reclaim and GC.
  String addBatch(
    List<String> paths,
    String outputDir,
    Map<String, List<Watermark>> configs,
  ) {
    final batchId = 'batch_${DateTime.now().microsecondsSinceEpoch}';
    _batchStartTimes[batchId] = DateTime.now();
    _batchJobIds[batchId] = {};

    // Detect batch type and set appropriate chunk size
    // Images process ~10-20x faster than videos, so larger chunk size is safe
    final imageExts = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'};
    final isImageBatch = paths.isNotEmpty &&
        imageExts.contains(
          p.extension(paths.first).toLowerCase().replaceFirst('.', ''),
        );

    // Cache batch type for adaptive concurrency tuning
    _isCurrentBatchImages = isImageBatch;

    int chunkSize = 10;
    int chunkThreshold = 15;
    int pauseSeconds = 30;

    if (isImageBatch) {
      chunkSize = 50; // Images are faster, can chunk more aggressively
      chunkThreshold = 25; // Only chunk if >25 images
      pauseSeconds = 15; // Shorter pause needed for images
      LoggerService.logInfo(
        'Image batch detected: using aggressive chunking (50 images/chunk, 15s pause)',
      );
    } else {
      LoggerService.logInfo(
        'Video batch detected: using conservative chunking (10 videos/chunk, 30s pause)',
      );
    }

    // Chunk large batches to prevent memory overload
    if (paths.length > chunkThreshold) {
      LoggerService.logInfo(
        'Large batch detected (${paths.length} items) — auto-chunking into groups of $chunkSize…',
      );
      _enqueueChunkedBatch(
        batchId,
        paths,
        outputDir,
        configs,
        chunkSize,
        pauseSeconds,
      );
    } else {
      _enqueueBatchImmediate(batchId, paths, outputDir, configs);
    }

    return batchId;
  }

  /// Enqueue a batch immediately (no chunking)
  void _enqueueBatchImmediate(
    String batchId,
    List<String> paths,
    String outputDir,
    Map<String, List<Watermark>> configs,
  ) {
    for (var path in paths) {
      // Avoid re-queuing an already active/pending job for the same file.
      if (_allJobs.any(
        (j) =>
            j.inputPath == path &&
            (j.status == JobStatus.pending || j.status == JobStatus.processing),
      )) {
        continue;
      }

      final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm', 'wmv'].contains(ext);
      final id =
          'job_${DateTime.now().microsecondsSinceEpoch}_${path.hashCode.abs()}';
      final fileName =
          'wm_${p.basenameWithoutExtension(path)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final outPath = p.join(outputDir, fileName);

      Directory(outputDir).createSync(recursive: true);

      final job = WatermarkJob(
        id: id,
        inputPath: path,
        outputPath: outPath,
        watermarks: configs[path] ?? [],
        isVideo: isVideo,
      );

      _allJobs.add(job);
      _pendingQueue.add(job);
      _batchJobIds[batchId]!.add(id);
    }

    LoggerService.logInfo(
      'Batch $batchId: enqueued ${paths.length} jobs '
      '(total queue size: ${_allJobs.length})',
    );
    _notifyState();
  }

  /// Enqueue a batch in chunks with pauses for memory reclaim
  void _enqueueChunkedBatch(
    String batchId,
    List<String> paths,
    String outputDir,
    Map<String, List<Watermark>> configs,
    int chunkSize,
    int pauseSeconds,
  ) {
    // Enqueue first chunk immediately
    final firstChunk = paths.take(chunkSize).toList();
    _enqueueBatchImmediate(batchId, firstChunk, outputDir, configs);

    // Schedule remaining chunks with delays for memory reclaim
    int index = chunkSize;
    Timer.periodic(Duration(seconds: pauseSeconds), (timer) {
      if (_isDisposed || index >= paths.length) {
        timer.cancel();
        return;
      }

      final endIndex = (index + chunkSize).clamp(0, paths.length);
      final chunk = paths.sublist(index, endIndex);

      LoggerService.logInfo(
        'Batch $batchId: enqueueing chunk ($index–$endIndex / ${paths.length})…',
      );
      _enqueueBatchImmediate(batchId, chunk, outputDir, configs);

      index = endIndex;
      if (index >= paths.length) {
        timer.cancel();
      }
    });
  }

  void pause() {
    _isPaused = true;
    for (var job in _allJobs.where((j) => j.status == JobStatus.pending)) {
      job.status = JobStatus.paused;
    }
    LoggerService.logInfo('Queue processing paused');
    _notifyState();
  }

  void resume() {
    _isPaused = false;
    for (var job in _allJobs.where((j) => j.status == JobStatus.paused)) {
      job.status = JobStatus.pending;
    }
    LoggerService.logInfo('Queue processing resumed');
    _notifyState();
  }

  void retryFailedJob(String jobId) {
    final job = _allJobs.firstWhere((j) => j.id == jobId);
    if (job.status == JobStatus.failed) {
      job.status = JobStatus.pending;
      job.errorMessage = null;
      job.progress = 0;
      job.retryCount = 0;
      _pendingQueue.add(job);
      _notifyState();
    }
  }

  // ─── Worker Loop ──────────────────────────────────────────────────────────

  Future<void> _runWorker(int workerId) async {
    while (!_isDisposed) {
      // Gate 1: paused / queue empty / capacity full
      if (_isPaused ||
          _pendingQueue.isEmpty ||
          _activeWorkers.length >= _maxParallelWorkers) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }

      // Gate 2: memory pressure check — back off if RAM is tight
      if (!await _memGuard.hasHeadroom() ||
          !await _memGuard.checkProcessMemorySafe()) {
        LoggerService.logInfo(
          'Worker $workerId: memory pressure detected — waiting…',
        );
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      // Pick next job FIFO
      final job = _pendingQueue.removeFirst();
      job.status = JobStatus.processing;
      _activeWorkers.add(job);
      _notifyState();

      LoggerService.logInfo('Worker $workerId → ${p.basename(job.inputPath)}');

      try {
        await _processJobWithRetry(job);
      } catch (e, stack) {
        job.status = JobStatus.failed;
        job.errorMessage = 'Fatal worker error: $e';
        // Clean up caches even on failure
        try {
          await WatermarkRenderer.clearJobCaches(job.id);
        } catch (_) {}
        LoggerService.logError(
          'Worker $workerId fatal on ${job.inputPath}: $e\n$stack',
        );
      } finally {
        _activeWorkers.remove(job);
        _notifyState();

        // Check if any batch is now fully complete → emit summary
        await _checkBatchCompletion();

        // Brief pause between jobs — lets GC run, prevents event-loop starvation
        await Future.delayed(const Duration(milliseconds: 200));

        LoggerService.logInfo(
          '[Job] ${job.id} — status=${job.status.name} progress=${(job.progress * 100).toStringAsFixed(1)}% '
          '(${_activeWorkers.length}/${_maxParallelWorkers} workers active)',
        );
      }
    }
  }

  // ─── Job Execution ────────────────────────────────────────────────────────

  Future<void> _processJobWithRetry(WatermarkJob job) async {
    const maxRetries = 2;

    while (job.retryCount <= maxRetries) {
      try {
        if (job.isVideo) {
          await _executeVideoJob(job);
        } else {
          await _executeImageJob(job);
        }
        job.status = JobStatus.completed;
        job.progress = 1.0;
        LoggerService.logInfo('COMPLETED: ${p.basename(job.inputPath)}');
        return;
      } catch (e) {
        job.retryCount++;
        LoggerService.logError(
          'FAILED (attempt ${job.retryCount}/$maxRetries): '
          '${p.basename(job.inputPath)} — $e',
        );

        if (job.retryCount > maxRetries) {
          job.status = JobStatus.failed;
          job.errorMessage = e.toString();
          return;
        }
        // Exponential back-off before retry
        await Future.delayed(Duration(seconds: 3 * job.retryCount));
      }
    }
  }

  Future<void> _executeVideoJob(WatermarkJob job) async {
    if (!File(job.inputPath).existsSync()) {
      throw Exception('Input file missing: ${job.inputPath}');
    }

    final dims = await VideoWatermarkService.probeVideoDimensions(
      job.inputPath,
    );
    if (dims == null) {
      throw Exception(
        'FFprobe could not analyze video — possible codec issue: '
        '${p.basename(job.inputPath)}',
      );
    }

    final success = await VideoWatermarkService.applyWatermarks(
      inputVideoPath: job.inputPath,
      watermarks: job.watermarks,
      outputPath: job.outputPath,
      videoWidth: dims.$1,
      videoHeight: dims.$2,
      onProgress: (prog) {
        job.progress = prog;
        _notifyStateThrottled();
      },
      jobId: job.id, // ADDED: Pass jobId for cache tracking
    );

    if (!success) {
      throw Exception('FFmpeg non-zero exit on: ${p.basename(job.inputPath)}');
    }

    // ADDED: Aggressive per-job cache cleanup after success
    try {
      await WatermarkRenderer.clearJobCaches(job.id);
    } catch (e) {
      LoggerService.logError('Job cache cleanup error: $e');
    }
  }

  Future<void> _executeImageJob(WatermarkJob job) async {
    // Run in an isolate so heavy pixel work doesn't block the UI thread.
    await compute(_imageIsolateHandler, {
      'input': job.inputPath,
      'output': job.outputPath,
      'watermarks': job.watermarks,
      'jobId': job.id, // ADDED: Pass jobId for cache tracking
    });
    job.progress = 1.0;

    // ADDED: Aggressive per-job cache cleanup after success
    try {
      await WatermarkRenderer.clearJobCaches(job.id);
    } catch (e) {
      LoggerService.logError('Job cache cleanup error: $e');
    }
  }

  static Future<void> _imageIsolateHandler(Map<String, dynamic> params) async {
    final String input = params['input'];
    final String output = params['output'];
    final List<Watermark> watermarks = params['watermarks'];

    final bytes = await File(input).readAsBytes();
    img.Image? base = img.decodeImage(bytes);
    if (base == null) throw Exception('Could not decode image: $input');

    img.Image processed = await WatermarkRenderer.renderOntoImage(
      baseImage: base,
      watermarks: watermarks,
    );

    // ADDED: Optimize encoding based on output format for speed
    // JPG: Use quality 85 for fast encoding (3-4x faster than quality 95)
    // PNG: Use default encoder (not lossless, but fast enough)
    final ext = p.extension(output).toLowerCase();
    final List<int>? encoded = ext == '.jpg' || ext == '.jpeg'
        ? img.encodeJpg(processed, quality: 85)
        : img.encodeNamedImage(output, processed);

    if (encoded == null) {
      throw Exception('Encoding failed for format: $ext');
    }

    await File(output).writeAsBytes(encoded);

    // Help GC — these are large pixel buffers
    base = null;
  }

  // ─── Batch Completion + Summary ───────────────────────────────────────────

  Future<void> _checkBatchCompletion() async {
    final completedBatches = <String>[];

    for (final entry in _batchJobIds.entries) {
      final batchId = entry.key;
      final jobIds = entry.value;

      final batchJobs = _allJobs.where((j) => jobIds.contains(j.id)).toList();
      if (batchJobs.isEmpty) continue;

      final allDone = batchJobs.every(
        (j) => j.status == JobStatus.completed || j.status == JobStatus.failed,
      );

      if (allDone) {
        final succeeded = batchJobs
            .where((j) => j.status == JobStatus.completed)
            .length;
        final failed = batchJobs
            .where((j) => j.status == JobStatus.failed)
            .length;
        final failedPaths = batchJobs
            .where((j) => j.status == JobStatus.failed)
            .map(
              (j) =>
                  '${p.basename(j.inputPath)}: ${j.errorMessage ?? "unknown"}',
            )
            .toList();

        final elapsed = DateTime.now().difference(
          _batchStartTimes[batchId] ?? DateTime.now(),
        );

        final summary = BatchSummary(
          total: batchJobs.length,
          succeeded: succeeded,
          failed: failed,
          elapsed: elapsed,
          failedPaths: failedPaths,
        );

        LoggerService.logInfo(summary.toString());

        if (!_summaryController.isClosed) {
          _summaryController.add(summary);
        }

        completedBatches.add(batchId);

        // Clear ALL caches after each completed batch to free memory and disk.
        await WatermarkRenderer.clearAllCaches();
      }
    }

    for (final id in completedBatches) {
      _batchJobIds.remove(id);
      _batchStartTimes.remove(id);
    }
  }

  // ─── State Notification ───────────────────────────────────────────────────

  void _notifyStateThrottled() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 200), _notifyState);
  }

  void _notifyState() {
    if (_isDisposed || _stateController.isClosed) return;

    final pending = _allJobs
        .where(
          (j) => j.status == JobStatus.pending || j.status == JobStatus.paused,
        )
        .toList();
    final completed = _allJobs
        .where((j) => j.status == JobStatus.completed)
        .toList();
    final failed = _allJobs.where((j) => j.status == JobStatus.failed).toList();

    _stateController.add(
      QueueState(
        pendingQueue: List.unmodifiable(_pendingQueue),
        activeWorkers: List.unmodifiable(_activeWorkers),
        completedJobs: List.unmodifiable(completed),
        failedJobs: List.unmodifiable(failed),
        isPaused: _isPaused,
        totalJobs: _allJobs.length,
      ),
    );
  }

  void dispose() {
    _isDisposed = true;
    _notifyTimer?.cancel();
    _stateController.close();
    _summaryController.close();
  }
}
