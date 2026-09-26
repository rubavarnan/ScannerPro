import 'dart:io';
import 'dart:ui' as ui;

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:pdf/pdf.dart' as pdf_lib;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

const _openWithChannel = MethodChannel('scanner_pro/downloads');

void main() => runApp(const ScannerProApp());

class ScannerProApp extends StatelessWidget {
  const ScannerProApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Scanner Pro+',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const HomePage(),
  );
}

class MyApp extends ScannerProApp {
  const MyApp({super.key});
}

void showGeneratingDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(width: 16),
          Text('Generating...'),
        ],
      ),
    ),
  );
}

void hideGeneratingDialog(BuildContext context) {
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  }
}

Uint8List compressEditedImage(Uint8List bytes, {int quality = 82}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final safeQuality = quality.clamp(1, 100);
  return Uint8List.fromList(img.encodeJpg(decoded, quality: safeQuality));
}

img.Image applyBrightnessAndContrast(
  img.Image source, {
  int brightness = 0,
  int contrast = 0,
}) {
  final safeBrightness = brightness.clamp(-100, 100);
  final safeContrast = contrast.clamp(-100, 100);
  final contrastFactor = safeContrast == 0
      ? 1.0
      : (259.0 * (safeContrast + 255.0)) / (255.0 * (259.0 - safeContrast));
  final brightnessShift = (safeBrightness / 100.0) * 255.0;

  final adjusted = img.Image(width: source.width, height: source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      final r = ((pixel.r - 128.0) * contrastFactor + 128.0 + brightnessShift)
          .round()
          .clamp(0, 255);
      final g = ((pixel.g - 128.0) * contrastFactor + 128.0 + brightnessShift)
          .round()
          .clamp(0, 255);
      final b = ((pixel.b - 128.0) * contrastFactor + 128.0 + brightnessShift)
          .round()
          .clamp(0, 255);
      final a = pixel.a;
      adjusted.setPixelRgba(x, y, r, g, b, a);
    }
  }
  return adjusted;
}

List<File> reorderFilesForDrag(List<File> files, int fromIndex, int toIndex) {
  if (fromIndex < 0 ||
      toIndex < 0 ||
      fromIndex >= files.length ||
      toIndex >= files.length ||
      fromIndex == toIndex) {
    return List<File>.from(files);
  }

  final ordered = List<File>.from(files);
  final moved = ordered.removeAt(fromIndex);
  final insertAt = (fromIndex < toIndex ? toIndex - 1 : toIndex).clamp(
    0,
    ordered.length,
  );
  ordered.insert(insertAt, moved);
  return ordered;
}

class DocumentFolder {
  Directory directory;
  DocumentFolder(this.directory);

  String get name => path.basename(directory.path);
  File get pdfFile => File(path.join(directory.path, '$name.pdf'));

  DateTime get createdDate => directory.statSync().changed;

  DateTime get modifiedDate {
    final files = directory.listSync().whereType<File>();
    return files.fold<DateTime>(
      directory.statSync().modified,
      (latest, file) {
        final modified = file.statSync().modified;
        return modified.isAfter(latest) ? modified : latest;
      },
    );
  }

  List<File> get images =>
      directory
          .listSync()
          .whereType<File>()
          .where(
            (file) => [
              '.jpg',
              '.jpeg',
              '.png',
              '.heic',
            ].contains(path.extension(file.path).toLowerCase()),
          )
          .toList()
        ..sort((a, b) {
          final aIndex = int.tryParse(path.basenameWithoutExtension(a.path));
          final bIndex = int.tryParse(path.basenameWithoutExtension(b.path));
          if (aIndex != null && bIndex != null) {
            return aIndex.compareTo(bIndex);
          }
          return a.path.compareTo(b.path);
        });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentFolder && directory.path == other.directory.path;

  @override
  int get hashCode => directory.path.hashCode;
}

