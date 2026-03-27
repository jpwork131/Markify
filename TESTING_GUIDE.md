# Testing Guide: Batch Watermark Processing

## Quick Start Testing

### Test 1: Freeze Prevention (10-15 Videos)
**Objective**: Verify UI remains responsive during processing

**Steps**:
1. Build and run the app
2. Select 10-15 videos (1080p, 3-5min each)
3. Apply 4-5 watermark layers (mix of text + logos)
4. Start batch processing
5. While processing:
   - Try to scroll in the UI → should be smooth (no freezes)
   - Try to cancel → should respond immediately
   - Check progress updates → should update every 200ms

**Expected Results**:
- ✅ No 30+ second freezes
- ✅ Progress displayed live
- ✅ Cancel button responds immediately
- ✅ No FFmpeg hang (timeout after 30 min max)

**Logs to Check**:
```
Worker 1 → video_1.mp4
[Job] job_xxx — status=processing progress=45.2% (1/1 workers active)
```

---

### Test 2: Memory Management (30-50 Videos)
**Objective**: Verify memory stays bounded and no OOM crashes

**Steps**:
1. Select 30-50 videos of varying lengths (2-10min)
2. Apply 4-5 layers to each
3. Monitor system memory during processing:
   ```powershell
   # Open Task Manager or run:
   Get-Process | Where {$_.Name -match "flutter|ffmpeg"} | Select Name, WorkingSet
   ```
4. Process entire batch
5. Check final log summary

**Expected Results**:
- ✅ Dart process: stays <200 MB
- ✅ Per-FFmpeg process: stays <500 MB
- ✅ System free RAM: stays >300 MB
- ✅ No OOM crashes
- ✅ All videos completed

**Logs to Check**:
```
Memory Guard: System RAM low (550 MB free). Threshold: 600 MB.
Worker 1: memory pressure detected — waiting…
Memory Guard: GOOD (750 MB free) — recommend 3 workers
Adaptive tuning: concurrency 1 → 3
```

---

### Test 3: Large Batch Chunking (80-100 Videos)
**Objective**: Verify large batches auto-chunk and progress correctly

**Steps**:
1. Select 80-100 videos
2. Start batch processing
3. Monitor logs for chunking messages
4. Wait for completion (4-6 hours)
5. Verify all completed successfully

**Expected Results**:
- ✅ Batch logged as "auto-chunking" (>15 videos)
- ✅ Chunks enqueued every ~30 seconds
- ✅ Progress visible throughout
- ✅ Concurrency scales safely (1 → 2-3 workers)
- ✅ Final summary shows 100 succeeded, 0 failed

**Logs to Check**:
```
Large batch detected (100 videos) — auto-chunking into groups of 10…
Batch xxx: enqueueing chunk (10–20 / 100)…
Batch xxx: enqueueing chunk (20–30 / 100)…
[BatchSummary] total=100 succeeded=100 failed=0 elapsed=21600s
```

---

### Test 4: Adaptive Concurrency
**Objective**: Verify worker count adapts to memory availability

**Steps**:
1. Start batch processing with 30+ videos
2. Monitor logs for concurrency changes
3. Optionally fill RAM externally to simulate pressure
4. Observe worker count changes

**Expected Results**:
- ✅ Starts at 1 worker
- ✅ Scales to 2-3 based on memory every 15 seconds
- ✅ Reduces to 1 if memory pressure detected
- ✅ Recovers to higher concurrency when memory freed

**Logs to Check**:
```
Worker pool concurrency set to 1
Memory Guard: GOOD (900 MB free) — recommend 3 workers
Adaptive tuning: concurrency 1 → 3
```

---

### Test 5: Process Timeout Recovery
**Objective**: Verify FFmpeg hang is detected and recovered

**Steps**:
1. Manually create a problematic video (corrupt codec) or modify code to hang FFmpeg
2. Start processing
3. Wait for timeout (30 minutes) OR manually trigger
4. Verify process is killed and job retries

**Expected Results**:
- ✅ After 30 min: "FFmpeg timeout after 30 minutes — killing process."
- ✅ Job retries up to 2 times
- ✅ Moves to next job after max retries exceeded
- ✅ No UI freeze

**Logs to Check**:
```
FFmpeg timeout after 30 minutes — killing process.
FAILED (attempt 1/2): video_bad.mp4 — TimeoutException: FFmpeg execution exceeded 30 minutes
FAILED (attempt 2/2): video_bad.mp4 — TimeoutException: FFmpeg execution exceeded 30 minutes
[Job] job_xxx — status=failed error=TimeoutException
```

---

## Memory Stress Test

### Setup
```powershell
# 1. Create 100 test videos (synthetic, fast generation)
$dir = "D:\test_videos_100"
mkdir $dir
for ($i=1; $i -le 100; $i++) {
  $pad = $i.ToString().PadLeft(3, '0')
  ffmpeg -f lavfi -i color=c=blue:s=1920x1080:d=300 `
         -f lavfi -i sine=f=440:d=300 `
         -pix_fmt yuv420p -y "$dir\test_video_$pad.mp4"
}

# 2. In Flutter app editor:
# - Import all 100 videos
# - Create watermark set: 2 text + 1 logo = 3 layers per video
# - Configure batch output folder

# 3. Start batch and monitor
```

