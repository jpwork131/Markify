import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

class LoggerService {
  static Future<void> logError(String message) async {
    try {
      final logFile = await _getLogFile();
      final timestamp = DateTime.now().toIso8601String();
      await logFile.writeAsString('[$timestamp] ERROR: $message\n', mode: FileMode.append);
      debugPrint('Logged Error: $message');
    } catch (e) {
      debugPrint('Failed to log error: $e');
    }
  }

  static Future<void> logInfo(String message) async {
    try {
      final logFile = await _getLogFile();
      final timestamp = DateTime.now().toIso8601String();
      await logFile.writeAsString('[$timestamp] INFO: $message\n', mode: FileMode.append);
      debugPrint('Logged Info: $message');
    } catch (e) {
      debugPrint('Failed to log info: $e');
    }
  }

  static Future<File> _getLogFile() async {
    String baseDir;
    if (Platform.isWindows) {
      // For EXE portability, put logs folder next to EXE
      baseDir = p.dirname(Platform.resolvedExecutable);
    } else {
      // On other platforms, use project directory or temp
      baseDir = Directory.current.path;
    }

    final logsDir = Directory(p.join(baseDir, 'logs'));
    if (!logsDir.existsSync()) {
      logsDir.createSync(recursive: true);
    }
    
    return File(p.join(logsDir.path, 'error.log'));
  }
}
