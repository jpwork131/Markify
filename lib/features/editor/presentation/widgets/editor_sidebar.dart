import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/features/editor/providers/editor_provider.dart';
import 'package:markify/shared/models/watermark.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

class EditorSidebar extends ConsumerWidget {
  const EditorSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorProvider);
    final selectedLayer = state.selectedLayer;
    final theme = Theme.of(context);

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              labelColor: theme.primaryColor,
              unselectedLabelColor: theme.hintColor,
              indicatorColor: theme.primaryColor,
              tabs: const [
                Tab(icon: Icon(Icons.settings), text: 'Layout'),
                Tab(icon: Icon(Icons.collections), text: 'Batch'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // Tab 1: Layout & Layers
                  Column(
                    children: [
                      _SidebarHeader(title: 'Properties'),
                      Expanded(
                        child: selectedLayer == null
                            ? const _NoSelectionPlaceholder()
                            : SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (selectedLayer is TextWatermark)
                                      _TextControls(layer: selectedLayer),
                                    if (selectedLayer is LogoWatermark)
                                      _LogoControls(layer: selectedLayer),
                                    const Divider(height: 32),
                                    _CommonControls(layer: selectedLayer),
                                    const Divider(height: 32),
                                    _AnimationControls(layer: selectedLayer),
                                    const Divider(height: 32),
                                    _PositionControls(layer: selectedLayer),
                                  ],
                                ),
                              ),
                      ),
                      _SidebarHeader(title: 'Layers'),
                      Expanded(
                        child: const _LayerList(),
                      ),
                    ],
                  ),
          // Tab 2: Batch File List
                  Column(
                    children: [
                      _SidebarHeader(title: 'Batch Selection'),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: OutlinedButton.icon(
                          onPressed: () => ref.read(editorProvider.notifier).applyCurrentToAll(),
                          icon: const Icon(Icons.copy_all, size: 16),
                          label: const Text('Apply Current to All', style: TextStyle(fontSize: 11)),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 36),
                          ),
                        ),
                      ),
                      const Expanded(
                        child: _BatchFileList(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchFileList extends ConsumerWidget {
  const _BatchFileList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaPaths = ref.watch(editorProvider.select((s) => s.mediaPaths));
    final currentPath = ref.watch(editorProvider.select((s) => s.mediaPath));

    if (mediaPaths.isEmpty) {
      return const Center(child: Text('Solo image'));
    }

    return ListView.builder(
      itemCount: mediaPaths.length,
      itemBuilder: (context, index) {
        final path = mediaPaths[index];
        final name = path.split('\\').last.split('/').last;
        final isSelected = currentPath == path;

        return ListTile(
          dense: true,
          selected: isSelected,
          leading: Icon(
            path.toLowerCase().endsWith('.mp4') || path.toLowerCase().endsWith('.mov')
                ? Icons.videocam
                : Icons.image,
            size: 16,
          ),
          title: Text(name, style: const TextStyle(fontSize: 12)),
          onTap: () => ref.read(editorProvider.notifier).switchPreviewFile(path),
        );
      },
    );
  }
}

// ─── Headers ──────────────────────────────────────────────────────────────────
class _SidebarHeader extends StatelessWidget {
  final String title;
  const _SidebarHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor.withValues(alpha: 0.05),
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
      ),
    );
  }
}