### Monitoring (PowerShell Script)
```powershell
# Monitor every 10 seconds
$outfile = "C:\batch_test_memory.log"
$startTime = Get-Date

do {
  $now = Get-Date
  $elapsed = ($now - $startTime).TotalSeconds
  
  # Get process info
  $dart = Get-Process flutter -ErrorAction SilentlyContinue
  $ffmpeg = Get-Process ffmpeg -ErrorAction SilentlyContinue | Measure-Object WorkingSet -Sum
  
  # Get system memory
  $wmic = wmic OS get FreePhysicalMemory /Value | Select-String "FreePhysicalMemory"
  $freeMb = [int]($wmic -replace "[^\d]" , "") / 1024
  
  # Log
  $line = "{0:000.0}s | Dart: {1:0000}MB | FFmpeg: {2:2} processes {3:0000}MB | Free: {4:0000}MB" -f `
    $elapsed, `
    ($dart.WorkingSet / 1MB), `
    $ffmpeg.Count, `
    ($ffmpeg.Sum / 1MB), `
    $freeMb
  
  Write-Host $line
  Add-Content $outfile $line
  Start-Sleep -Seconds 10
} while ((Get-Process flutter -ErrorAction SilentlyContinue) -and $elapsed -lt 86400)

Write-Host "Log saved to: $outfile"
```

### Success Criteria
- ✅ Dart process: <250 MB peak
- ✅ FFmpeg process (per job): <550 MB peak
- ✅ System free RAM: stays >200 MB (warning at 400 MB)
- ✅ No OOM crash
- ✅ All 100 videos complete
- ✅ Total time: 4-8 hours (depending on other system load)

---

## Performance Benchmarks

### Before Implementation
- 10 videos: crashes or freezes
- 15 videos: likely crash
- Concurrency: 1 (slow)
- Memory: unbounded growth

### After Implementation
- Expected for 100 × 1080p 5-min videos with 4-5 layers:

| System | Time | Concurrency | Peak Memory |
|--------|------|-------------|-------------|
| 8GB, i7, SSD | 4-6 hours | 2-3 | <600 MB |
| 16GB, i9, NVMe | 3-4 hours | 3-4 | <700 MB |
| 4GB (low-end) | 8-10 hours | 1 | <400 MB |

---

## Troubleshooting

### Issue: "App still freezes during batch"
**Check**:
- [ ] Latest code deployed?
- [ ] UI.Future.delayed(Duration.zero) calls present?
- [ ] FFmpeg time=[HH:MM:SS] progress being parsed?
- [ ] onProgress callback being invoked?

**Fix**: Ensure all changes from Phase 1 are applied.

### Issue: "Crashes after 20 videos"
**Check**:
- [ ] clearJobCaches() being called after each job?
- [ ] Memory Guard threshold at 600 MB?
- [ ] Concurrency limiting based on memory?

**Fix**: Verify Phase 3 implementation. Check logs for "Memory Guard" messages.

### Issue: "Only 1 worker, processes very slowly"
**Check**:
- [ ] _startWorkerPool() periodic timer running?
- [ ] recommendedConcurrency() returning >1?
- [ ] System has >1200 MB free RAM?

**Fix**: Check logs for Memory Guard recommendations. Try closing other apps to free RAM.

### Issue: "FFmpeg process eating >2GB memory"
**Check**:
- [ ] Large video file (>500MB)?
- [ ] Many layers (>10)?
- [ ] Complex animations enabled?

**Fix**: Reduce video bitrate, reduce layers, or disable animations for that file. checkProcessMemorySafe() will pause if detected.

---

## Automated Test Checklist

Run before each release:

- [ ] **Syntax Check**: `flutter analyze lib/services/` — 0 errors
- [ ] **Small Batch**: 5 videos × 2 layers → completes in <10 min, no crash
- [ ] **Medium Batch**: 20 videos × 4 layers → completes in <2 hours, UI responsive
- [ ] **Cold Start**: App closed between batches → memory resets
- [ ] **Hot Reload**: UI updates during processing
- [ ] **Cancel**: Batch cancel works mid-processing
- [ ] **Retry**: Failed video retries and completes
- [ ] **Logs**: All critical events logged ([Job], [Memory Guard], etc.)

---

## Support & Next Steps

**Next phases**:
1. Production deployment (1 week monitoring)
2. Collect telemetry on real batches
3. Optimize chunk size based on user hardware
4. Add text-glyph caching for repeated watermarks
5. Implement remote worker support for massive batches

**Contact**: Refer to code comments marked with **ADDED** or **FIX** for implementation details.

---

**Last Updated**: March 27, 2026
