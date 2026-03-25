import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:markify/features/editor/providers/editor_provider.dart';
import 'package:markify/features/upload/presentation/upload_screen.dart';
import 'package:markify/features/editor/presentation/widgets/editor_canvas.dart';
import 'package:markify/features/editor/presentation/widgets/editor_sidebar.dart';
import 'package:markify/features/export/services/image_exporter.dart';
import 'package:markify/services/video_watermark_service.dart';
import 'package:markify/services/batch_processor.dart';
import 'package:markify/features/license/providers/license_provider.dart';
import 'package:markify/features/license/presentation/screens/license_screen.dart';

// ─── Home ─────────────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final licenseState = ref.watch(licenseProvider);

    if (licenseState.status == LicenseStatus.loading || 
        licenseState.status == LicenseStatus.unknown) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (licenseState.status != LicenseStatus.valid) {
      return const LicenseScreen();
    }

    final hasMedia = ref.watch(editorProvider.select((s) => s.image != null || s.isVideo));

    return Scaffold(
      body: Stack(
        children: [
          hasMedia ? const EditorView() : const UploadScreen(),
          if (licenseState.expiryDate != null)
            Positioned(
              bottom: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.verified, size: 14, color: Colors.greenAccent),
                    const SizedBox(width: 6),
                    Text(
                      'License: Expires on ${licenseState.expiryDate}',
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Editor View ──────────────────────────────────────────────────────────────

class EditorView extends ConsumerWidget {
  const EditorView({super.key});

  // ── Export handler ──────────────────────────────────────────────────────────
  Future<void> _handleExport(BuildContext context, WidgetRef ref) async {
    final state = ref.read(editorProvider);
    if (state.image == null && !state.isVideo) return;

    if (state.mediaPaths.length > 1) {
      // For batch export, we open a dedicated dialog that handles its own state
      // We return here to avoid the finally block below which pops the dialog.
      await _handleBatchExport(context, ref, state);
      return;
    }

    // Single export logic
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ExportProgressDialog(),
      );
    }

    try {
      if (state.isVideo) {
        await _exportVideo(context, state, ref);
      } else {
        await _exportImage(context, state);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      // ONLY pop for single export (the anonymous dialog we showed at line 45)
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }


  Future<void> _handleBatchExport(BuildContext context, WidgetRef ref, dynamic state) async {
    final outputDirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Output Directory for Batch',
    );
    if (outputDirPath == null) return;

    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BatchExportProgressDialog(
          state: state,
          outputDirPath: outputDirPath,
        ),
      );
    }
  }

  Future<void> _exportImage(BuildContext context, dynamic state) async {
    final exportBytes = await ImageExporter.export(state: state);
    if (exportBytes == null) return;

    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save watermarked image',
      fileName: 'watermarked_image.png',
      type: FileType.image,
    );

    if (outputPath != null) {
      await File(outputPath).writeAsBytes(exportBytes);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ Image saved to $outputPath')),
        );
      }
    }
  }

  Future<void> _exportVideo(
    BuildContext context,
    dynamic state,
    WidgetRef ref,
  ) async {
    final mediaPath = state.mediaPath!;

    // Probe actual video dimensions
    final dims = await VideoWatermarkService.probeVideoDimensions(mediaPath);
    if (dims == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Could not read video dimensions.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save watermarked video',
      fileName: 'watermarked_video.mp4',
    );
    if (outputPath == null) return;

    final success = await VideoWatermarkService.applyWatermarks(
      inputVideoPath: mediaPath,
      watermarks: state.layers,
      outputPath: outputPath,
      videoWidth: dims.$1,
      videoHeight: dims.$2,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? '✅ Video saved to $outputPath' : '❌ Video export failed. Check logs.',
          ),
          backgroundColor: success ? null : Colors.red,
        ),
      );
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isVideo =
        ref.watch(editorProvider.select((s) => s.isVideo));

    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ):
            const UndoIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyY):
            const RedoIntent(),
        LogicalKeySet(LogicalKeyboardKey.delete): const DeleteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          UndoIntent: CallbackAction<UndoIntent>(
            onInvoke: (_) => ref.read(editorProvider.notifier).undo(),
          ),
          RedoIntent: CallbackAction<RedoIntent>(
            onInvoke: (_) => ref.read(editorProvider.notifier).redo(),
          ),
          DeleteIntent: CallbackAction<DeleteIntent>(onInvoke: (_) {
            final sel =
                ref.read(editorProvider).selectedLayerId;
            if (sel != null) {
              ref.read(editorProvider.notifier).deleteLayer(sel);
            }
            return null;
          }),
        },
        child: Column(
          children: [
            // ── Toolbar ──────────────────────────────────────────────────────
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: theme.cardColor,
                border:
                    Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back to Upload',
                    onPressed: () =>
                        ref.read(editorProvider.notifier).reset(),
                  ),
                  const VerticalDivider(indent: 12, endIndent: 12),
                  Row(
                    children: [
                      Text(
                        'Watermark Pro',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (isVideo) ...[
                        const SizedBox(width: 8),
                        Chip(
                          label: const Text('VIDEO'),
                          backgroundColor:
                              Colors.deepPurple.withValues(alpha: 0.15),
                          labelStyle: const TextStyle(
                            color: Colors.deepPurple,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                      if (ref.read(editorProvider).mediaPaths.length > 1) ...[
                        const SizedBox(width: 8),
                        Chip(
                          label: Text('${ref.read(editorProvider).mediaPaths.length} FILES'),
                          backgroundColor: Colors.blue.withValues(alpha: 0.15),
                          labelStyle: const TextStyle(
                            color: Colors.blue,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ],
                  ),
                  const Spacer(),
                  // Undo / Redo
                  IconButton(
                    icon: const Icon(Icons.undo),
                    tooltip: 'Undo (Ctrl+Z)',
                    onPressed: () => ref.read(editorProvider.notifier).undo(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.redo),
                    tooltip: 'Redo (Ctrl+Y)',
                    onPressed: () =>
                        ref.read(editorProvider.notifier).redo(),
                  ),
                  const VerticalDivider(indent: 12, endIndent: 12),
                  // Add Text
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(editorProvider.notifier).addTextWatermark(),
                    icon: const Icon(Icons.text_fields),
                    label: const Text('Add Text'),
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          theme.primaryColor.withValues(alpha: 0.1),
                      foregroundColor: theme.primaryColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Add Logo
                  FilledButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform
                          .pickFiles(type: FileType.image);
                      if (result != null &&
                          result.files.single.path != null) {
                        ref
                            .read(editorProvider.notifier)
                            .addLogoWatermark(result.files.single.path!);
                      }
                    },
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Add Logo'),
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          theme.primaryColor.withValues(alpha: 0.1),
                      foregroundColor: theme.primaryColor,
                    ),
                  ),
                  const VerticalDivider(indent: 12, endIndent: 12),
                  // Export
                  ElevatedButton.icon(
                    onPressed: () => _handleExport(context, ref),
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      ref.read(editorProvider).mediaPaths.length > 1
                          ? 'Process Batch'
                          : (isVideo ? 'Export Video' : 'Export Image'),
                    ),
                  ),
                ],
              ),
            ),

            // ── Editor Body ───────────────────────────────────────────────────
            Expanded(
              child: Row(
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: EditorCanvas(),
                    ),
                  ),
                  const EditorSidebar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Progress Dialog ──────────────────────────────────────────────────────────

class _ExportProgressDialog extends StatelessWidget {
  const _ExportProgressDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Exporting…',
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _BatchExportProgressDialog extends StatefulWidget {
  final dynamic state;
  final String outputDirPath;
  const _BatchExportProgressDialog({required this.state, required this.outputDirPath});

  @override
  State<_BatchExportProgressDialog> createState() => _BatchExportProgressDialogState();
}

class _BatchExportProgressDialogState extends State<_BatchExportProgressDialog> {
  int _current = 0;
  int _total = 1;
  int _success = 0;
  int _failed = 0;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _startBatch();
  }

  Future<void> _startBatch() async {
    final processor = BatchProcessor(
      paths: widget.state.mediaPaths,
      configState: widget.state,
      outputDir: widget.outputDirPath,
      onProgress: (current, total) {
        if (mounted) {
          setState(() {
            _current = current;
            _total = total;
          });
        }
      },
      onComplete: (success, failed) {
        if (mounted) {
          setState(() {
            _success = success;
            _failed = failed;
            _completed = true;
          });
        }
      },
    );
    await processor.processBatch();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == 0 ? 0.0 : _current / _total;
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Batch Processing'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_completed) ...[
              LinearProgressIndicator(
                value: progress,
                backgroundColor: theme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text('Processing $_current of $_total files…',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ] else ...[
              const Icon(Icons.check_circle, color: Colors.green, size: 64),
              const SizedBox(height: 16),
              Text('Done!', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.dividerColor.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    _ResultRow(
                      icon: Icons.check_circle_outline,
                      label: 'Successful',
                      count: _success,
                      color: Colors.green,
                    ),
                    const Divider(height: 16),
                    _ResultRow(
                      icon: Icons.error_outline,
                      label: 'Failed',
                      count: _failed,
                      color: _failed > 0 ? Colors.red : Colors.grey,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_completed)
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: const Text('OK'),
          ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color color;

  const _ResultRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(label),
        const Spacer(),
        Text(count.toString(),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }
}

