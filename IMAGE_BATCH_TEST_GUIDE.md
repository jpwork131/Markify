# Image Batch Testing Quick Guide

## Test 1: Smoke Test (20 Images, ~5 minutes)

### Setup
```dart
// Create 20 test images (1080p JPG)
// Add 3 text watermarks: Title, Company, Date

// In UI: Select all 20 images
// Configure: 3 watermarks
// Click: "Start Batch Processing"
```

### Monitor
- **Expected Time:** 4-6 minutes
- **Per-Image:** 12-18 seconds
- **No Freezes:** UI should remain responsive (scrolling, button clicks)
- **Memory:** Monitor using Windows Task Manager → Markify → Memory <300 MB
- **Workers:** Should see 2-3 concurrent workers processing

### Validation
- ✅ All 20 watermarked images created
- ✅ Zero crashes or freezes
- ✅ All images have correct watermarks applied
- ✅ Memory stays <350 MB throughout

---

## Test 2: Load Test (100 Images, ~15 minutes)

### Setup
```dart
// Create 100 test images (1080p JPG)
// Add 3 text watermarks: Title, Company, Date

// In UI: Select all 100 images
// Configure: 3 watermarks
// Click: "Start Batch Processing"
```

### Monitor
- **Expected Time:** 12-18 minutes
- **Per-Image:** 6-9 seconds
- **Concurrency:** 3-4 workers should be active
- **Memory Peak:** Should not exceed 500 MB
- **CPU:** Should stay <80% (room for UI responsiveness)

### Logs to Check
```
[QueueProcessor] Image batch detected: using aggressive chunking (50 images/chunk, 15s pause)
[MemoryGuard] Memory Guard (images): ... recommend 3-4 workers
[QueueProcessor] Adaptive tuning: concurrency 2 → 4 (images)
[QueueProcessor] Batch batch_XXXXX: enqueued 50 jobs ...
```

### Validation
- ✅ All 100 images completed
- ✅ Zero crashes or memory errors
- ✅ Processing time: 12-18 minutes (avg 7-10 sec per image)
- ✅ Memory peak: <500 MB
- ✅ Final summary: "100 succeeded, 0 failed"

---

## Test 3: Memory Stress Test (100 Images, 5 Watermarks, ~20 minutes)

### Setup
```dart
// Create 100 test images (1080p JPG)
// Add 5 watermarks: 2 logos + 3 text

// Same process as Load Test
```

### Monitor
- **Expected Time:** 18-25 minutes
- **Per-Image:** 10-15 seconds (more layers)
- **Memory Peaks:** Watch for temporary spikes >600 MB (should recover)
- **Batch Chunks:** Monitor pause times between 50-image chunks

### Logs to Check
```
[QueueProcessor] Batch summary (50-60%): memory pressure detected — pause
[MemoryGuard] System RAM low (450 MB free)
[QueueProcessor] Resuming after pause...
```

### Validation
- ✅ All images completed despite memory pressure
- ✅ No OOM crashes
- ✅ Pause-resume cycles work correctly
- ✅ Final memory usage returns to <300 MB after completion

---

## Test 4: Quality Verification (10-20 Images)

### Visual Inspection
1. Open original image in image viewer
2. Open watermarked image in image viewer
3. Side-by-side comparison:
   - ✅ Text watermarks readable and crisp
   - ✅ Logos clear and properly positioned
   - ✅ No compression artifacts visible
   - ✅ Color accuracy maintained (quality 85 JPG)

### File Size Comparison
```
Original: 2.5 MB
Watermarked (quality 85): 1.8 MB  ← Expected (85% of original)
Watermarked (quality 95): 2.1 MB  ← For comparison (default)
```

---

## Performance Benchmarking

### Run Benchmark
```dart
// Time this exact batch on your system:
// 50 images, 1080p JPG, 3 text watermarks
// Record: total time, memory peak, worker concurrency

Stopwatch sw = Stopwatch()..start();
processor.addBatch(50_image_paths, outputs, configs);
// Wait for completion...
print('Total: ${sw.elapsedMilliseconds} ms');
print('Per-image: ${sw.elapsedMilliseconds / 50} ms');
```

### Expected Results (8GB RAM System)
- **50 images:** 5-7 minutes (6-8 sec/image)
- **100 images:** 10-15 minutes (6-9 sec/image)
- **Memory peak:** <450 MB
- **Concurrency:** 3-4 workers for most of batch

### On Lower RAM (4GB System)
- **Worker count:** Likely 2 workers (more conservative)
- **Speed:** ~10 sec/image
- **Pause frequency:** More frequent memory-triggered pauses
- **Total time:** 15-20 minutes for 100 images

---

## Troubleshooting Checklist

| Symptom | Cause | Fix |
|---------|-------|-----|
| Processing <5 images/min | Low worker count | Close other apps, restart |
| App freezes mid-batch | Memory exhaustion | Use `clearAllCaches()` before batch |
| Memory grows unbounded | Cache not cleared | Verify `clearJobCaches()` is called |
| UI unresponsive | Long chunk processing | Reduce chunk size to 30 |
| Slow on first batch, fast on second | Watermark cache warming | Expected (first preloads) |

---

## Logging Reference

Enable verbose logging to diagnose issues:

```dart
// In lib/services/logger_service.dart:
static bool enableVerboseLogging = true;

// Monitor these key logs:
// [MemoryGuard] - Memory and concurrency decisions
// [QueueProcessor] - Batch progress and chunking
// [Job] - Individual job processing
// [WatermarkRenderer] - Cache management
```

---

## One-Click Test Script (Pseudo-code)

```dart
void runFullImageBatchTest() async {
  final processor = QueueProcessor();
  final testDir = '/test_data/watermark_images';
  
  // Setup
  final images = Directory(testDir).listSync()
    .whereType<File>()
    .where((f) => ['.jpg', '.jpeg', '.png'].contains(
      p.extension(f.path).toLowerCase()))
    .map((f) => f.path)
    .toList();

  LoggerService.logInfo('Starting 100-image watermark batch test');
  LoggerService.logInfo('Images: ${images.length}, System RAM: 8GB');

  // Configure watermarks
  final configs = {
    for (var img in images) img: [
      TextWatermark(text: 'Test Batch', position: Offset(0.05, 0.05)),
      TextWatermark(text: 'Company', position: Offset(0.5, 0.5)),
      TextWatermark(text: DateTime.now().toString(), position: Offset(0.05, 0.95)),
    ]
  };

  // Start batch
  final sw = Stopwatch()..start();
  final batchId = processor.addBatch(images, '/outputs', configs);

  // Monitor
  processor.summaryStream.listen((summary) {
    sw.stop();
    LoggerService.logInfo('[TEST RESULT]');
    LoggerService.logInfo('Total time: ${sw.elapsedMilliseconds / 1000} seconds');
    LoggerService.logInfo('Per-image: ${sw.elapsedMilliseconds / images.length} ms');
    LoggerService.logInfo('Result: ${summary.toString()}');
  });
}
```

---

**Next Step:** Execute Test 1 (Smoke Test) to verify basic functionality ✅