class _NoSelectionPlaceholder extends StatelessWidget {
  const _NoSelectionPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Text(
          'Select a layer to edit properties',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

// ─── Text Controls ────────────────────────────────────────────────────────────
class _TextControls extends ConsumerStatefulWidget {
  final TextWatermark layer;
  const _TextControls({required this.layer});

  @override
  ConsumerState<_TextControls> createState() => _TextControlsState();
}

class _TextControlsState extends ConsumerState<_TextControls> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.layer.text);
  }

  @override
  void didUpdateWidget(_TextControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layer.text != widget.layer.text &&
        _ctrl.text != widget.layer.text) {
      _ctrl.text = widget.layer.text;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layer = widget.layer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Text', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          onChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(text: val)),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
        const SizedBox(height: 16),
        Text('Font Size (% of image height)',
            style: Theme.of(context).textTheme.labelMedium),
        Slider(
          value: layer.fontSize.clamp(0.01, 0.3),
          min: 0.01,
          max: 0.3,
          label: '${(layer.fontSize * 100).toStringAsFixed(1)}%',
          onChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(fontSize: val)),
        ),
        const SizedBox(height: 16),
        Text('Color', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Pick a Color'),
              content: SingleChildScrollView(
                child: ColorPicker(
                  pickerColor: layer.color,
                  onColorChanged: (val) => ref
                      .read(editorProvider.notifier)
                      .updateLayer(layer.copyWith(color: val)),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: layer.color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Font Weight',
            style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        SegmentedButton<FontWeight>(
          segments: const [
            ButtonSegment(
                value: FontWeight.normal, label: Text('Normal')),
            ButtonSegment(
                value: FontWeight.bold, label: Text('Bold')),
          ],
          selected: {layer.fontWeight},
          onSelectionChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(fontWeight: val.first)),
        ),
      ],
    );
  }
}

// ─── Logo Controls ────────────────────────────────────────────────────────────
class _LogoControls extends ConsumerWidget {
  final LogoWatermark layer;
  const _LogoControls({required this.layer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Width (% of image)',
            style: Theme.of(context).textTheme.labelMedium),
        Slider(
          value: layer.normalizedWidth.clamp(0.01, 1.0),
          min: 0.01,
          max: 1.0,
          label: '${(layer.normalizedWidth * 100).toStringAsFixed(1)}%',
          onChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(normalizedWidth: val)),
        ),
        const SizedBox(height: 8),
        Text('Height (% of image)',
            style: Theme.of(context).textTheme.labelMedium),
        Slider(
          value: layer.normalizedHeight.clamp(0.01, 1.0),
          min: 0.01,
          max: 1.0,
          label: '${(layer.normalizedHeight * 100).toStringAsFixed(1)}%',
          onChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(normalizedHeight: val)),
        ),
      ],
    );
  }
}

// ─── Common Controls ──────────────────────────────────────────────────────────
class _CommonControls extends ConsumerWidget {
  final Watermark layer;
  const _CommonControls({required this.layer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Opacity', style: Theme.of(context).textTheme.labelMedium),
        Slider(
          value: layer.opacity,
          min: 0,
          max: 1,
          label: '${(layer.opacity * 100).toInt()}%',
          onChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(opacity: val)),
        ),
        const SizedBox(height: 8),
        Text('Rotation (°)',
            style: Theme.of(context).textTheme.labelMedium),
        Slider(
          value: layer.rotation,
          min: -180,
          max: 180,
          label: '${layer.rotation.toStringAsFixed(1)}°',
          onChanged: (val) => ref
              .read(editorProvider.notifier)
              .updateLayer(layer.copyWith(rotation: val)),
        ),
      ],
    );
  }
}

// ─── Animation Controls ───────────────────────────────────────────────────────
class _AnimationControls extends ConsumerWidget {
  final Watermark layer;
  const _AnimationControls({required this.layer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Animation', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 8),
        DropdownButtonFormField<AnimationType>(
          initialValue: layer.animationType,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: AnimationType.values.map((type) {
            final label = type.name.replaceAllMapped(
                RegExp(r'[A-Z]'), (match) => ' ${match.group(0)}');
            final capitalized = label[0].toUpperCase() + label.substring(1);
            return DropdownMenuItem(
              value: type,
              child: Text(capitalized),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              ref.read(editorProvider.notifier).updateLayer(
                    layer.copyWith(animationType: val),
                  );
            }
          },
        ),
        if (layer.animationType != AnimationType.none) ...[
          const SizedBox(height: 16),
          Text('Animation Speed',
              style: Theme.of(context).textTheme.labelMedium),
          Slider(
            value: layer.animationSpeed,
            min: 0.1,
            max: 5.0,
            label: '${layer.animationSpeed.toStringAsFixed(1)}x',
            onChanged: (val) => ref
                .read(editorProvider.notifier)
                .updateLayer(layer.copyWith(animationSpeed: val)),
          ),
        ],
      ],
    );
  }
}