class ImageEditorPage extends StatefulWidget {
  final File file;
  const ImageEditorPage({required this.file, super.key});

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> {
  late File _currentFile;
  int _brightness = 0;
  int _contrast = 0;
  bool _showOriginal = false;
  bool _isBusy = false;
  File? _enhancementBaseFile;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_isBusy || !mounted) return;
    setState(() => _isBusy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<File> _persistEditedImage(Uint8List bytes, String suffix) async {
    final compressed = compressEditedImage(bytes);
    final tempDir = await getTemporaryDirectory();
    final target = File(
      path.join(
        tempDir.path,
        'scanner_pro_${DateTime.now().millisecondsSinceEpoch}_$suffix.jpg',
      ),
    );
    await target.writeAsBytes(compressed);
    return target;
  }

  Future<void> _applyEnhancement() async {
    final source =
        _enhancementBaseFile ?? (_showOriginal ? widget.file : _currentFile);
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;

    final enhanced = applyBrightnessAndContrast(
      decoded,
      brightness: _brightness,
      contrast: _contrast,
    );
    final output = Uint8List.fromList(img.encodeJpg(enhanced, quality: 100));
    final updated = await _persistEditedImage(output, 'enhanced');
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = updated;
      _enhancementBaseFile ??= source;
    });
  }

  Future<void> _cropImage() async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: _currentFile.path,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 100,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop image',
          toolbarColor: Colors.indigo,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'Crop image'),
      ],
    );

    if (cropped == null || !mounted) return;

    final nextFile = File(cropped.path);
    setState(() {
      _showOriginal = false;
      _currentFile = nextFile;
      _enhancementBaseFile = null;
    });
  }

  Future<void> _enhanceImage() async {
    if (_brightness == 0 && _contrast == 0) {
      setState(() {
        _brightness = 8;
        _contrast = 12;
      });
    }
    await _applyEnhancement();
  }

  Future<void> _rotateImage() async {
    final bytes = await _currentFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;

    final rotated = img.copyRotate(decoded, angle: 90);
    final output = Uint8List.fromList(img.encodeJpg(rotated));
    final updated = await _persistEditedImage(output, 'rotated');
    if (mounted) {
      setState(() {
        _showOriginal = false;
        _currentFile = updated;
        _enhancementBaseFile = null;
      });
    }
  }

  Future<void> _resetImage() async {
    setState(() {
      _brightness = 0;
      _contrast = 0;
      _showOriginal = false;
      _currentFile = widget.file;
      _enhancementBaseFile = null;
    });
  }

  Future<void> _addSignature() async {
    final signatureBytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => const SignatureDialog(),
    );
    if (!mounted || signatureBytes == null || signatureBytes.isEmpty) return;

    final source = _showOriginal ? widget.file : _currentFile;
    final bytes = await source.readAsBytes();
    if (!context.mounted) return;
    final placementContext = context;
    final placedBytes = await showDialog<Uint8List>(
      context: placementContext,
      builder: (_) => SignaturePlacementDialog(
        imageBytes: bytes,
        signatureBytes: signatureBytes,
      ),
    );
    if (!mounted || placedBytes == null || placedBytes.isEmpty) return;

    final updated = await _persistEditedImage(placedBytes, 'signed');
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = updated;
      _enhancementBaseFile = null;
    });
  }

  Future<void> _addText() async {
    final options = await showDialog<TextAnnotationOptions>(
      context: context,
      builder: (_) => const TextEntryDialog(),
    );
    if (!context.mounted || options == null || options.text.trim().isEmpty) {
      return;
    }

    final source = _showOriginal ? widget.file : _currentFile;
    final imageBytes = await source.readAsBytes();
    if (!context.mounted) return;
    final placementContext = context;
    final placedBytes = await showDialog<Uint8List>(
      context: placementContext,
      builder: (_) => TextPlacementDialog(
        imageBytes: imageBytes,
        options: options,
      ),
    );
    if (!mounted || placedBytes == null || placedBytes.isEmpty) return;

    final updated = await _persistEditedImage(placedBytes, 'text');
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = updated;
      _enhancementBaseFile = null;
    });
  }

  Future<void> _saveImage() async {
    final updatedBytes = await _currentFile.readAsBytes();
    final savedFile = await _persistEditedImage(updatedBytes, 'saved');
    if (!mounted) return;
    Navigator.pop(context, savedFile);
  }

  Widget _buildEditAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton.filled(
      tooltip: tooltip,
      onPressed: _isBusy ? null : onPressed,
      icon: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _currentFile.existsSync();
    final displayedFile = _showOriginal ? widget.file : _currentFile;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit image'),
        actions: [
          IconButton(
            tooltip: 'Save changes',
            onPressed: canEdit ? _saveImage : null,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scrollableActions = <Widget>[
                    _buildEditAction(
                      icon: Icons.crop,
                      tooltip: 'Crop',
                      onPressed: () => _runAction(_cropImage),
                    ),
                    _buildEditAction(
                      icon: Icons.rotate_90_degrees_ccw,
                      tooltip: 'Rotate',
                      onPressed: () => _runAction(_rotateImage),
                    ),
                    _buildEditAction(
                      icon: Icons.auto_fix_high,
                      tooltip: 'Enhance',
                      onPressed: () => _runAction(_enhanceImage),
                    ),
                    _buildEditAction(
                      icon: Icons.draw,
                      tooltip: 'Signature',
                      onPressed: () => _runAction(_addSignature),
                    ),
                    _buildEditAction(
                      icon: Icons.text_fields,
                      tooltip: 'Text',
                      onPressed: () => _runAction(_addText),
                    ),
                  ];

                  return Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: scrollableActions
                                .map(
                                  (action) => Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: SizedBox(
                                      width: 48,
                                      height: 48,
                                      child: action,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 12, thickness: 1),
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: _buildEditAction(
                          icon: Icons.restart_alt,
                          tooltip: 'Reset',
                          onPressed: () => _runAction(_resetImage),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Edited')),
                  ButtonSegment(value: true, label: Text('Original')),
                ],
                selected: {_showOriginal},
                onSelectionChanged: (selection) =>
                    setState(() => _showOriginal = selection.first),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: canEdit
                      ? Image.file(displayedFile, fit: BoxFit.contain)
                      : const Center(child: Text('Image unavailable')),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text('Brightness'),
                      Expanded(
                        child: Slider(
                          value: _brightness.toDouble(),
                          min: -50,
                          max: 50,
                          divisions: 100,
                          onChanged: (value) {
                            setState(() => _brightness = value.round());
                          },
                          onChangeEnd: (_) async {
                            if (_showOriginal || _isBusy || !mounted) return;
                            await _runAction(_applyEnhancement);
                          },
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Contrast'),
                      Expanded(
                        child: Slider(
                          value: _contrast.toDouble(),
                          min: -50,
                          max: 50,
                          divisions: 100,
                          onChanged: (value) {
                            setState(() => _contrast = value.round());
                          },
                          onChangeEnd: (_) async {
                            if (_showOriginal || _isBusy || !mounted) return;
                            await _runAction(_applyEnhancement);
                          },
                        ),
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

class SignatureDialog extends StatefulWidget {
  const SignatureDialog({super.key});

  @override
  State<SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<SignatureDialog> {
  final List<Offset?> _points = <Offset?>[];
  final GlobalKey _canvasKey = GlobalKey();

  Future<void> _apply() async {
    if (_points.whereType<Offset>().length < 2) return;

    final boundary = _canvasKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return;

    final image = await boundary.toImage(pixelRatio: 3);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (!mounted || byteData == null) return;
    Navigator.pop(context, byteData.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add signature'),
      content: SizedBox(
        width: 360,
        height: 180,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.black26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: RepaintBoundary(
            key: _canvasKey,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) =>
                  setState(() => _points.add(details.localPosition)),
              onPanUpdate: (details) =>
                  setState(() => _points.add(details.localPosition)),
              onPanEnd: (_) => setState(() => _points.add(null)),
              child: SizedBox.expand(
                child: CustomPaint(
                  painter: SignaturePainter(List<Offset?>.from(_points)),
                ),
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(_points.clear),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }
}

class SignaturePainter extends CustomPainter {
  final List<Offset?> points;

  const SignaturePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var index = 0; index < points.length - 1; index++) {
      final start = points[index];
      final end = points[index + 1];
      if (start != null && end != null) {
        canvas.drawLine(start, end, paint);
      } else if (start != null && end == null) {
        canvas.drawCircle(start, paint.strokeWidth / 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant SignaturePainter oldDelegate) =>
      oldDelegate.points != points;
}

class SignaturePlacementDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final Uint8List signatureBytes;

  const SignaturePlacementDialog({
    required this.imageBytes,
    required this.signatureBytes,
    super.key,
  });

  @override
  State<SignaturePlacementDialog> createState() =>
      _SignaturePlacementDialogState();
}

class _SignaturePlacementDialogState extends State<SignaturePlacementDialog> {
  late final img.Image? _image;
  late final img.Image? _signature;
  double _leftFraction = 0.58;
  double _topFraction = 0.72;
  double _widthFraction = 0.35;

  @override
  void initState() {
    super.initState();
    _image = img.decodeImage(widget.imageBytes);
    _signature = img.decodeImage(widget.signatureBytes);
  }

  Rect _imageRect(Size size) {
    final image = _image;
    if (image == null) return Rect.zero;
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(image.width.toDouble(), image.height.toDouble()),
      size,
    );
    final destination = fitted.destination;
    return Rect.fromLTWH(
      (size.width - destination.width) / 2,
      (size.height - destination.height) / 2,
      destination.width,
      destination.height,
    );
  }

  double _signatureHeightFraction() {
    final image = _image;
    final signature = _signature;
    if (image == null || signature == null) return 0;
    final imageAspect = image.width / image.height;
    final signatureAspect = signature.width / signature.height;
    return _widthFraction * imageAspect / signatureAspect;
  }

  Rect _signatureRect(Rect imageRect) {
    final signature = _signature;
    if (signature == null) return Rect.zero;
    final width = imageRect.width * _widthFraction;
    final height = width * signature.height / signature.width;
    return Rect.fromLTWH(
      imageRect.left + imageRect.width * _leftFraction,
      imageRect.top + imageRect.height * _topFraction,
      width,
      height,
    );
  }

  void _moveSignature(DragUpdateDetails details, Rect imageRect) {
    final heightFraction = _signatureHeightFraction();
    setState(() {
      _leftFraction = (_leftFraction + details.delta.dx / imageRect.width)
          .clamp(0.0, 1.0 - _widthFraction)
          .toDouble();
      _topFraction = (_topFraction + details.delta.dy / imageRect.height)
          .clamp(0.0, 1.0 - heightFraction)
          .toDouble();
    });
  }

  void _resizeSignature(DragUpdateDetails details, Rect imageRect) {
    final image = _image;
    final signature = _signature;
    if (image == null || signature == null) return;
    final nextWidth = _widthFraction + details.delta.dx / imageRect.width;
    final nextHeight = nextWidth *
      (image.width / image.height) /
      (signature.width / signature.height);
    if (nextHeight >= 0.1 && nextHeight <= 0.85) {
      setState(() {
        _widthFraction = nextWidth.clamp(0.1, 0.85).toDouble();
        _leftFraction = _leftFraction
            .clamp(0.0, 1.0 - _widthFraction)
            .toDouble();
        _topFraction = _topFraction
            .clamp(0.0, 1.0 - _signatureHeightFraction())
            .toDouble();
      });
    }
  }

  Future<void> _apply() async {
    final image = _image;
    final signature = _signature;
    if (image == null || signature == null) return;

    final targetWidth = (image.width * _widthFraction).round().clamp(
      1,
      image.width,
    );
    final resizedSignature = img.copyResize(signature, width: targetWidth);
    final targetX = (image.width * _leftFraction).round();
    final targetY = (image.height * _topFraction).round();
    img.compositeImage(
      image,
      resizedSignature,
      dstX: targetX,
      dstY: targetY,
    );
    Navigator.pop(context, Uint8List.fromList(img.encodeJpg(image, quality: 100)));
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null || _signature == null) {
      return AlertDialog(
        title: const Text('Place signature'),
        content: const Text('The signature or image could not be read.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Place signature'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
            final imageRect = _imageRect(canvasSize);
            final signatureRect = _signatureRect(imageRect);
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black12,
                    child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                  ),
                ),
                Positioned.fromRect(
                  rect: signatureRect,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) =>
                        _moveSignature(details, imageRect),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: Image.memory(
                            widget.signatureBytes,
                            fit: BoxFit.contain,
                          ),
                        ),
                        Positioned(
                          right: -10,
                          bottom: -10,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) =>
                                _resizeSignature(details, imageRect),
                            child: const CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.indigo,
                              child: Icon(
                                Icons.open_in_full,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }
}

class TextAnnotationOptions {
  final String text;
  final Color color;
  final String fontFamily;
  final double fontSize;
  final bool bold;
  final bool italic;
  final TextAlign alignment;
  final double opacity;

  const TextAnnotationOptions({
    required this.text,
    required this.color,
    required this.fontFamily,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.alignment,
    required this.opacity,
  });
}

class TextEntryDialog extends StatefulWidget {
  const TextEntryDialog({super.key});

  @override
  State<TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<TextEntryDialog> {
  final TextEditingController _controller = TextEditingController();
  Color _color = Colors.black;
  String _fontFamily = 'Default';
  double _fontSize = 48;
  bool _bold = false;
  bool _italic = false;
  TextAlign _alignment = TextAlign.left;
  double _opacity = 1;

  static const _colors = <Color>[
    Colors.black,
    Colors.white,
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
  ];

  TextStyle get _previewStyle => TextStyle(
    color: _color,
    fontFamily: _fontFamily == 'Default' ? null : _fontFamily,
    fontSize: _fontSize,
    fontWeight: _bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: _italic ? FontStyle.italic : FontStyle.normal,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add text'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 4,
              minLines: 1,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Enter text',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Text color'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _colors.map((color) {
                return GestureDetector(
                  onTap: () => setState(() => _color = color),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: color,
                    child: _color == color
                        ? Icon(
                            Icons.check,
                            size: 18,
                            color: color.computeLuminance() > 0.5
                                ? Colors.black
                                : Colors.white,
                          )
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _fontFamily,
              decoration: const InputDecoration(labelText: 'Font family'),
              items: const [
                DropdownMenuItem(value: 'Default', child: Text('Default')),
                DropdownMenuItem(value: 'serif', child: Text('Serif')),
                DropdownMenuItem(value: 'monospace', child: Text('Monospace')),
              ],
              onChanged: (value) => setState(() => _fontFamily = value ?? 'Default'),
            ),
            Row(
              children: [
                const Text('Font size'),
                Expanded(
                  child: Slider(
                    value: _fontSize,
                    min: 16,
                    max: 96,
                    divisions: 20,
                    label: '${_fontSize.round()}',
                    onChanged: (value) => setState(() => _fontSize = value),
                  ),
                ),
                Text('${_fontSize.round()}'),
              ],
            ),
            Row(
              children: [
                FilterChip(
                  label: const Text('Bold'),
                  selected: _bold,
                  onSelected: (value) => setState(() => _bold = value),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Italic'),
                  selected: _italic,
                  onSelected: (value) => setState(() => _italic = value),
                ),
              ],
            ),
            DropdownButtonFormField<TextAlign>(
              initialValue: _alignment,
              decoration: const InputDecoration(labelText: 'Alignment'),
              items: const [
                DropdownMenuItem(value: TextAlign.left, child: Text('Left')),
                DropdownMenuItem(value: TextAlign.center, child: Text('Center')),
                DropdownMenuItem(value: TextAlign.right, child: Text('Right')),
              ],
              onChanged: (value) =>
                  setState(() => _alignment = value ?? TextAlign.left),
            ),
            Row(
              children: [
                const Text('Opacity'),
                Expanded(
                  child: Slider(
                    value: _opacity,
                    min: 0.1,
                    max: 1,
                    divisions: 9,
                    label: '${(_opacity * 100).round()}%',
                    onChanged: (value) => setState(() => _opacity = value),
                  ),
                ),
                Text('${(_opacity * 100).round()}%'),
              ],
            ),
            const SizedBox(height: 8),
            Text('Preview', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(
              _controller.text.isEmpty ? 'Your text preview' : _controller.text,
              style: _previewStyle.copyWith(
                color: _color.withValues(alpha: _opacity),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            TextAnnotationOptions(
              text: _controller.text,
              color: _color,
              fontFamily: _fontFamily,
              fontSize: _fontSize,
              bold: _bold,
              italic: _italic,
              alignment: _alignment,
              opacity: _opacity,
            ),
          ),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class TextPlacementDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final TextAnnotationOptions options;

  const TextPlacementDialog({
    required this.imageBytes,
    required this.options,
    super.key,
  });

  @override
  State<TextPlacementDialog> createState() => _TextPlacementDialogState();
}

class _TextPlacementDialogState extends State<TextPlacementDialog> {
  late final img.Image? _image;
  double _leftFraction = 0.08;
  double _topFraction = 0.08;
  late double _fontFraction;

  @override
  void initState() {
    super.initState();
    _image = img.decodeImage(widget.imageBytes);
    _fontFraction = widget.options.fontSize / 600;
  }

  Rect _imageRect(Size size) {
    final image = _image;
    if (image == null) return Rect.zero;
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(image.width.toDouble(), image.height.toDouble()),
      size,
    );
    final destination = fitted.destination;
    return Rect.fromLTWH(
      (size.width - destination.width) / 2,
      (size.height - destination.height) / 2,
      destination.width,
      destination.height,
    );
  }

  TextPainter _textPainter(double fontSize, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        text: widget.options.text,
        style: TextStyle(
          color: widget.options.color.withValues(alpha: widget.options.opacity),
          fontSize: fontSize,
          fontFamily: widget.options.fontFamily == 'Default'
              ? null
              : widget.options.fontFamily,
          fontWeight: widget.options.bold
              ? FontWeight.bold
              : FontWeight.normal,
          fontStyle: widget.options.italic
              ? FontStyle.italic
              : FontStyle.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: widget.options.alignment,
      maxLines: 8,
    );
    painter.layout(maxWidth: maxWidth);
    return painter;
  }

  Rect _textRect(Rect imageRect) {
    final painter = _textPainter(
      imageRect.width * _fontFraction,
      imageRect.width * 0.82,
    );
    return Rect.fromLTWH(
      imageRect.left + imageRect.width * _leftFraction,
      imageRect.top + imageRect.height * _topFraction,
      painter.width,
      painter.height,
    );
  }

  void _moveText(DragUpdateDetails details, Rect imageRect, Rect textRect) {
    setState(() {
      _leftFraction = (_leftFraction + details.delta.dx / imageRect.width)
          .clamp(0.0, ((imageRect.right - textRect.width - imageRect.left) /
                  imageRect.width)
              .clamp(0.0, 1.0))
          .toDouble();
      _topFraction = (_topFraction + details.delta.dy / imageRect.height)
          .clamp(0.0, ((imageRect.bottom - textRect.height - imageRect.top) /
                  imageRect.height)
              .clamp(0.0, 1.0))
          .toDouble();
    });
  }

  void _resizeText(DragUpdateDetails details, Rect imageRect) {
    final nextFontFraction =
        _fontFraction + details.delta.dx / imageRect.width;
    if (nextFontFraction < 0.03 || nextFontFraction > 0.2) return;
    setState(() => _fontFraction = nextFontFraction);
  }

  Future<Uint8List?> _renderText(int imageWidth) async {
    final fontSize = imageWidth * _fontFraction;
    final painter = _textPainter(fontSize, imageWidth * 0.82);
    final width = painter.width.ceil().clamp(1, imageWidth);
    final height = painter.height.ceil().clamp(1, imageWidth);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    painter.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(width, height);
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    picture.dispose();
    return data?.buffer.asUint8List();
  }

  Future<void> _apply() async {
    final image = _image;
    if (image == null) return;
    final textBytes = await _renderText(image.width);
    if (!mounted || textBytes == null) return;
    final textImage = img.decodeImage(textBytes);
    if (textImage == null) return;

    img.compositeImage(
      image,
      textImage,
      dstX: (image.width * _leftFraction).round(),
      dstY: (image.height * _topFraction).round(),
    );
    if (!mounted) return;
    Navigator.pop(context, Uint8List.fromList(img.encodeJpg(image, quality: 100)));
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return AlertDialog(
        title: const Text('Place text'),
        content: const Text('The image could not be read.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Place text'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
            final imageRect = _imageRect(canvasSize);
            final textRect = _textRect(imageRect);
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black12,
                    child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                  ),
                ),
                Positioned.fromRect(
                  rect: textRect,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) =>
                        _moveText(details, imageRect, textRect),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: Text(
                            widget.options.text,
                            maxLines: 8,
                            overflow: TextOverflow.clip,
                            textAlign: widget.options.alignment,
                            style: TextStyle(
                              color: widget.options.color.withValues(
                                alpha: widget.options.opacity,
                              ),
                              fontFamily: widget.options.fontFamily == 'Default'
                                  ? null
                                  : widget.options.fontFamily,
                              fontSize: imageRect.width * _fontFraction,
                              fontWeight: widget.options.bold
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              fontStyle: widget.options.italic
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                          ),
                        ),
                        Positioned(
                          right: -10,
                          bottom: -10,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) =>
                                _resizeText(details, imageRect),
                            child: const CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.indigo,
                              child: Icon(
                                Icons.open_in_full,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }
}

class StorageService {
  static Directory standardDownloadsDirectory({
    required String operatingSystem,
    String? downloadsDirectoryPath,
    String? homeDirectory,
  }) {
    if (operatingSystem == 'android') {
      return Directory(
        downloadsDirectoryPath ?? '/storage/emulated/0/Download',
      );
    }

    if (operatingSystem == 'windows') {
      final home =
          homeDirectory ??
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '.';
      return Directory(path.join(home, 'Downloads'));
    }

    final home =
        homeDirectory ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return Directory(path.join(home, 'Downloads'));
  }

  Future<Directory> root() async {
    final appDocumentsDirectory = await getApplicationDocumentsDirectory();
    final root = Directory(
      path.join(appDocumentsDirectory.path, 'Scanner Pro'),
    );
    await root.create(recursive: true);
    return root;
  }

  Future<Directory> downloads() async {
    if (Platform.isAndroid) {
      final dir = standardDownloadsDirectory(
        operatingSystem: 'android',
        downloadsDirectoryPath: '/storage/emulated/0/Download',
      );
      await dir.create(recursive: true);
      return dir;
    }

    if (Platform.isWindows) {
      final home =
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '.';
      final dir = standardDownloadsDirectory(
        operatingSystem: 'windows',
        homeDirectory: home,
      );
      await dir.create(recursive: true);
      return dir;
    }

    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final dir = standardDownloadsDirectory(
      operatingSystem: 'linux',
      homeDirectory: home,
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<DocumentFolder>> documents() async {
    final rootDirectory = await root();
    return rootDirectory
        .listSync()
        .whereType<Directory>()
        .map(DocumentFolder.new)
        .where(
          (document) =>
              document.images.isNotEmpty || document.pdfFile.existsSync(),
        )
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<DocumentFolder> createDocument() async {
    final rootDirectory = await root();
    final names = rootDirectory
        .listSync()
        .whereType<Directory>()
        .map((item) => path.basename(item.path).toLowerCase())
        .toSet();
    var number = 1;
    var name = 'Document';
    while (names.contains(name.toLowerCase())) {
      name = 'Document${++number}';
    }
    final directory = Directory(path.join(rootDirectory.path, name));
    await directory.create();
    return DocumentFolder(directory);
  }

  Future<DocumentFolder> importFile(File source, String originalName) async {
    final extension = path.extension(originalName).toLowerCase();
    final supportedImageExtensions = ['.jpg', '.jpeg', '.png', '.heic'];
    if (extension != '.pdf' && !supportedImageExtensions.contains(extension)) {
      throw FormatException('Unsupported imported file: $originalName');
    }

    final document = await createDocumentWithName(
      path.basenameWithoutExtension(originalName),
    );

    try {
      if (extension == '.pdf') {
        await _importPdfPages(source, document);
      } else {
        await source.copy(path.join(document.directory.path, '1$extension'));
      }
    } catch (_) {
      await document.directory.delete(recursive: true);
      rethrow;
    }

    return document;
  }

  Future<void> _importPdfPages(File source, DocumentFolder document) async {
    final pdfFile = await source.copy(document.pdfFile.path);
    final pdfDocument = await PdfDocument.openFile(pdfFile.path);
    try {
      for (var pageNumber = 1;
          pageNumber <= pdfDocument.pagesCount;
          pageNumber++) {
        final page = await pdfDocument.getPage(pageNumber);
        try {
          final width = 1600.0;
          final height = width * page.height / page.width;
          final rendered = await page.render(
            width: width,
            height: height,
            format: PdfPageImageFormat.jpeg,
            quality: 90,
            backgroundColor: '#FFFFFF',
          );
          if (rendered == null || rendered.bytes.isEmpty) {
            throw StateError('Could not render PDF page $pageNumber');
          }

          final imageFile = File(
            path.join(document.directory.path, '$pageNumber.jpg'),
          );
          await imageFile.writeAsBytes(rendered.bytes);
        } finally {
          await page.close();
        }
      }
    } finally {
      await pdfDocument.close();
    }

    if (document.images.isEmpty) {
      throw StateError('The imported PDF has no pages');
    }
  }

  Future<DocumentFolder> createDocumentWithName(String requestedName) async {
    final rootDirectory = await root();
    final names = rootDirectory
        .listSync()
        .whereType<Directory>()
        .map((item) => path.basename(item.path).toLowerCase())
        .toSet();
    final baseName = requestedName.trim().isEmpty
        ? 'Document'
        : requestedName.trim();
    var name = baseName;
    var number = 1;
    while (names.contains(name.toLowerCase())) {
      name = '$baseName${++number}';
    }
    final directory = Directory(path.join(rootDirectory.path, name));
    await directory.create();
    return DocumentFolder(directory);
  }

  Future<void> mergeDocuments(List<DocumentFolder> selectedDocuments) async {
    if (selectedDocuments.length < 2) {
      throw const FormatException('Select at least two documents to merge');
    }

    final winner = selectedDocuments.first;
    final losers = selectedDocuments.skip(1).toList();
    var nextIndex = winner.images
            .map((file) => int.tryParse(path.basenameWithoutExtension(file.path)))
            .whereType<int>()
            .fold<int>(0, (highest, value) => value > highest ? value : highest) +
        1;
    final copiedFiles = <File>[];

    try {
      for (final document in losers) {
        for (final source in document.images) {
          final extension = path.extension(source.path).toLowerCase();
          final target = File(
            path.join(winner.directory.path, '${nextIndex++}$extension'),
          );
          await source.copy(target.path);
          copiedFiles.add(target);
        }
      }

      for (final document in losers) {
        if (await document.directory.exists()) {
          await document.directory.delete(recursive: true);
        }
      }

      if (await winner.pdfFile.exists()) {
        await winner.pdfFile.delete();
      }
    } catch (_) {
      for (final file in copiedFiles) {
        if (await file.exists()) await file.delete();
      }
      rethrow;
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final storage = StorageService();
  final TextEditingController _searchController = TextEditingController();
  List<DocumentFolder> documents = [];
  bool loading = true;
  bool _searchOpen = false;
  bool _bulkProcessing = false;
  String _searchQuery = '';
  String _sortField = 'name';
  bool _sortAscending = true;
  bool _gridView = false;
  final List<DocumentFolder> _selectedDocuments = <DocumentFolder>[];

  List<DocumentFolder> get _filteredDocuments {
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List<DocumentFolder>.from(documents)
        : documents
        .where((document) => document.name.toLowerCase().contains(query))
        .toList();
    filtered.sort((a, b) {
      final comparison = switch (_sortField) {
        'created' => a.createdDate.compareTo(b.createdDate),
        'modified' => a.modifiedDate.compareTo(b.modifiedDate),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return _sortAscending ? comparison : -comparison;
    });
    return filtered;
  }

  bool get _isMultiSelectMode => _selectedDocuments.isNotEmpty;

  void _toggleDocumentSelection(DocumentFolder document) {
    setState(() {
      if (_selectedDocuments.contains(document)) {
        _selectedDocuments.remove(document);
      } else {
        _selectedDocuments.add(document);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedDocuments.clear());
  }

  Future<void> _loadHomeSettings() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sortField = preferences.getString('home_sort_field') ?? 'name';
      _sortAscending = preferences.getBool('home_sort_ascending') ?? true;
      _gridView = preferences.getBool('home_grid_view') ?? false;
    });
  }

  Future<void> _saveHomeSettings() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('home_sort_field', _sortField);
    await preferences.setBool('home_sort_ascending', _sortAscending);
    await preferences.setBool('home_grid_view', _gridView);
  }

  Future<void> _showSortDialog() async {
    var field = _sortField;
    var ascending = _sortAscending;
    final result = await showDialog<Map<String, Object>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Sort documents'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: field,
                decoration: const InputDecoration(labelText: 'Sort by'),
                items: const [
                  DropdownMenuItem(value: 'name', child: Text('Name')),
                  DropdownMenuItem(value: 'created', child: Text('Created date')),
                  DropdownMenuItem(value: 'modified', child: Text('Modified date')),
                ],
                onChanged: (value) => setDialogState(() => field = value ?? 'name'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Ascending')),
                  ButtonSegment(value: false, label: Text('Descending')),
                ],
                selected: {ascending},
                onSelectionChanged: (selection) =>
                    setDialogState(() => ascending = selection.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'field': field,
                'ascending': ascending,
              }),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _sortField = result['field'] as String;
      _sortAscending = result['ascending'] as bool;
    });
    await _saveHomeSettings();
  }

  Future<void> _toggleGridView() async {
    setState(() => _gridView = !_gridView);
    await _saveHomeSettings();
  }

  @override
  void initState() {
    super.initState();
    _openIncomingFile();
    _loadHomeSettings();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted && documents.isEmpty) setState(() => loading = true);
    try {
      await storage.root();
      documents = await storage.documents();
    } catch (error) {
      _message('Storage could not be prepared: $error');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openIncomingFile() async {
    _openWithChannel.setMethodCallHandler((call) async {
      if (call.method == 'incomingFileAvailable') {
        await _importIncomingFile();
      }
    });
    await _importIncomingFile();
  }

  Future<void> _importIncomingFile() async {
    try {
      final incoming = await _openWithChannel.invokeMethod<Object?>(
        'getIncomingFile',
      );
      if (incoming == null || !mounted) return;
      final sources = incoming is Map
          ? <Map<Object?, Object?>>[incoming.cast<Object?, Object?>()]
          : (incoming is List
            ? incoming
              .whereType<Map>()
              .map((file) => file.cast<Object?, Object?>())
              .toList()
            : <Map<Object?, Object?>>[]);
      for (final file in sources) {
        final sourcePath = file['path'] as String?;
        if (sourcePath == null) continue;
        final source = File(sourcePath);
        final name = file['name'] as String? ?? 'Document';
        await storage.importFile(source, name);
        await source.delete();
      }
      await _refresh();
      _message('Document imported.');
    } on PlatformException catch (error) {
      _message('Could not open document: ${error.message ?? error.code}');
    } catch (error) {
      _message('Could not import document: $error');
    }
  }

  Future<void> _addToNewDocument(ImageSource source) async {
    final document = await storage.createDocument();
    if (!mounted) return;

    try {
      if (source == ImageSource.gallery) {
        final selectedImages = await ImagePicker().pickMultiImage();
        if (selectedImages.isEmpty) {
          await document.directory.delete(recursive: true);
          return;
        }

        var nextIndex = 1;
        for (final selectedImage in selectedImages) {
          final extension = path.extension(selectedImage.name).toLowerCase();
          final safeExtension =
              ['.jpg', '.jpeg', '.png', '.heic'].contains(extension)
              ? extension
              : '.jpg';
          final target = File(
            path.join(document.directory.path, '${nextIndex++}$safeExtension'),
          );
          final bytes = await selectedImage.readAsBytes();
          if (bytes.isEmpty) continue;
          await target.writeAsBytes(bytes);
        }

        if (document.images.isEmpty) {
          await document.directory.delete(recursive: true);
          throw const FileSystemException('No usable images were selected');
        }
      } else {
        await CunningDocumentScanner.cleanCache();
        final scannedPaths = await CunningDocumentScanner.getPictures(
          scannerSource: ScannerSource.camera,
          noOfPages: 50,
          androidScannerMode: AndroidScannerMode.full,
        );
        if (scannedPaths == null || scannedPaths.isEmpty) {
          await document.directory.delete(recursive: true);
          return;
        }

        var nextIndex = 1;
        for (final scannedPath in scannedPaths) {
          final scannedFile = File(scannedPath);
          if (!await scannedFile.exists()) continue;

          final target = File(
            path.join(document.directory.path, '${nextIndex++}.jpg'),
          );
          await scannedFile.copy(target.path);
        }

        await CunningDocumentScanner.cleanCache();
        if (document.images.isEmpty) {
          await document.directory.delete(recursive: true);
          throw const FileSystemException('No usable images were scanned');
        }
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DocumentPage(document: document)),
      );
      if (mounted) await _refresh();
    } catch (error) {
      if (await document.directory.exists()) {
        await document.directory.delete(recursive: true);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add image: $error')));
      }
    }
  }

  Future<void> _openDocument(DocumentFolder document) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DocumentPage(document: document)),
    );
    _refresh();
  }

  Future<void> _rename(DocumentFolder document) async {
    final controller = TextEditingController(text: document.name);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename file'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    final clean = value?.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
    if (clean == null || clean.isEmpty || clean == document.name) return;
    final destination = Directory(
      path.join(document.directory.parent.path, clean),
    );
    if (await destination.exists()) {
      _message('A file with that name already exists.');
      return;
    }
    await document.directory.rename(destination.path);
    _refresh();
  }

  Future<void> _delete(DocumentFolder document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text(
          'This will delete "${document.name}" and all its scanned files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (await document.directory.exists()) {
      await document.directory.delete(recursive: true);
    }
    _refresh();
  }

  Future<void> _deleteSelectedDocuments() async {
    if (_selectedDocuments.isEmpty) return;

    final titles = _selectedDocuments.map((doc) => doc.name).join(', ');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete selected documents?'),
        content: Text(
          'This will delete ${_selectedDocuments.length} selected document(s):\n$titles',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    for (final document in _selectedDocuments.toList()) {
      if (await document.directory.exists()) {
        await document.directory.delete(recursive: true);
      }
    }

    _clearSelection();
    _refresh();
  }

  Future<void> _shareSelectedDocuments() async {
    if (_selectedDocuments.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Share selected files'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: fileType,
                      decoration: const InputDecoration(labelText: 'Share as'),
                      items: const [
                        DropdownMenuItem(value: 'pdf', child: Text('pdf')),
                        DropdownMenuItem(value: 'jpg', child: Text('jpg')),
                      ],
                      onChanged: (value) {
                        final nextType = value ?? fileType;
                        if (nextType == fileType) return;
                        setDialogState(() => fileType = nextType);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: const InputDecoration(labelText: 'File Size'),
                      items: buildExportSizeItems(
                        documentTotalBytes(_selectedDocuments.toList()),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => fileSize = value ?? 'Actual'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, {
                    'fileType': fileType,
                    'fileSize': fileSize,
                  }),
                  child: const Text('Share'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;

    setState(() => _bulkProcessing = true);
    showGeneratingDialog(context);
    try {
      final exportedFiles = <XFile>[];
      for (final document in _selectedDocuments) {
        if (document.images.isEmpty) continue;
        final exportPath = await exportDocumentImagesToDownloads(
          images: document.images,
          fileType: result['fileType'] ?? 'pdf',
          fileSize: result['fileSize'] ?? 'Actual',
          fileName: document.name,
          saveToDownloads: false,
        );
        exportedFiles.add(XFile(exportPath));
      }

      if (!mounted) return;
      if (exportedFiles.isEmpty) {
        hideGeneratingDialog(context);
        _message('No documents were available to share.');
        return;
      }

      hideGeneratingDialog(context);
      final shareResult = await SharePlus.instance.share(
        ShareParams(files: exportedFiles, text: 'Shared from Scanner Pro+'),
      );
      if (shareResult.status == ShareResultStatus.success) {
        _clearSelection();
      }
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      _message('Export failed: $error');
    } finally {
      if (mounted) setState(() => _bulkProcessing = false);
    }
  }

  Future<void> _mergeSelectedDocuments() async {
    if (_selectedDocuments.length < 2) return;

    final winner = _selectedDocuments.first;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Merge documents?'),
        content: Text(
          'Merge ${_selectedDocuments.length} documents into "${winner.name}"? '
          'The other documents will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _bulkProcessing = true);
    try {
      await storage.mergeDocuments(_selectedDocuments);
      _clearSelection();
      await _refresh();
      _message('Documents merged into "${winner.name}".');
    } catch (error) {
      _message('Merge failed: $error');
    } finally {
      if (mounted) setState(() => _bulkProcessing = false);
    }
  }

  Future<void> _menu(DocumentFolder document) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.picture_as_pdf),
              title: const Text('PDF preview'),
              onTap: () => Navigator.pop(sheetContext, 'preview'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') await _rename(document);
    if (action == 'delete') await _delete(document);
    if (action == 'preview' && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PdfPreviewPage(document: document)),
      );
    }
    _refresh();
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  Widget _buildGridDocumentCard(
    BuildContext context,
    DocumentFolder document,
  ) {
    final selected = _selectedDocuments.contains(document);
    final firstImage = document.images.firstOrNull;
    return InkWell(
      onTap: _isMultiSelectMode
          ? () => _toggleDocumentSelection(document)
          : () => _openDocument(document),
      onLongPress: () => _toggleDocumentSelection(document),
      borderRadius: BorderRadius.circular(12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            firstImage == null
                ? const Center(child: Icon(Icons.folder_outlined, size: 36))
                : Image.file(firstImage, fit: BoxFit.cover),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.8)],
                  ),
                ),
              ),
            ),
            if (_isMultiSelectMode)
              Positioned(
                top: 4,
                left: 4,
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleDocumentSelection(document),
                  fillColor: WidgetStatePropertyAll(
                    Theme.of(context).colorScheme.surface,
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Text(
                document.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNarrowLayout = MediaQuery.sizeOf(context).width < 500;

    return Scaffold(
    appBar: AppBar(
      title: _searchOpen
          ? SizedBox(
              width: 220,
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                },
                decoration: const InputDecoration(
                  hintText: 'Search docs',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            )
          : _isMultiSelectMode
          ? Text('${_selectedDocuments.length} selected')
          : Text('My Docs (${documents.length})'),
      leading: _isMultiSelectMode
          ? IconButton(
              onPressed: _clearSelection,
              icon: const Icon(Icons.close),
              tooltip: 'Clear selection',
            )
          : null,
      actions: [
        if (!_isMultiSelectMode)
          IconButton(
            onPressed: _toggleSearch,
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            tooltip: 'Search documents',
          ),
        if (!_isMultiSelectMode)
          PopupMenuButton<String>(
            tooltip: 'Document options',
            onSelected: (value) {
              if (value == 'sort') _showSortDialog();
              if (value == 'view') _toggleGridView();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'sort',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.sort),
                  title: Text('Sort'),
                ),
              ),
              PopupMenuItem(
                value: 'view',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_gridView ? Icons.view_list : Icons.grid_view),
                  title: Text(_gridView ? 'View as list' : 'View as grid'),
                ),
              ),
            ],
          ),
      ],
    ),
    floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    floatingActionButton: _isMultiSelectMode
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: () =>
                          _addToNewDocument(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt, size: 18),
                      label: const Text('Camera'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 42),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _addToNewDocument(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library, size: 18),
                      label: const Text('Gallery'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 42),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    body: SafeArea(
      top: false,
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredDocuments.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 220),
                      Center(
                        child: Text(
                          _searchQuery.isEmpty
                              ? 'No files yet. Tap Camera or Gallery to start scanning.'
                              : 'No documents match "$_searchQuery".',
                        ),
                      ),
                    ],
                  )
                : _gridView
                ? GridView.builder(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      _isMultiSelectMode
                          ? (isNarrowLayout ? 100 : 120)
                          : 100,
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: 0.75,
                        ),
                    itemCount: _filteredDocuments.length,
                    itemBuilder: (context, index) => _buildGridDocumentCard(
                      context,
                      _filteredDocuments[index],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      _isMultiSelectMode
                          ? (isNarrowLayout ? 100 : 120)
                          : 100,
                    ),
                    itemCount: _filteredDocuments.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final document = _filteredDocuments[index];
                      final selected = _selectedDocuments.contains(document);
                      final firstImage = document.images.firstOrNull;
                      return ListTile(
                        tileColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: _isMultiSelectMode
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) =>
                                    _toggleDocumentSelection(document),
                              )
                            : firstImage == null
                            ? const Icon(Icons.folder_outlined)
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  firstImage,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                ),
                              ),
                        title: Text(
                          document.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${document.images.length} picture${document.images.length == 1 ? '' : 's'}',
                        ),
                        onTap: _isMultiSelectMode
                            ? () => _toggleDocumentSelection(document)
                            : () => _openDocument(document),
                        onLongPress: () => _toggleDocumentSelection(document),
                        trailing: _isMultiSelectMode
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.more_vert),
                                onPressed: () => _menu(document),
                              ),
                      );
                    },
                  ),
          ),
          if (_isMultiSelectMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: isNarrowLayout
                    ? Row(
                        children: [
                          Expanded(
                            child: _buildBulkActionButton(
                              icon: Icons.delete_outline,
                              label: 'Delete',
                              vertical: true,
                              onPressed: _bulkProcessing
                                  ? null
                                  : _deleteSelectedDocuments,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildBulkActionButton(
                              icon: Icons.merge_type,
                              label: 'Merge',
                              vertical: true,
                              onPressed:
                                  _bulkProcessing ||
                                      _selectedDocuments.length < 2
                                  ? null
                                  : _mergeSelectedDocuments,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildBulkActionButton(
                              icon: Icons.share,
                              label: 'Share',
                              vertical: true,
                              onPressed: _bulkProcessing
                                  ? null
                                  : _shareSelectedDocuments,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: _buildBulkActionButton(
                              icon: Icons.delete_outline,
                              label: 'Delete',
                              onPressed: _bulkProcessing
                                  ? null
                                  : _deleteSelectedDocuments,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildBulkActionButton(
                              icon: Icons.merge_type,
                              label: 'Merge',
                              onPressed:
                                  _bulkProcessing ||
                                      _selectedDocuments.length < 2
                                  ? null
                                  : _mergeSelectedDocuments,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildBulkActionButton(
                              icon: Icons.share,
                              label: 'Share',
                              onPressed: _bulkProcessing
                                  ? null
                                  : _shareSelectedDocuments,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  Widget _buildBulkActionButton({
    required IconData icon,
    required String label,
    bool vertical = false,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: vertical
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon),
                  const SizedBox(height: 2),
                  Text(label),
                ],
              ),
            )
          : FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            ),
    );
  }
}

String sanitizeExportFileName(String rawName, String extension) {
  final cleaned = rawName.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
  final normalized = cleaned.isEmpty ? 'Document' : cleaned;
  final lowerExtension = extension.toLowerCase();
  final lowerName = normalized.toLowerCase();
  final hasExtension = lowerName.endsWith('.$lowerExtension');
  if (hasExtension) {
    return normalized.substring(
      0,
      normalized.length - lowerExtension.length - 1,
    );
  }
  return normalized;
}

int documentTotalBytes(List<DocumentFolder> documents) {
  return documents.fold<int>(0, (sum, document) {
    return sum +
        document.images.fold<int>(
          0,
          (docSum, file) => docSum + file.lengthSync(),
        );
  });
}

const exportSizeOptions = <String, double>{
  'Actual': 0.95,
  'Medium': 0.90,
  'Small': 0.80,
  'X-Small': 0.70,
  'Smallest': 0.60,
};

const exportQualityOptions = <String, int>{
  'Actual': 95,
  'Medium': 90,
  'Small': 80,
  'X-Small': 70,
  'Smallest': 60,
};

double exportScaleForSize(String fileSize) =>
    exportSizeOptions[fileSize] ?? exportSizeOptions['Actual']!;

int exportQualityForSize(String fileSize) =>
    exportQualityOptions[fileSize] ?? exportQualityOptions['Actual']!;

String formatByteSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)}KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

List<DropdownMenuItem<String>> buildExportSizeItems(int actualBytes) =>
    exportSizeOptions.entries
        .map(
          (entry) => DropdownMenuItem(value: entry.key, child: Text(entry.key)),
        )
        .toList();

Future<File> _generateExportFile({
  required List<File> images,
  required String fileType,
  required File outputFile,
  required double scaleFactor,
  required int quality,
}) async {
  if (images.isEmpty) {
    throw const FormatException('No images available for export');
  }

  if (fileType.toLowerCase() == 'jpg') {
    final decodedImages = <img.Image>[];
    for (final imageFile in images) {
      final bytes = await imageFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) continue;
      decodedImages.add(_scaleExportImage(decoded, scaleFactor));
    }

    if (decodedImages.isEmpty) {
      throw const FormatException('No images available for export');
    }

    final maxWidth = decodedImages.fold<int>(
      0,
      (current, image) => image.width > current ? image.width : current,
    );
    final totalHeight = decodedImages.fold<int>(
      0,
      (total, image) => total + image.height,
    );

    final combined = img.Image(width: maxWidth, height: totalHeight);
    var y = 0;
    for (final page in decodedImages) {
      final xOffset = (maxWidth - page.width) ~/ 2;
      img.compositeImage(combined, page, dstX: xOffset, dstY: y);
      y += page.height;
    }

    await outputFile.writeAsBytes(img.encodeJpg(combined, quality: quality));
    return outputFile;
  }

  final pdf = pw.Document();
  final pageFormat = pdf_lib.PdfPageFormat.standard;

  for (final imageFile in images) {
    final bytes = await imageFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) continue;

    final scaledImage = _scaleExportImage(decoded, scaleFactor);
    final scaledBytes = Uint8List.fromList(
      img.encodeJpg(scaledImage, quality: quality),
    );
    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (_) => pw.Center(
          child: pw.Image(
            pw.MemoryImage(scaledBytes),
            fit: pw.BoxFit.contain,
            width: pageFormat.width,
            height: pageFormat.height,
          ),
        ),
      ),
    );
  }

  await outputFile.writeAsBytes(await pdf.save());
  return outputFile;
}

img.Image _scaleExportImage(img.Image source, double scaleFactor) {
  const maxExportDimension = 1800;
  final requestedScale = scaleFactor.clamp(0.01, 1.0);
  final dimensionScale =
      maxExportDimension /
      (source.width > source.height ? source.width : source.height);
  final effectiveScale = requestedScale < dimensionScale
      ? requestedScale
      : dimensionScale;
  if (effectiveScale >= 1) return source;
  return img.copyResize(
    source,
    width: (source.width * effectiveScale).round().clamp(1, source.width),
    height: (source.height * effectiveScale).round().clamp(1, source.height),
  );
}

Future<String> saveToPublicDownloads({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('scanner_pro/downloads');
    try {
      final savedPath = await channel.invokeMethod<String>('saveFile', {
        'fileName': fileName,
        'mimeType': mimeType,
        'bytes': bytes,
      });
      if (savedPath != null && savedPath.isNotEmpty) {
        return savedPath;
      }
    } catch (_) {
      // Fall back to the public Downloads directory if the platform channel fails.
    }
  }

  final downloadsDir = await StorageService().downloads();
  final outputFile = _nextAvailableExportFile(downloadsDir, fileName);
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsBytes(bytes);
  return outputFile.path;
}

File _nextAvailableExportFile(Directory directory, String fileName) {
  final extension = path.extension(fileName);
  final baseName = extension.isEmpty
      ? fileName
      : fileName.substring(0, fileName.length - extension.length);
  var candidate = File(path.join(directory.path, fileName));
  var suffix = 1;
  while (candidate.existsSync()) {
    candidate = File(
      path.join(directory.path, '${baseName}_$suffix$extension'),
    );
    suffix++;
  }
  return candidate;
}

Future<String> exportDocumentImagesToDownloads({
  required List<File> images,
  required String fileType,
  required String fileName,
  String fileSize = 'Actual',
  bool saveToDownloads = true,
}) async {
  final extension = fileType.toLowerCase() == 'jpg' ? 'jpg' : 'pdf';
  final cleanName = sanitizeExportFileName(fileName, extension);
  final fileNameWithExtension = '$cleanName.$extension';

  final tempFile = File(
    path.join(Directory.systemTemp.path, fileNameWithExtension),
  );
  await tempFile.parent.create(recursive: true);

  if (images.isEmpty) {
    throw const FormatException('No images available for export');
  }
  await _generateExportFile(
    images: images,
    fileType: fileType,
    outputFile: tempFile,
    scaleFactor: exportScaleForSize(fileSize),
    quality: exportQualityForSize(fileSize),
  );

  final bytes = await tempFile.readAsBytes();
  if (!saveToDownloads) {
    return tempFile.path;
  }

  final mimeType = extension == 'jpg' ? 'image/jpeg' : 'application/pdf';

  final targetName = fileNameWithExtension;
  final publicPath = await saveToPublicDownloads(
    fileName: targetName,
    bytes: bytes,
    mimeType: mimeType,
  );

  if (await tempFile.exists()) {
    await tempFile.delete();
  }

  return publicPath;
}

class DocumentPage extends StatefulWidget {
  final DocumentFolder document;
  const DocumentPage({required this.document, super.key});

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

class _DocumentPageState extends State<DocumentPage> {
  bool processing = false;
  bool saving = false;
  bool _isReordering = false;
  int _imageRefreshToken = 0;
  late String _currentName;

  List<File> get images => widget.document.images;

  @override
  void initState() {
    super.initState();
    _currentName = widget.document.name;
  }

  String _formatDate(File file) {
    final date = file.lastModifiedSync();
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]}-${date.day}';
  }

  String _formatFileSize(File file) {
    final bytes = file.lengthSync();
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  Future<List<XFile>> _pickGalleryImages() async {
    try {
      return await ImagePicker().pickMultiImage();
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      final isMissingImageUri =
          code.contains('missing') && code.contains('image-uri');
      if (!isMissingImageUri) rethrow;

      final selectedImage = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      return selectedImage == null ? <XFile>[] : [selectedImage];
    }
  }

  Future<void> _add(ImageSource source) async {
    try {
      if (source == ImageSource.gallery) {
        final selectedImages = await _pickGalleryImages();
        if (selectedImages.isEmpty) return;

        final nextIndexStart = images
            .map(
              (file) => int.tryParse(path.basenameWithoutExtension(file.path)),
            )
            .whereType<int>()
            .fold<int>(
              0,
              (highest, value) => value > highest ? value : highest,
            );
        var nextIndex = nextIndexStart + 1;
        var importedCount = 0;
        for (final selectedImage in selectedImages) {
          final extension = path.extension(selectedImage.name).toLowerCase();
          final safeExtension =
              ['.jpg', '.jpeg', '.png', '.heic'].contains(extension)
              ? extension
              : '.jpg';
          final target = File(
            path.join(
              widget.document.directory.path,
              '${nextIndex++}$safeExtension',
            ),
          );
          final bytes = await selectedImage.readAsBytes();
          if (bytes.isEmpty) continue;
          await target.writeAsBytes(bytes);
          importedCount++;
        }

        if (importedCount == 0) {
          throw const FileSystemException('No usable images were selected');
        }
        if (mounted) setState(() {});
        return;
      }

      const scannerSource = ScannerSource.camera;
      await CunningDocumentScanner.cleanCache();
      final scannedPaths = await CunningDocumentScanner.getPictures(
        scannerSource: scannerSource,
        noOfPages: 50,
        androidScannerMode: AndroidScannerMode.full,
      );

      if (scannedPaths == null || scannedPaths.isEmpty) return;

      final nextIndexStart = images
          .map((file) => int.tryParse(path.basenameWithoutExtension(file.path)))
          .whereType<int>()
          .fold<int>(0, (highest, value) => value > highest ? value : highest);
      var nextIndex = nextIndexStart + 1;
      for (final scannedPath in scannedPaths) {
        final scannedFile = File(scannedPath);
        if (!await scannedFile.exists()) continue;

        final target = File(
          path.join(widget.document.directory.path, '${nextIndex++}.jpg'),
        );
        await scannedFile.copy(target.path);
      }

      await CunningDocumentScanner.cleanCache();
      if (mounted) setState(() {});
    } on CunningDocumentScannerException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add image: $error')));
      }
    }
  }

  Future<void> _chooseCameraSource() async {
    await _add(ImageSource.camera);
  }

  Future<void> _openImageEditor(File file) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImageEditorPage(file: file)),
    );

    if (result is File && mounted) {
      final updated = result;
      final target = File(file.path);
      if (!await updated.exists()) return;

      final updatedBytes = await updated.readAsBytes();
      await target.writeAsBytes(updatedBytes, flush: true);
      await FileImage(target).evict();
      if (updated.path != target.path && await updated.exists()) {
        await updated.delete();
      }
      setState(() => _imageRefreshToken++);
    }
  }

  Future<void> _remove(File file) async {
    if (!await file.exists()) return;

    await file.delete();
    if (mounted) setState(() {});
  }

  Future<void> _reorderImages(String fromPath, String toPath) async {
    final currentImages = images;
    final fromIndex = currentImages.indexWhere(
      (file) => file.path == fromPath,
    );
    final toIndex = currentImages.indexWhere((file) => file.path == toPath);
    if (_isReordering ||
        fromIndex < 0 ||
        toIndex < 0 ||
        fromIndex >= currentImages.length ||
        toIndex >= currentImages.length ||
        fromIndex == toIndex) {
      return;
    }

    final orderedImages = reorderFilesForDrag(
      currentImages,
      fromIndex,
      toIndex,
    );

    setState(() => _isReordering = true);
    final temporaryFiles = <File>[];
    final stagedImages = <({String extension, List<int> bytes})>[];
    var reordered = false;
    try {
      for (final image in currentImages) {
        await FileImage(image).evict();
      }

      final stamp = DateTime.now().microsecondsSinceEpoch;
      stagedImages.addAll(
        await Future.wait(
          orderedImages.map((source) async {
            final bytes = await source.readAsBytes();
            if (bytes.isEmpty) {
              throw const FormatException(
                'An image could not be read during reorder',
              );
            }
            return (
              extension: path.extension(source.path).toLowerCase(),
              bytes: bytes,
            );
          }),
        ),
      );

      temporaryFiles.addAll(
        List.generate(
          stagedImages.length,
          (index) => File(
            path.join(
              widget.document.directory.path,
              '.reorder_${stamp}_$index${stagedImages[index].extension}',
            ),
          ),
        ),
      );
      await Future.wait(
        List.generate(
          stagedImages.length,
          (index) => temporaryFiles[index].writeAsBytes(
            stagedImages[index].bytes,
            flush: true,
          ),
        ),
      );

      await Future.wait(
        currentImages.map((source) async {
          if (await source.exists()) await source.delete();
        }),
      );

      await Future.wait(
        List.generate(temporaryFiles.length, (index) async {
        await temporaryFiles[index].rename(
          path.join(
            widget.document.directory.path,
            '${index + 1}${stagedImages[index].extension}',
          ),
        );
        }),
      );
      reordered = true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reorder images: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isReordering = false;
          if (reordered) _imageRefreshToken++;
        });
      }
    }
  }

  Future<void> _renameDocument() async {
    final controller = TextEditingController(text: _currentName);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename file'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final rawName = value?.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
    if (rawName == null || rawName.isEmpty || rawName == _currentName) return;
    final clean = rawName;
    final destination = Directory(
      path.join(widget.document.directory.parent.path, clean),
    );
    if (await destination.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A file with that name already exists.'),
          ),
        );
      }
      return;
    }
    await widget.document.directory.rename(destination.path);
    widget.document.directory = destination;
    if (!mounted) return;
    setState(() => _currentName = clean);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Renamed to $clean')));
  }

  Future<String> _exportDocumentFile({
    required String fileType,
    required String fileName,
    required String fileSize,
    bool saveToDownloads = true,
  }) async {
    return exportDocumentImagesToDownloads(
      images: images,
      fileType: fileType,
      fileName: fileName,
      fileSize: fileSize,
      saveToDownloads: saveToDownloads,
    );
  }

  Future<void> _shareDocument() async {
    if (images.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';
    final fileNameController = TextEditingController(text: _currentName);

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Share as'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: fileType,
                      decoration: const InputDecoration(labelText: 'Share as'),
                      items: const [
                        DropdownMenuItem(value: 'pdf', child: Text('pdf')),
                        DropdownMenuItem(value: 'jpg', child: Text('jpg')),
                      ],
                      onChanged: (value) {
                        final nextType = value ?? fileType;
                        if (nextType == fileType) return;
                        setDialogState(() => fileType = nextType);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: const InputDecoration(labelText: 'File Size'),
                      items: buildExportSizeItems(
                        documentTotalBytes([widget.document]),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => fileSize = value ?? 'Actual'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: fileNameController,
                      decoration: const InputDecoration(labelText: 'File Name'),
                      textCapitalization: TextCapitalization.none,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, {
                    'fileType': fileType,
                    'fileSize': fileSize,
                    'fileName': fileNameController.text,
                  }),
                  child: const Text('Share'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;

    setState(() => processing = true);
    showGeneratingDialog(context);
    try {
      final outputPath = await _exportDocumentFile(
        fileType: result['fileType'] ?? 'pdf',
        fileSize: result['fileSize'] ?? 'Actual',
        fileName: result['fileName'] ?? _currentName,
        saveToDownloads: false,
      );

      if (!mounted) return;

      hideGeneratingDialog(context);
      final shareResult = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(outputPath)],
          text: 'Shared from Scanner Pro+',
        ),
      );

      if (shareResult.status == ShareResultStatus.success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document shared successfully.')),
        );
      }
      final temporaryFile = File(outputPath);
      if (await temporaryFile.exists()) await temporaryFile.delete();
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> _downloadDocument() async {
    if (images.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';
    final fileNameController = TextEditingController(text: _currentName);

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Save as'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: fileType,
                      decoration: const InputDecoration(labelText: 'Save as'),
                      items: const [
                        DropdownMenuItem(value: 'pdf', child: Text('pdf')),
                        DropdownMenuItem(value: 'jpg', child: Text('jpg')),
                      ],
                      onChanged: (value) {
                        final nextType = value ?? fileType;
                        if (nextType == fileType) return;
                        setDialogState(() => fileType = nextType);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: const InputDecoration(labelText: 'File Size'),
                      items: buildExportSizeItems(
                        documentTotalBytes([widget.document]),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => fileSize = value ?? 'Actual'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: fileNameController,
                      decoration: const InputDecoration(labelText: 'File Name'),
                      textCapitalization: TextCapitalization.none,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, {
                    'fileType': fileType,
                    'fileSize': fileSize,
                    'fileName': fileNameController.text,
                  }),
                  child: const Text('Download'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;

    setState(() => saving = true);
    showGeneratingDialog(context);
    try {
      final outputPath = await _exportDocumentFile(
        fileType: result['fileType'] ?? 'pdf',
        fileSize: result['fileSize'] ?? 'Actual',
        fileName: result['fileName'] ?? _currentName,
      );

      if (!mounted) return;
      hideGeneratingDialog(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloaded to $outputPath')));
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: GestureDetector(
        onTap: _renameDocument,
        child: Text(
          _currentName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      actions: [
        if (images.isNotEmpty)
          IconButton(
            tooltip: 'Share document',
            onPressed: processing ? null : _shareDocument,
            icon: processing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share),
          ),
        if (images.isNotEmpty)
          IconButton(
            tooltip: 'Download document',
            onPressed: saving ? null : _downloadDocument,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
          ),
      ],
    ),
    floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    floatingActionButton: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: _chooseCameraSource,
                icon: const Icon(Icons.camera_alt, size: 18),
                label: const Text('Camera'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 42),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _add(ImageSource.gallery),
                icon: const Icon(Icons.photo_library, size: 18),
                label: const Text('Gallery'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 42),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: images.isEmpty
                ? const Center(
                    child: Text('Add a picture from the camera or gallery.'),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: images.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 0.8,
                        ),
                    itemBuilder: (_, index) {
                      final file = images[index];
                      return DragTarget<String>(
                        onWillAcceptWithDetails: (details) =>
                            details.data != file.path &&
                            images.any((image) => image.path == details.data),
                        onAcceptWithDetails: (details) {
                          _reorderImages(details.data, file.path);
                        },
                        builder: (context, candidateData, rejectedData) {
                          final isDropTarget = candidateData.isNotEmpty;
                          return LongPressDraggable<String>(
                            data: file.path,
                            maxSimultaneousDrags: _isReordering ? 0 : 1,
                            delay: const Duration(milliseconds: 150),
                            feedback: Material(
                              elevation: 8,
                              borderRadius: BorderRadius.circular(12),
                              clipBehavior: Clip.antiAlias,
                              child: SizedBox(
                                width: 160,
                                height: 210,
                                child: Image.file(file, fit: BoxFit.cover),
                              ),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: isDropTarget
                                    ? Border.all(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        width: 3,
                                      )
                                    : null,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Stack(
                                key: ValueKey(file.path),
                                children: [
                                  Positioned.fill(
                                    child: GestureDetector(
                                      onTap: () => _openImageEditor(file),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.file(
                                          file,
                                          key: ValueKey(
                                            '${file.path}-$_imageRefreshToken',
                                          ),
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.transparent,
                                              Colors.black54,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 8,
                                    left: 8,
                                    child: IgnorePointer(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '${index + 1}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 8,
                                    left: 8,
                                    right: 42,
                                    child: IgnorePointer(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _formatDate(file),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _formatFileSize(file),
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: IconButton(
                                      onPressed: () => _remove(file),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 26,
                                        minHeight: 26,
                                      ),
                                      icon: const CircleAvatar(
                                        radius: 13,
                                        backgroundColor: Colors.black54,
                                        child: Icon(
                                          Icons.close,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class PdfPreviewPage extends StatefulWidget {
  final DocumentFolder document;
  const PdfPreviewPage({required this.document, super.key});

  @override
  State<PdfPreviewPage> createState() => _PdfPreviewPageState();
}

class _PdfPreviewPageState extends State<PdfPreviewPage> {
  bool saving = false;

  Future<void> _renameDocument() async {
    final controller = TextEditingController(text: widget.document.name);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename file'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    final rawName = value?.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
    if (rawName == null || rawName.isEmpty || rawName == widget.document.name) {
      return;
    }

    final destination = Directory(
      path.join(widget.document.directory.parent.path, rawName),
    );
    if (await destination.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A file with that name already exists.'),
          ),
        );
      }
      return;
    }

    await widget.document.directory.rename(destination.path);
    widget.document.directory = destination;

    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Renamed to $rawName')));
  }

  Future<void> _shareDocument() async {
    if (widget.document.images.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';
    final fileNameController = TextEditingController(
      text: widget.document.name,
    );

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Share as'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: fileType,
                      decoration: const InputDecoration(labelText: 'Share as'),
                      items: const [
                        DropdownMenuItem(value: 'pdf', child: Text('pdf')),
                        DropdownMenuItem(value: 'jpg', child: Text('jpg')),
                      ],
                      onChanged: (value) {
                        final nextType = value ?? fileType;
                        if (nextType == fileType) return;
                        setDialogState(() => fileType = nextType);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: const InputDecoration(labelText: 'File Size'),
                      items: buildExportSizeItems(
                        documentTotalBytes([widget.document]),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => fileSize = value ?? 'Actual'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: fileNameController,
                      decoration: const InputDecoration(labelText: 'File Name'),
                      textCapitalization: TextCapitalization.none,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, {
                    'fileType': fileType,
                    'fileSize': fileSize,
                    'fileName': fileNameController.text,
                  }),
                  child: const Text('Share'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;

    showGeneratingDialog(context);
    try {
      final outputPath = await exportDocumentImagesToDownloads(
        images: widget.document.images,
        fileType: result['fileType'] ?? 'pdf',
        fileSize: result['fileSize'] ?? 'Actual',
        fileName: result['fileName'] ?? widget.document.name,
        saveToDownloads: false,
      );

      if (!mounted) return;
      hideGeneratingDialog(context);
      final shareResult = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(outputPath)],
          text: 'Shared from Scanner Pro+',
        ),
      );

      if (shareResult.status == ShareResultStatus.success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document shared successfully.')),
        );
      }
      final temporaryFile = File(outputPath);
      if (await temporaryFile.exists()) await temporaryFile.delete();
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    }
  }

  Future<void> _downloadDocument() async {
    if (widget.document.images.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';
    final fileNameController = TextEditingController(
      text: widget.document.name,
    );

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Save as'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: fileType,
                      decoration: const InputDecoration(labelText: 'Save as'),
                      items: const [
                        DropdownMenuItem(value: 'pdf', child: Text('pdf')),
                        DropdownMenuItem(value: 'jpg', child: Text('jpg')),
                      ],
                      onChanged: (value) {
                        final nextType = value ?? fileType;
                        if (nextType == fileType) return;
                        setDialogState(() => fileType = nextType);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: const InputDecoration(labelText: 'File Size'),
                      items: buildExportSizeItems(
                        documentTotalBytes([widget.document]),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => fileSize = value ?? 'Actual'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: fileNameController,
                      decoration: const InputDecoration(labelText: 'File Name'),
                      textCapitalization: TextCapitalization.none,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, {
                    'fileType': fileType,
                    'fileSize': fileSize,
                    'fileName': fileNameController.text,
                  }),
                  child: const Text('Download'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;

    setState(() => saving = true);
    showGeneratingDialog(context);
    try {
      final outputPath = await exportDocumentImagesToDownloads(
        images: widget.document.images,
        fileType: result['fileType'] ?? 'pdf',
        fileSize: result['fileSize'] ?? 'Actual',
        fileName: result['fileName'] ?? widget.document.name,
      );

      if (!mounted) return;
      hideGeneratingDialog(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloaded to $outputPath')));
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.grey.shade200,
    appBar: AppBar(
      title: GestureDetector(
        onTap: _renameDocument,
        child: Text(
          widget.document.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      actions: widget.document.images.isEmpty
          ? const []
          : [
              IconButton(
                tooltip: 'Share',
                onPressed: _shareDocument,
                icon: const Icon(Icons.share),
              ),
              IconButton(
                tooltip: 'Download',
                onPressed: saving ? null : _downloadDocument,
                icon: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
              ),
            ],
    ),
    body: SafeArea(
      top: false,
      child: widget.document.images.isEmpty
          ? const Center(child: Text('No pictures in this file.'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: widget.document.images.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, index) {
                final file = widget.document.images[index];
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 5,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: AspectRatio(
                    aspectRatio:
                        pdf_lib.PdfPageFormat.standard.width /
                        pdf_lib.PdfPageFormat.standard.height,
                    child: Image.file(file, fit: BoxFit.contain),
                  ),
                );
              },
            ),
    ),
  );
}
