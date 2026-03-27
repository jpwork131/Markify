import 'dart:io';
import 'dart:async';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:markify/shared/models/watermark.dart';
import 'package:markify/services/watermark_renderer.dart';
import 'package:markify/services/logger_service.dart';
import 'package:path/path.dart' as p;

class VideoWatermarkService {
  static String get _ffmpegPath {
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final local = p.join(exeDir, 'ffmpeg.exe');
      if (File(local).existsSync()) return local;

      // Project root for dev
      final root = p.join(Directory.current.path, 'ffmpeg.exe');
      if (File(root).existsSync()) return root;

      return 'ffmpeg.exe'; // Fallback to PATH
    }
    return 'ffmpeg';
  }

  static String get _ffprobePath {
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final local = p.join(exeDir, 'ffprobe.exe');
      if (File(local).existsSync()) return local;

      final root = p.join(Directory.current.path, 'ffprobe.exe');
      if (File(root).existsSync()) return root;

      return 'ffprobe.exe';
    }
    return 'ffprobe';
  }

  static Future<bool> applyWatermarks({
    required String inputVideoPath,
    required List<Watermark> watermarks,
    required String outputPath,
    required int videoWidth,
    required int videoHeight,
    Function(double)? onProgress,
    String? jobId,
  }) async {
    final visibleWatermarks = watermarks.where((wm) => wm.isVisible).toList();
    if (visibleWatermarks.isEmpty) {
      LoggerService.logInfo('No visible watermarks, copying file.');
      await File(inputVideoPath).copy(outputPath);
      return true;
    }

    final tempDir = await getTemporaryDirectory();
    // Use a unique session directory per job to avoid cross-job file collisions.
    final sessionPath = p.join(
      tempDir.path,
      'markify_session_${DateTime.now().microsecondsSinceEpoch}',
    );
    await Directory(sessionPath).create(recursive: true);

    try {
      final descriptors = await WatermarkRenderer.buildFfmpegDescriptors(
        watermarks: visibleWatermarks,
        videoW: videoWidth,
        videoH: videoHeight,
        tempDir: sessionPath,
        jobId: jobId, // ADDED: Pass jobId for cache tracking
      );

      final cmd = _buildFilterComplexArgs(
        inputVideoPath,
        descriptors,
        outputPath,
      );
      LoggerService.logInfo(
        'FFmpeg start: ${p.basename(inputVideoPath)} — ${descriptors.length} layers',
      );

      if (Platform.isWindows) {
        final duration = await getVideoDuration(inputVideoPath);
        return await _runFfmpegCli(cmd, duration, onProgress);
      }
      return await _runFfmpegKit(cmd, onProgress);
    } catch (e, stack) {
      LoggerService.logError('Video processing failed: $e\n$stack');
      return false;
    } finally {
      // Always clean up the per-job temp directory immediately.
      try {
        if (Directory(sessionPath).existsSync()) {
          await Directory(sessionPath).delete(recursive: true);
        }
      } catch (e) {
        debugPrint('[VideoWatermarkService] Temp-dir cleanup error: $e');
      }
    }
  }

  static List<String> _buildFilterComplexArgs(
    String input,
    List<FfmpegOverlayDescriptor> descriptors,
    String output,
  ) {
    // Note: On Windows Process.start, DO NOT quote arguments in the list.
    // The OS handles quoting if they contain spaces.
    final args = <String>['-y', '-i', input];

    for (var d in descriptors) {
      args.addAll(['-i', d.imagePath]);
    }

    final filter = StringBuffer();
    String lastOutput = '[0:v]';

    for (int i = 0; i < descriptors.length; i++) {
      final d = descriptors[i];
      filter.write('[${i + 1}:v]scale=${d.width}:${d.height}[scaled$i];');
    }

    for (int i = 0; i < descriptors.length; i++) {
      final d = descriptors[i];
      final scaled = '[scaled$i]';
      final out = '[v${i + 1}]';
      String overlayExpr = _getOverlayExpression(d);
      filter.write('$lastOutput$scaled overlay=$overlayExpr$out');
      if (i < descriptors.length - 1) filter.write(';');
      lastOutput = out;
    }

    if (descriptors.isNotEmpty) filter.write(';');
    const String finalVideoOutput = '[final_vid]';
    filter.write('${lastOutput}format=yuv420p$finalVideoOutput');

    args.addAll(['-filter_complex', filter.toString()]);
    args.addAll(['-map', finalVideoOutput]);
    args.addAll(['-map', '0:a?', '-c:a', 'copy']);
    args.addAll([
      '-c:v', 'libx264',
      '-preset',
      'fast', // Changed from 'ultrafast' for better quality/speed balance
      '-crf', '20', // Changed from '23' to preserve quality on 1080p
      '-threads', '0',
      '-sn',
      output,
    ]);

    return args;
  }

  static String _getOverlayExpression(FfmpegOverlayDescriptor d) {
    if (d.animationType == AnimationType.none) {
      return '${d.x}:${d.y}';
    }
    final double speed = d.animationSpeed;
    final String xBase = '${d.x}';
    final String yBase = '${d.y}';

    switch (d.animationType) {
      case AnimationType.leftToRight:
        return "x='-w+mod(t*W*$speed/5,W+w)':y=$yBase";
      case AnimationType.topToBottom:
        return "x=$xBase:y='-h+mod(t*H*$speed/5,H+h)'";
      case AnimationType.diagonal:
        return "x='-w+mod(t*W*$speed/5,W+w)':y='-h+mod(t*H*$speed/5,H+h)'";
      case AnimationType.bounce:
        return "x='abs(W-w)*abs(sin(t*$speed))':y='abs(H-h)*abs(cos(t*$speed))'";
      case AnimationType.circular:
        return "x='$xBase+100*cos(t*$speed)':y='$yBase+100*sin(t*$speed)'";
      case AnimationType.zigZag:
        return "x='-w+mod(t*W*$speed/5,W+w)':y='$yBase+50*sin(t*${speed * 3})'";
      default:
        return '$xBase:$yBase';
    }
  }

  static Future<bool> _runFfmpegKit(
    List<String> cmd,
    Function(double)? onProgress,
  ) async {
    final session = await FFmpegKit.executeWithArguments(cmd);
    final returnCode = await session.getReturnCode();
    return ReturnCode.isSuccess(returnCode);
  }

  /// Runs FFmpeg as a subprocess and streams stderr for progress updates.
  ///
  /// FIX: Both stdout AND stderr are drained concurrently via separate futures.
  /// Without draining stdout, the pipe buffer fills up on large outputs and
  /// the process hangs indefinitely — a classic subprocess deadlock on Windows.
  ///
  /// ADDED: 30-minute timeout with graceful process termination. If FFmpeg hangs,
  /// we kill the process and return failure instead of blocking the worker.
  static Future<bool> _runFfmpegCli(
    List<String> args,
    Duration? duration,
    Function(double)? onProgress,
  ) async {
    Process? process;
    try {
      final exe = _ffmpegPath;
      process = await Process.start(exe, args);

      // --- DRAIN stdout unconditionally to prevent pipe-buffer deadlock ---
      final stdoutFuture = process.stdout.drain<void>();

      // --- Parse stderr for progress reporting ---
      final stderrFuture = () async {
        if (onProgress != null && duration != null) {
          final totalSeconds = duration.inMilliseconds / 1000.0;
          // FFmpeg progress format: 'time=00:00:23.45'
          final timeRegex = RegExp(r'time=(\d+):(\d+):(\d+\.\d+)');

          await for (final chunk in process!.stderr.transform(
            const SystemEncoding().decoder,
          )) {
            final matches = timeRegex.allMatches(chunk);
            if (matches.isNotEmpty) {
              final match =
                  matches.last; // Use the latest timestamp in this chunk
              final h = int.parse(match.group(1)!);
              final m = int.parse(match.group(2)!);
              final s = double.parse(match.group(3)!);
              final currentSeconds = h * 3600 + m * 60 + s;
              final progress = (currentSeconds / totalSeconds).clamp(0.0, 0.99);
              onProgress(progress);
            }
          }
        } else {
          await process!.stderr.drain<void>();
        }
      }();

      // Wait for all streams and the process to finish together WITH TIMEOUT
      final timeoutDuration = Duration(minutes: 30);
      await Future.wait([stdoutFuture, stderrFuture]).timeout(
        timeoutDuration,
        onTimeout: () async {
          LoggerService.logError(
            'FFmpeg timeout after 30 minutes — killing process.',
          );
          process!.kill();
          throw TimeoutException(
            'FFmpeg execution exceeded 30 minutes',
            timeoutDuration,
          );
        },
      );
      final exitCode = await process.exitCode.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          LoggerService.logError(
            'FFmpeg process exit code read timeout — killing process.',
          );
          process!.kill();
          return -1;
        },
      );
      if (exitCode == 0) onProgress?.call(1.0);
      return exitCode == 0;
    } catch (e) {
      LoggerService.logError('FFmpeg CLI failed: $e');
      // Best-effort kill if still running
      try {
        process?.kill();
      } catch (_) {}
      return false;
    }
  }

  static Future<(int, int)?> probeVideoDimensions(String path) async {
    if (Platform.isWindows) {
      final probe = _ffprobePath;
      try {
        final res = await Process.run(probe, [
          '-v',
          'error',
          '-select_streams',
          'v:0',
          '-show_entries',
          'stream=width,height',
          '-of',
          'csv=s=x:p=0',
          path,
        ]);
        if (res.exitCode == 0) {
          final parts = res.stdout.toString().trim().split('x');
          if (parts.length == 2) {
            return (int.parse(parts[0]), int.parse(parts[1]));
          }
        }
      } catch (e) {
        LoggerService.logError('FFprobe dimensions failed: $e');
      }
    } else {
      try {
        final session = await FFmpegKit.execute('-i "$path"');
        final output = await session.getOutput();
        final match = RegExp(r'(\d{2,5})x(\d{2,5})').firstMatch(output ?? '');
        if (match != null)
          return (int.parse(match.group(1)!), int.parse(match.group(2)!));
      } catch (_) {}
    }
    return null;
  }

  static Future<Duration?> getVideoDuration(String path) async {
    final probe = _ffprobePath;
    try {
      final res = await Process.run(probe, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        path,
      ]);
      if (res.exitCode == 0) {
        final seconds = double.tryParse(res.stdout.toString().trim());
        if (seconds != null) {
          return Duration(milliseconds: (seconds * 1000).toInt());
        }
      }
    } catch (e) {
      LoggerService.logError('Duration probe failed: $e');
    }
    return null;
  }
}
