import 'dart:io';
import 'dart:typed_data';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/features/editor/providers/editor_provider.dart';

class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  bool _isDragging = false;
  bool _isLoading = false;

  static const _supportedExtensions = [
    'jpg', 'jpeg', 'png',
    'mp4', 'mov', 'avi', 'mkv', 'webm',
  ];

  Future<void> _loadFiles(List<String> paths) async {
    if (paths.isEmpty) return;

    // Check validation based on the first file, or all files:
    // To keep it simple, we just validate the first file for format
    final path = paths.first;
    final ext = path.split('.').last.toLowerCase();
    if (!_supportedExtensions.contains(ext)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unsupported format. Use JPG, PNG, MP4, MOV, AVI, MKV, or WEBM.'),
          ),
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    try {
      final file = File(path);
      Uint8List bytes = Uint8List(0);
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
      
      if (!isVideo) {
        final length = await file.length();
        if (length > 50 * 1024 * 1024) throw Exception("Image file too large");
        bytes = await file.readAsBytes();
      }
      ref.read(editorProvider.notifier).setMedia(bytes, paths);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load file: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _isDragging = false);
    if (details.files.isNotEmpty) {
      await _loadFiles(details.files.map((f) => f.path).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          DropTarget(
            onDragDone: _handleDrop,
            onDragEntered: (_) => setState(() => _isDragging = true),
            onDragExited: (_) => setState(() => _isDragging = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: _isDragging
                    ? theme.primaryColor.withValues(alpha: 0.08)
                    : Colors.transparent,
                border: _isDragging
                    ? Border.all(color: theme.primaryColor, width: 2)
                    : null,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                      side: BorderSide(
                        color: _isDragging
                            ? theme.primaryColor
                            : theme.dividerColor,
                        width: 2,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(48.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: _isLoading
                                ? const SizedBox(
                                    height: 64,
                                    width: 64,
                                    child: CircularProgressIndicator(strokeWidth: 3),
                                  )
                                : Icon(
                                    _isDragging
                                        ? Icons.file_download_outlined
                                        : Icons.cloud_upload_outlined,
                                    size: 64,
                                    color: theme.primaryColor,
                                  ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            _isDragging ? 'Drop to upload!' : 'Select Multiple Files',
                            style: theme.textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Drag and drop your image or video, or click to browse',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: theme.hintColor),
                          ),
                          const SizedBox(height: 32),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton.icon(
                                onPressed: _isLoading ? null : () => _pickFileType(FileType.image),
                                icon: const Icon(Icons.image_outlined),
                                label: const Text('Select Image'),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(180, 50),
                                ),
                              ),
                              const SizedBox(width: 16),
                              ElevatedButton.icon(
                                onPressed: _isLoading ? null : () => _pickFileType(FileType.video),
                                icon: const Icon(Icons.video_library_outlined),
                                label: const Text('Select Video'),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(180, 50),
                                  backgroundColor: theme.colorScheme.secondary,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const _FormatChips(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFileType(FileType type) async {
    final result = await FilePicker.platform.pickFiles(
      type: type,
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      await _loadFiles(result.files.map((f) => f.path!).toList());
    }
  }
}

class _FormatChips extends StatelessWidget {
  const _FormatChips();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        _chip(context, 'JPG', Colors.green),
        _chip(context, 'PNG', Colors.green),
        _chip(context, 'MP4', Colors.blue),
        _chip(context, 'MOV', Colors.blue),
        _chip(context, 'AVI', Colors.blue),
        _chip(context, 'MKV', Colors.blue),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Chip(
      label: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
      ),
      padding: EdgeInsets.zero,
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
    );
  }
}
