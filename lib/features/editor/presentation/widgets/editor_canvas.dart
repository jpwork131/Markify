import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/features/editor/providers/editor_provider.dart';
import 'package:markify/shared/models/watermark.dart';
import 'package:markify/shared/widgets/resize_handle.dart';
import 'package:video_player/video_player.dart';

// ─── Canvas ───────────────────────────────────────────────────────────────────

class EditorCanvas extends ConsumerStatefulWidget {
  const EditorCanvas({super.key});

  @override
  ConsumerState<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends ConsumerState<EditorCanvas> {
  final TransformationController _transformCtrl = TransformationController();

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorProvider);
    if (editorState.image == null && !editorState.isVideo) {
      return const Center(child: Text('No media loaded'));
    }

    return Shortcuts(
      shortcuts: const <SingleActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.delete): DeleteIntent(),
        SingleActivator(LogicalKeyboardKey.backspace): DeleteIntent(),
      },
      child: Focus(
        autofocus: true,
        child: InteractiveViewer(
          transformationController: _transformCtrl,
          minScale: 0.1,
          maxScale: 10,
          panEnabled: editorState.selectedLayerId == null,
          scaleEnabled: true,
          onInteractionUpdate: (_) {
            final zoom = _transformCtrl.value.getMaxScaleOnAxis();
            ref.read(editorProvider.notifier).setZoom(zoom);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              // ── Compute the exact rendered image rect ──────────────────────
              final imgSize = editorState.mediaSize ?? const Size(1, 1);
              final fitted = applyBoxFit(
                BoxFit.contain,
                imgSize,
                constraints.biggest,
              );
              final renderSize = fitted.destination;

              // Where is the top-left of the image inside the full constraints?
              final imgLeft =
                  (constraints.maxWidth - renderSize.width) / 2.0;
              final imgTop =
                  (constraints.maxHeight - renderSize.height) / 2.0;

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // ── Base image ─────────────────────────────────────────────
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: editorState.isVideo
                          ? _VideoBackground(
                              key: ValueKey(editorState.mediaPath),
                              path: editorState.mediaPath!,
                              onInitialized: (size) {
                                // Call asynchronously to prevent build phase issues
                                Future.microtask(() {
                                  if (ref.read(editorProvider).mediaSize !=
                                      size) {
                                    ref
                                        .read(editorProvider.notifier)
                                        .updateMediaSize(size);
                                  }
                                });
                              },
                            )
                          : Image.memory(
                              editorState.image!,
                              fit: BoxFit.contain,
                            ),
                    ),
                  ),

                  // ── Watermark layers ───────────────────────────────────────
                  RepaintBoundary(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final layer in editorState.layers)
                          if (layer.isVisible)
                            _WatermarkLayerWidget(
                              key: ValueKey(layer.id),
                              layer: layer,
                              renderSize: renderSize,
                              imgOffset: Offset(imgLeft, imgTop),
                              isSelected: editorState.selectedLayerId == layer.id,
                              onTap: () => ref
                                  .read(editorProvider.notifier)
                                  .selectLayer(layer.id),
                            ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─── Watermark Layer Widget ───────────────────────────────────────────────────

class _WatermarkLayerWidget extends ConsumerStatefulWidget {
  final Watermark layer;

  /// Pixel size of the rendered image inside the canvas.
  final Size renderSize;

  /// Top-left offset of the image within the LayoutBuilder constraints.
  final Offset imgOffset;

  final bool isSelected;
  final VoidCallback onTap;

  const _WatermarkLayerWidget({
    super.key,
    required this.layer,
    required this.renderSize,
    required this.imgOffset,
    required this.isSelected,
    required this.onTap,
  });

  @override
  ConsumerState<_WatermarkLayerWidget> createState() => _WatermarkLayerWidgetState();
}

class _WatermarkLayerWidgetState extends ConsumerState<_WatermarkLayerWidget> with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(vsync: this, duration: const Duration(days: 365))
      ..addListener(() => setState(() {}))
      ..forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layer = widget.layer;
    final zoom = ref.watch(editorProvider.select((s) => s.zoomLevel));

    final pixelCX = widget.imgOffset.dx + layer.normalizedCenterX * widget.renderSize.width;
    final pixelCY = widget.imgOffset.dy + layer.normalizedCenterY * widget.renderSize.height;
    final pixelW = layer.normalizedWidth * widget.renderSize.width;
    final pixelH = layer.normalizedHeight * widget.renderSize.height;

    double left = pixelCX - pixelW / 2.0;
    double top = pixelCY - pixelH / 2.0;

    if (layer.animationType != AnimationType.none) {
      final tSec = (_animCtrl.lastElapsedDuration?.inMilliseconds ?? 0) / 1000.0;
      final speed = layer.animationSpeed;
      final W = widget.renderSize.width;
      final H = widget.renderSize.height;
      final w = pixelW;
      final h = pixelH;

      switch (layer.animationType) {
        case AnimationType.leftToRight:
          left = widget.imgOffset.dx - w + ((tSec * W * speed / 5.0) % (W + w));
          break;
        case AnimationType.topToBottom:
          top = widget.imgOffset.dy - h + ((tSec * H * speed / 5.0) % (H + h));
          break;
        case AnimationType.diagonal:
          left = widget.imgOffset.dx - w + ((tSec * W * speed / 5.0) % (W + w));
          top = widget.imgOffset.dy - h + ((tSec * H * speed / 5.0) % (H + h));
          break;
        case AnimationType.bounce:
          left = widget.imgOffset.dx + (W - w).abs() * math.sin(tSec * speed).abs();
          top = widget.imgOffset.dy + (H - h).abs() * math.cos(tSec * speed).abs();
          break;
        case AnimationType.circular:
          left = left + 100 * math.cos(tSec * speed);
          top = top + 100 * math.sin(tSec * speed);
          break;
        case AnimationType.zigZag:
          left = widget.imgOffset.dx - w + ((tSec * W * speed / 5.0) % (W + w));
          top = top + 50 * math.sin(tSec * speed * 3.0);
          break;
        default:
          break;
      }
    }

    Widget content;
    if (layer is TextWatermark) {
      final textLayer = layer;
      content = Opacity(
        opacity: textLayer.opacity,
        child: SizedBox(
          width: pixelW,
          height: pixelH,
          child: FittedBox(
            fit: BoxFit.contain,
            child: Text(
              textLayer.text,
              style: TextStyle(
                fontSize: 100, 
                color: textLayer.color,
                fontWeight: textLayer.fontWeight,
                fontFamily: textLayer.fontFamily,
                height: 1.0,
              ),
              overflow: TextOverflow.visible,
              softWrap: false,
            ),
          ),
        ),
      );
    } else {
      final logoLayer = layer as LogoWatermark;
      content = Opacity(
        opacity: logoLayer.opacity,
        child: Image.file(
          File(logoLayer.imagePath),
          width: pixelW,
          height: pixelH,
          fit: BoxFit.contain,
        ),
      );
    }

    Widget layerWidget = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: pixelW,
          height: pixelH,
          alignment: Alignment.center,
          decoration: widget.isSelected
              ? BoxDecoration(
                  border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.8), width: 1.5),
                )
              : null,
          child: content,
        ),
        if (widget.isSelected) ..._buildHandles(ref, zoom, pixelW, pixelH),
      ],
    );

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        onPanUpdate: widget.isSelected
            ? (details) {
                final ndx = (details.delta.dx / zoom) / widget.renderSize.width;
                final ndy = (details.delta.dy / zoom) / widget.renderSize.height;
                ref.read(editorProvider.notifier).updateLayer(
                  layer.copyWith(
                    normalizedCenterX:
                        (layer.normalizedCenterX + ndx).clamp(0.0, 1.0),
                    normalizedCenterY:
                        (layer.normalizedCenterY + ndy).clamp(0.0, 1.0),
                  ),
                  snap: true,
                  saveToHistory: false,
                );
              }
            : null,
        onPanEnd: widget.isSelected
            ? (_) => ref.read(editorProvider.notifier).saveHistory()
            : null,
        child: Transform.rotate(
          angle: layer.rotation * math.pi / 180.0,
          alignment: Alignment.center,
          child: layerWidget,
        ),
      ),
    );
  }

  List<Widget> _buildHandles(
      WidgetRef ref, double zoom, double pixelW, double pixelH) {
    return [
      // Bottom-right: resize width + height
      ResizeHandle(
        alignment: Alignment.bottomRight,
        offset: Offset(pixelW, pixelH),
        onDragUpdate: (details) {
          final dw =
              (details.delta.dx / zoom) / widget.renderSize.width;
          final dh =
              (details.delta.dy / zoom) / widget.renderSize.height;
            ref.read(editorProvider.notifier).updateLayer(
              widget.layer.copyWith(
                normalizedWidth: (widget.layer.normalizedWidth + dw).clamp(0.02, 2.0),
                normalizedHeight: (widget.layer.normalizedHeight + dh).clamp(0.01, 2.0),
              ),
              saveToHistory: false,
            );
          },
          onDragEnd: () => ref.read(editorProvider.notifier).saveHistory(),
        ),
        // Middle-right: resize width only
        ResizeHandle(
          alignment: Alignment.centerRight,
          offset: Offset(pixelW, pixelH / 2),
          onDragUpdate: (details) {
            final dw = (details.delta.dx / zoom) / widget.renderSize.width;
            ref.read(editorProvider.notifier).updateLayer(
              widget.layer.copyWith(
                normalizedWidth: (widget.layer.normalizedWidth + dw).clamp(0.02, 2.0),
              ),
              saveToHistory: false,
            );
          },
          onDragEnd: () => ref.read(editorProvider.notifier).saveHistory(),
        ),
        // Bottom-middle: resize height only
        ResizeHandle(
          alignment: Alignment.bottomCenter,
          offset: Offset(pixelW / 2, pixelH),
          onDragUpdate: (details) {
            final dh = (details.delta.dy / zoom) / widget.renderSize.height;
            ref.read(editorProvider.notifier).updateLayer(
              widget.layer.copyWith(
                normalizedHeight: (widget.layer.normalizedHeight + dh).clamp(0.01, 2.0),
              ),
              saveToHistory: false,
            );
          },
          onDragEnd: () => ref.read(editorProvider.notifier).saveHistory(),
        ),
      ];
  }
}

// ─── Video Preview Widget ───────────────────────────────────────────────────

class _VideoBackground extends StatefulWidget {
  final String path;
  final Function(Size)? onInitialized;
  const _VideoBackground({super.key, required this.path, this.onInitialized});

  @override
  State<_VideoBackground> createState() => _VideoBackgroundState();
}

class _VideoBackgroundState extends State<_VideoBackground> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) {
          setState(() {
            _initialized = true;
          });
          _controller.setLooping(true);
          _controller.play();
          if (widget.onInitialized != null) {
            widget.onInitialized!(_controller.value.size);
          }
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Positioned.fill(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: VideoPlayer(_controller),
            ),
          ),
        ),
        // Play/Pause overlay
        Positioned(
          bottom: 16,
          left: 16,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: Theme.of(context).primaryColor,
            onPressed: () {
              setState(() {
                _controller.value.isPlaying
                    ? _controller.pause()
                    : _controller.play();
              });
            },
            child: Icon(
              _controller.value.isPlaying
                  ? Icons.pause
                  : Icons.play_arrow,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