// ─── Position Controls ────────────────────────────────────────────────────────
class _PositionControls extends ConsumerWidget {
  final Watermark layer;
  const _PositionControls({required this.layer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Position (Normalized)',
            style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(
          'X: ${(layer.normalizedCenterX * 100).toStringAsFixed(1)}%  '
          'Y: ${(layer.normalizedCenterY * 100).toStringAsFixed(1)}%',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _QuickPosBtn(
              label: 'Top Left',
              cx: 0.15, cy: 0.1,
              layer: layer,
              ref: ref,
            ),
            _QuickPosBtn(
              label: 'Top Center',
              cx: 0.5, cy: 0.1,
              layer: layer,
              ref: ref,
            ),
            _QuickPosBtn(
              label: 'Top Right',
              cx: 0.85, cy: 0.1,
              layer: layer,
              ref: ref,
            ),
            _QuickPosBtn(
              label: 'Center',
              cx: 0.5, cy: 0.5,
              layer: layer,
              ref: ref,
            ),
            _QuickPosBtn(
              label: 'Bottom Left',
              cx: 0.15, cy: 0.9,
              layer: layer,
              ref: ref,
            ),
            _QuickPosBtn(
              label: 'Bottom Center',
              cx: 0.5, cy: 0.9,
              layer: layer,
              ref: ref,
            ),
            _QuickPosBtn(
              label: 'Bottom Right',
              cx: 0.85, cy: 0.9,
              layer: layer,
              ref: ref,
            ),
          ],
        ),
      ],
    );
  }
}

class _QuickPosBtn extends StatelessWidget {
  final String label;
  final double cx, cy;
  final Watermark layer;
  final WidgetRef ref;

  const _QuickPosBtn({
    required this.label,
    required this.cx,
    required this.cy,
    required this.layer,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label,
          style:
              const TextStyle(fontSize: 11)),
      onPressed: () => ref
          .read(editorProvider.notifier)
          .updateLayer(
            layer.copyWith(normalizedCenterX: cx, normalizedCenterY: cy),
          ),
    );
  }
}

// ─── Layer List ───────────────────────────────────────────────────────────────
class _LayerList extends ConsumerWidget {
  const _LayerList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layers = ref.watch(editorProvider.select((s) => s.layers));
    final selectedId =
        ref.watch(editorProvider.select((s) => s.selectedLayerId));

    if (layers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('No layers yet.\nAdd text or logo watermarks.',
              textAlign: TextAlign.center),
        ),
      );
    }

    return ReorderableListView.builder(
      itemCount: layers.length,
      onReorder: (oldIndex, newIndex) =>
          ref.read(editorProvider.notifier).reorderLayers(oldIndex, newIndex),
      itemBuilder: (context, index) {
        final layer = layers[index];
        final isText = layer is TextWatermark;
        return ListTile(
          key: ValueKey(layer.id),
          selected: selectedId == layer.id,
          leading: Icon(isText ? Icons.text_fields : Icons.image_outlined),
          title: Text(
            isText ? layer.text : 'Logo Layer',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                    layer.isVisible ? Icons.visibility : Icons.visibility_off),
                onPressed: () => ref
                    .read(editorProvider.notifier)
                    .updateLayer(layer.copyWith(isVisible: !layer.isVisible)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline),
                onPressed: () =>
                    ref.read(editorProvider.notifier).deleteLayer(layer.id),
              ),
            ],
          ),
          onTap: () =>
              ref.read(editorProvider.notifier).selectLayer(layer.id),
        );
      },
    );
  }
}
