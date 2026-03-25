import 'dart:io';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:markify/shared/models/watermark.dart';
import 'package:markify/services/watermark_renderer.dart';

/// Applies watermarks to a video file using a Hybrid Pipeline:
/// 1. On Windows: Tries to use system FFmpeg (via CLI) if the flutter plugin is broken.
/// 2. On Mobile/Others: Uses FFmpegKit plugin.
class VideoWatermarkService {
  static String get _ffmpegPath {
    if (Platform.isWindows) {
      final appDir = File(Platform.resolvedExecutable).parent.path;
      final local = '$appDir\\ffmpeg.exe';
      if (File(local).existsSync()) return local;
      final root = '${Directory.current.path}\\ffmpeg.exe';
      if (File(root).existsSync()) return root;
      return 'ffmpeg.exe';
    }
    return 'ffmpeg';
  }

  static String get _ffprobePath {
    if (Platform.isWindows) {
      final appDir = File(Platform.resolvedExecutable).parent.path;
      final local = '$appDir\\ffprobe.exe';
      if (File(local).existsSync()) return local;
      final root = '${Directory.current.path}\\ffprobe.exe';
      if (File(root).existsSync()) return root;
      return 'ffprobe.exe';
    }
    return 'ffprobe';
  }

  /// Entry point for video watermarking.
  static Future<bool> applyWatermarks({
    required String inputVideoPath,
    required List<Watermark> watermarks,
    required String outputPath,
    required int videoWidth,
    required int videoHeight,
    Function(double)? onProgress,
  }) async {
    final visibleWatermarks = watermarks.where((wm) => wm.isVisible).toList();
    if (visibleWatermarks.isEmpty) {
      await File(inputVideoPath).copy(outputPath);
      return true;
    }

    final tempDir = await getTemporaryDirectory();
    final sessionPath = '${tempDir.path}/export_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(sessionPath).create(recursive: true);

    try {
      debugPrint('[VideoWatermarkService] Building descriptors...');
      final descriptors = await WatermarkRenderer.buildFfmpegDescriptors(
        watermarks: visibleWatermarks,
        videoW: videoWidth,
        videoH: videoHeight,
        tempDir: sessionPath,
      );
      debugPrint('[VideoWatermarkService] Descriptors built: ${descriptors.length}');

      final cmd = _buildFilterComplexArgs(inputVideoPath, descriptors, outputPath);
      debugPrint('[VideoWatermarkService] Final CMD Args: ${cmd.join(' ')}');

      if (Platform.isWindows) {
        debugPrint('[VideoWatermarkService] Checking system FFmpeg on Windows...');
        final hasFfmpeg = await _checkSystemFfmpeg();
        if (hasFfmpeg) {
          debugPrint('[VideoWatermarkService] Windows CLI found -> Starting process...');
          return await _runFfmpegCli(cmd, onProgress);
        } else {
          debugPrint('[VideoWatermarkService] ERROR: ffmpeg.exe not found on Windows PATH or project root.');
          return false;
        }
      }

      debugPrint('[VideoWatermarkService] Using FFmpegKit Plugin (Mobile)');
      return await _runFfmpegKit(cmd, onProgress);

    } catch (e, stack) {
      debugPrint('[VideoWatermarkService] CRITICAL ERROR: $e');
      debugPrint(stack.toString());
      return false;
    } finally {
      try {
        await Directory(sessionPath).delete(recursive: true);
      } catch (e) {
        debugPrint('[VideoWatermarkService] Cleanup error: $e');
      }
    }
  }

  static List<String> _buildFilterComplexArgs(
    String input, 
    List<FfmpegOverlayDescriptor> descriptors, 
    String output
  ) {
    final args = <String>['-y', '-i', input];
    for (var d in descriptors) {
      args.addAll(['-i', d.imagePath]);
    }

    final filter = StringBuffer();
    String lastOutput = '[0:v]';
    
    // 1. Scale all overlays first
    for (int i = 0; i < descriptors.length; i++) {
      final d = descriptors[i];
      filter.write('[${i + 1}:v]scale=${d.width}:${d.height}[scaled$i];');
    }

    // 2. Chain overlays
    for (int i = 0; i < descriptors.length; i++) {
        final d = descriptors[i];
        final scaled = '[scaled$i]';
        final out = '[v${i + 1}]';
        
        String overlayExpr = _getOverlayExpression(d);
        // Remove spaces in the filter string
        filter.write('$lastOutput$scaled overlay=$overlayExpr$out');
        if (i < descriptors.length - 1) filter.write(';');
        lastOutput = out;
    }

    // 3. Ensure YUV420P output format for maximum compatibility and to fix libx264 errors
    final String finalVideoOutput = '[final_vid]';
    if (descriptors.isNotEmpty) filter.write(';');
    // Removed all spaces within the filter string component itself
    filter.write('${lastOutput}format=yuv420p$finalVideoOutput');

    args.addAll(['-filter_complex', filter.toString()]);
    
    // Explicitly map the last video output from filter complex
    args.addAll(['-map', finalVideoOutput]);
    
    // Gracefully handle audio: copy if it exists, ignore if not
    args.addAll(['-map', '0:a?', '-c:a', 'copy']);
    
    // Video encoding settings
    args.addAll([
      '-c:v', 'libx264', 
      '-preset', 'ultrafast', 
      '-crf', '23', 
      output
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
        // Move from left to right, loop
        return 'x=\'-w + mod(t*W*$speed/5, W+w)\':y=$yBase';
      case AnimationType.topToBottom:
        // Move from top to bottom
        return 'x=$xBase:y=\'-h + mod(t*H*$speed/5, H+h)\'';
      case AnimationType.diagonal:
        // Move diagonally
        return 'x=\'-w + mod(t*W*$speed/5, W+w)\':y=\'-h + mod(t*H*$speed/5, H+h)\'';
      case AnimationType.bounce:
        // Bouncing logic using abs(sin)
        return 'x=\'abs(W-w)*abs(sin(t*$speed))\':y=\'abs(H-h)*abs(cos(t*$speed))\'';
      case AnimationType.circular:
        // Circular motion
        return 'x=\'$xBase + 100*cos(t*$speed)\':y=\'$yBase + 100*sin(t*$speed)\'';
      case AnimationType.zigZag:
        // Zigzag (combining linear x with sin y)
        return 'x=\'-w + mod(t*W*$speed/5, W+w)\':y=\'$yBase + 50*sin(t*${speed * 3})\'';
      default:
        return '$xBase:$yBase';
    }
  }

  static Future<bool> _runFfmpegKit(List<String> cmd, Function(double)? onProgress) async {
    final session = await FFmpegKit.executeWithArguments(cmd);
    final returnCode = await session.getReturnCode();
    return ReturnCode.isSuccess(returnCode);
  }

  static Future<bool> _runFfmpegCli(List<String> args, Function(double)? onProgress) async {
    try {
      final exe = _ffmpegPath;
      debugPrint('[VideoWatermarkService] Spawning Process: $exe');
      
      // On Windows, runInShell: true can cause issues with list arguments
      // It's safer to run directly unless you're calling a .bat file
      final process = await Process.start(exe, args);
      
      // We must consume the streams or the process will hang if the buffer fills up 
      // (important for long log outputs in video processing)
      process.stdout.listen((data) {}, onDone: () => debugPrint('[VideoWatermarkService] stdout closed'));
      process.stderr.listen((data) {
        // Optional: you can parse logs here for progress
      }, onDone: () => debugPrint('[VideoWatermarkService] stderr closed'));
      
      final exitCode = await process.exitCode;
      debugPrint('[VideoWatermarkService] Process exited: $exitCode');
      
      onProgress?.call(1.0);
      return exitCode == 0;
    } catch (e) {
      debugPrint('[VideoWatermarkService] CLI Process Spawn Failed: $e');
      return false;
    }
  }


  static Future<bool> _checkSystemFfmpeg() async {
    try {
      final exe = _ffmpegPath;
      final res = await Process.run(exe, ['-version'], runInShell: true);
      return res.exitCode == 0;
    } catch (_) { 
      return false; 
    }
  }

  static Future<(int, int)?> probeVideoDimensions(String path) async {
    if (Platform.isWindows) {
      final probePath = _ffprobePath;
      // Safety check: is it a full path or just a command?
      final isFound = probePath.contains('\\') ? File(probePath).existsSync() : true;
      
      if (isFound) {
        try {
          final res = await Process.run(probePath, [
            '-v', 'error', 
            '-select_streams', 'v:0', 
            '-show_entries', 'stream=width,height', 
            '-of', 'csv=s=x:p=0', 
            path
          ]);
          if (res.exitCode == 0) {
            final parts = res.stdout.toString().trim().split('x');
            if (parts.length == 2) {
              return (int.parse(parts[0]), int.parse(parts[1]));
            }
          }
        } catch (_) {}
      }
    }

    if (!Platform.isWindows) {
      try {
        final session = await FFmpegKit.execute('-i "$path"');
        final output = await session.getOutput();
        final regExp = RegExp(r'(\d{2,5})x(\d{2,5})');
        final match = regExp.firstMatch(output ?? '');
        if (match != null) return (int.parse(match.group(1)!), int.parse(match.group(2)!));
      } catch (_) {}
    }
    return null;
  }
}
