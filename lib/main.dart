import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bicubic_resize/flutter_bicubic_resize.dart' as bicubic;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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
final _generatingProgress = ValueNotifier<int>(0);

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

void showGeneratingDialog(
  BuildContext context, {
  String message = 'Generating...',
}) {
  _generatingProgress.value = 0;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 16),
          ValueListenableBuilder<int>(
            valueListenable: _generatingProgress,
            builder: (_, progress, _) => Text('$message $progress%'),
          ),
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

Future<T> runWithProgressDialog<T>(
  BuildContext context, {
  required String message,
  required Future<T> Function() action,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 16),
            Text(message),
          ],
        ),
      ),
    ),
  );
  final routeFuture = navigator.push<void>(route);
  try {
    await WidgetsBinding.instance.endOfFrame;
    return await action();
  } finally {
    if (navigator.mounted && route.isActive) {
      navigator.removeRoute(route);
    }
    await routeFuture;
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
  final insertAt = toIndex.clamp(0, ordered.length);
  ordered.insert(insertAt, moved);
  return ordered;
}

class DocumentFolder {
  static const _createdAtFileName = '.scanner_pro_created_at';

  Directory directory;
  DocumentFolder(this.directory);

  String get name => path.basename(directory.path);
  File get pdfFile => File(path.join(directory.path, '$name.pdf'));
  File get _createdAtFile =>
      File(path.join(directory.path, _createdAtFileName));

  DateTime get createdDate {
    if (_createdAtFile.existsSync()) {
      final savedDate = DateTime.tryParse(_createdAtFile.readAsStringSync());
      if (savedDate != null) return savedDate;
    }
    return directory.statSync().changed;
  }

  Future<void> preserveCreatedDate() async {
    if (_createdAtFile.existsSync()) {
      final savedDate = DateTime.tryParse(await _createdAtFile.readAsString());
      if (savedDate != null) return;
    }
    await _createdAtFile.writeAsString(
      directory.statSync().changed.toIso8601String(),
      flush: true,
    );
  }

  DateTime get modifiedDate {
    final files = directory.listSync().whereType<File>().where(
      (file) => path.basename(file.path) != _createdAtFileName,
    );
    return files.fold<DateTime>(directory.statSync().modified, (latest, file) {
      final modified = file.statSync().modified;
      return modified.isAfter(latest) ? modified : latest;
    });
  }

  int get sizeBytes => directory
      .listSync()
      .whereType<File>()
      .where((file) => path.basename(file.path) != _createdAtFileName)
      .fold<int>(0, (total, file) => total + file.lengthSync());

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

List<(int, int)> collageLayoutsForImageCount(int imageCount) {
  if (imageCount <= 0) return const [];
  return [
    for (var rows = 1; rows <= 4; rows++)
      for (var columns = 1; columns <= 3; columns++)
        if (rows * columns >= imageCount) (rows, columns),
  ];
}

class _CollageLayoutPreview extends StatelessWidget {
  final int rows;
  final int columns;
  final int selectedCount;

  const _CollageLayoutPreview({
    required this.rows,
    required this.columns,
    required this.selectedCount,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: GridView.builder(
          padding: const EdgeInsets.all(10),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rows * columns,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
            childAspectRatio: 0.75 * rows / columns,
          ),
          itemBuilder: (context, index) => DecoratedBox(
            decoration: BoxDecoration(
              color: index < selectedCount
                  ? colorScheme.primaryContainer
                  : colorScheme.surface,
              border: Border.all(
                color: index < selectedCount
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }
}

class EditedImageResult {
  final File sourceFile;
  final File editedFile;

  const EditedImageResult({required this.sourceFile, required this.editedFile});
}

class ImageEditorPage extends StatefulWidget {
  final File file;
  final List<File> files;
  const ImageEditorPage({required this.file, this.files = const [], super.key});

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> {
  late final List<File> _files = widget.files.isEmpty
      ? [widget.file]
      : List<File>.unmodifiable(widget.files);
  int _imageIndex = 0;
  late File _currentFile;
  Uint8List? _displayedBytes;
  int _brightness = 0;
  int _contrast = 0;
  bool _showOriginal = false;
  bool _isBusy = false;
  bool _showBusySpinner = false;
  bool _hasUnsavedChanges = false;
  File? _enhancementBaseFile;

  File get _sourceFile => _files[_imageIndex];

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    final initialIndex = _files.indexWhere(
      (file) => file.path == widget.file.path,
    );
    if (initialIndex >= 0) _imageIndex = initialIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final initialBytes = await _sourceFile.readAsBytes();
      if (mounted) {
        setState(() => _displayedBytes = initialBytes);
      }
    });
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    bool showSpinner = true,
  }) async {
    if (_isBusy || !mounted) return;
    setState(() {
      _isBusy = true;
      _showBusySpinner = showSpinner;
    });
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _showBusySpinner = false;
        });
      }
    }
  }

  Future<File> _persistEditedImage(Uint8List bytes, String suffix) async {
    final compressed = compressEditedImage(bytes, quality: 82);
    final tempDir = await getTemporaryDirectory();
    final target = File(
      path.join(
        tempDir.path,
        'scanner_pro_${DateTime.now().millisecondsSinceEpoch}_$suffix.jpg',
      ),
    );
    await target.writeAsBytes(compressed);
    if (mounted) {
      setState(() => _displayedBytes = compressed);
    }
    return target;
  }

  Future<void> _applyEnhancement() async {
    final source =
        _enhancementBaseFile ?? (_showOriginal ? _sourceFile : _currentFile);
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;

    final enhanced = applyBrightnessAndContrast(
      decoded,
      brightness: _brightness,
      contrast: _contrast,
    );
    final output = Uint8List.fromList(img.encodeJpg(enhanced, quality: 82));
    final updated = await _persistEditedImage(output, 'enhanced');
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = updated;
      _displayedBytes = _displayedBytes ?? output;
      _enhancementBaseFile ??= source;
      _hasUnsavedChanges = true;
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
    final nextBytes = await nextFile.readAsBytes();
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = nextFile;
      _displayedBytes = nextBytes;
      _enhancementBaseFile = null;
      _hasUnsavedChanges = true;
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
    final output = Uint8List.fromList(img.encodeJpg(rotated, quality: 82));
    final updated = await _persistEditedImage(output, 'rotated');
    if (mounted) {
      setState(() {
        _showOriginal = false;
        _currentFile = updated;
        _displayedBytes = output;
        _enhancementBaseFile = null;
        _hasUnsavedChanges = true;
      });
    }
  }

  Future<void> _resetImage() async {
    final originalBytes = await _sourceFile.readAsBytes();
    if (!mounted) return;
    setState(() {
      _brightness = 0;
      _contrast = 0;
      _showOriginal = false;
      _currentFile = _sourceFile;
      _displayedBytes = originalBytes;
      _enhancementBaseFile = null;
      _hasUnsavedChanges = false;
    });
  }

  Future<void> _addSignature() async {
    final signatureBytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => const SignatureDialog(),
    );
    if (!mounted || signatureBytes == null || signatureBytes.isEmpty) return;

    final source = _showOriginal ? _sourceFile : _currentFile;
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
      _displayedBytes = _displayedBytes ?? placedBytes;
      _enhancementBaseFile = null;
      _hasUnsavedChanges = true;
    });
  }

  Future<void> _addText() async {
    await _addTextAnnotation();
  }

  Future<void> _addWatermark() async {
    await _addTextAnnotation(isWatermark: true);
  }

  Future<void> _addTextAnnotation({bool isWatermark = false}) async {
    final options = await showDialog<TextAnnotationOptions>(
      context: context,
      builder: (_) => TextEntryDialog(isWatermark: isWatermark),
    );
    if (!context.mounted || options == null || options.text.trim().isEmpty) {
      return;
    }

    final source = _showOriginal ? _sourceFile : _currentFile;
    final imageBytes = await source.readAsBytes();
    if (!context.mounted) return;
    final placementContext = context;
    final placedBytes = await showDialog<Uint8List>(
      context: placementContext,
      builder: (_) => TextPlacementDialog(
        imageBytes: imageBytes,
        options: options,
        isWatermark: isWatermark,
      ),
    );
    if (!mounted || placedBytes == null || placedBytes.isEmpty) return;

    final updated = await _persistEditedImage(placedBytes, 'text');
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = updated;
      _displayedBytes = _displayedBytes ?? placedBytes;
      _enhancementBaseFile = null;
      _hasUnsavedChanges = true;
    });
  }

  Future<void> _addImage() async {
    final selectedImage = await ImagePicker().pickImage(
      source: ImageSource.gallery,
    );
    if (!mounted || selectedImage == null) return;

    final source = _showOriginal ? _sourceFile : _currentFile;
    final imageBytes = await source.readAsBytes();
    final overlayBytes = await File(selectedImage.path).readAsBytes();
    if (!mounted) return;

    final placedBytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => ImagePlacementDialog(
        imageBytes: imageBytes,
        overlayBytes: overlayBytes,
      ),
    );
    if (!mounted || placedBytes == null || placedBytes.isEmpty) return;

    final updated = await _persistEditedImage(placedBytes, 'image_overlay');
    if (!mounted) return;
    setState(() {
      _showOriginal = false;
      _currentFile = updated;
      _displayedBytes = _displayedBytes ?? placedBytes;
      _enhancementBaseFile = null;
      _hasUnsavedChanges = true;
    });
  }

  Future<bool> _confirmImageChange() async {
    if (!_hasUnsavedChanges) return true;

    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save changes?'),
        content: const Text(
          'This image has unsaved changes. Save them before moving to another image?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'save'),
            child: const Text('Save and continue'),
          ),
        ],
      ),
    );

    if (!mounted || choice == null || choice == 'cancel') return false;
    if (choice == 'save') {
      final bytes = await _currentFile.readAsBytes();
      await _sourceFile.writeAsBytes(compressEditedImage(bytes, quality: 82));
      await FileImage(_sourceFile).evict();
    }
    return true;
  }

  Future<void> _showAdjacentImage(int direction) async {
    if (_isBusy) return;
    final nextIndex = _imageIndex + direction;
    if (nextIndex < 0 || nextIndex >= _files.length) return;
    if (!await _confirmImageChange() || !mounted) return;

    final nextFile = _files[nextIndex];
    final nextBytes = await nextFile.readAsBytes();
    if (!mounted) return;
    setState(() {
      _imageIndex = nextIndex;
      _currentFile = nextFile;
      _displayedBytes = nextBytes;
      _brightness = 0;
      _contrast = 0;
      _showOriginal = false;
      _hasUnsavedChanges = false;
      _enhancementBaseFile = null;
    });
  }

  void _handlePreviewSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 150) return;
    _showAdjacentImage(velocity < 0 ? 1 : -1);
  }

  Future<void> _saveImage() async {
    if (_isBusy) return;
    if (!_hasUnsavedChanges) {
      Navigator.pop(
        context,
        EditedImageResult(sourceFile: _sourceFile, editedFile: _sourceFile),
      );
      return;
    }

    setState(() {
      _isBusy = true;
      _showBusySpinner = true;
    });
    try {
      final savedFile = await runWithProgressDialog(
        context,
        message: 'Saving image...',
        action: () async {
          final updatedBytes = await _currentFile.readAsBytes();
          return _persistEditedImage(updatedBytes, 'saved');
        },
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        EditedImageResult(sourceFile: _sourceFile, editedFile: savedFile),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _showBusySpinner = false;
        });
      }
    }
  }

  Future<void> _recognizeText() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OCR is available on Android and iOS only.'),
        ),
      );
      return;
    }

    await _runAction(() async {
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      try {
        final source = _showOriginal ? _sourceFile : _currentFile;
        final recognizedText = await recognizer.processImage(
          InputImage.fromFilePath(source.path),
        );
        if (!mounted) return;

        await showDialog<void>(
          context: context,
          builder: (_) => OcrTextDialog(text: recognizedText.text),
        );
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('OCR failed: $error')));
      } finally {
        await recognizer.close();
      }
    }, showSpinner: false);
  }

  Widget _buildEditAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton.filled(
      tooltip: tooltip,
      onPressed: _isBusy ? null : onPressed,
      icon: _isBusy && _showBusySpinner
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = _currentFile.existsSync();
    final displayedFile = _showOriginal ? _sourceFile : _currentFile;
    final previewBytes = !_showOriginal ? _displayedBytes : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit image'),
        actions: [
          IconButton(
            tooltip: 'Recognize text',
            onPressed: canEdit && !_isBusy ? _recognizeText : null,
            icon: const Icon(Icons.text_snippet_outlined),
          ),
          IconButton(
            tooltip: 'Save changes',
            onPressed: canEdit && !_isBusy ? _saveImage : null,
            icon: _isBusy && _showBusySpinner
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
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
                      onPressed: () =>
                          _runAction(_addSignature, showSpinner: false),
                    ),
                    _buildEditAction(
                      icon: Icons.text_fields,
                      tooltip: 'Text',
                      onPressed: () => _runAction(_addText, showSpinner: false),
                    ),
                    _buildEditAction(
                      icon: Icons.branding_watermark,
                      tooltip: 'Watermark',
                      onPressed: () =>
                          _runAction(_addWatermark, showSpinner: false),
                    ),
                    _buildEditAction(
                      icon: Icons.add_photo_alternate_outlined,
                      tooltip: 'Add image',
                      onPressed: () =>
                          _runAction(_addImage, showSpinner: false),
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
                      ? GestureDetector(
                          key: const ValueKey('edit-image-preview'),
                          onHorizontalDragEnd: _handlePreviewSwipe,
                          child: previewBytes != null
                              ? Image.memory(previewBytes, fit: BoxFit.contain)
                              : Image.file(displayedFile, fit: BoxFit.contain),
                        )
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
                          onChanged: _isBusy
                              ? null
                              : (value) =>
                                    setState(() => _brightness = value.round()),
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
                          onChanged: _isBusy
                              ? null
                              : (value) =>
                                    setState(() => _contrast = value.round()),
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

class OcrTextDialog extends StatelessWidget {
  final String text;

  const OcrTextDialog({required this.text, super.key});

  Future<void> _copyText(BuildContext context) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Text copied.')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Recognized text'),
      content: SizedBox(
        width: 420,
        height: 300,
        child: text.trim().isEmpty
            ? const Center(child: Text('No text was found in this image.'))
            : SingleChildScrollView(child: SelectableText(text)),
      ),
      actions: [
        TextButton(
          onPressed: text.trim().isEmpty ? null : () => _copyText(context),
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
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
  bool _isApplying = false;

  Future<void> _apply() async {
    if (_isApplying || _points.whereType<Offset>().length < 2) return;
    setState(() => _isApplying = true);

    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || byteData == null) return;
      if (!mounted) return;
      Navigator.pop(context, byteData.buffer.asUint8List());
    } finally {
      if (mounted) {
        setState(() => _isApplying = false);
      }
    }
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
        FilledButton(
          onPressed: _isApplying ? null : _apply,
          child: _isApplying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Apply'),
        ),
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
  bool _isApplying = false;

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
    final nextHeight =
        nextWidth *
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
    if (_isApplying || image == null || signature == null) return;
    setState(() => _isApplying = true);

    try {
      final targetWidth = (image.width * _widthFraction).round().clamp(
        1,
        image.width,
      );
      final resizedSignature = img.copyResize(signature, width: targetWidth);
      final targetX = (image.width * _leftFraction).round();
      final targetY = (image.height * _topFraction).round();
      img.compositeImage(image, resizedSignature, dstX: targetX, dstY: targetY);
      if (!mounted) return;
      Navigator.pop(
        context,
        Uint8List.fromList(img.encodeJpg(image, quality: 100)),
      );
    } finally {
      if (mounted) {
        setState(() => _isApplying = false);
      }
    }
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
            final canvasSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
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
        FilledButton(
          onPressed: _isApplying ? null : _apply,
          child: _isApplying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Apply'),
        ),
      ],
    );
  }
}

class ImagePlacementDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final Uint8List overlayBytes;

  const ImagePlacementDialog({
    required this.imageBytes,
    required this.overlayBytes,
    super.key,
  });

  @override
  State<ImagePlacementDialog> createState() => _ImagePlacementDialogState();
}

class _ImagePlacementDialogState extends State<ImagePlacementDialog> {
  late final img.Image? _image;
  late final img.Image? _overlay;
  double _leftFraction = 0.36;
  double _topFraction = 0.36;
  double _widthFraction = 0.28;
  bool _isApplying = false;

  @override
  void initState() {
    super.initState();
    _image = img.decodeImage(widget.imageBytes);
    _overlay = img.decodeImage(widget.overlayBytes);
    final image = _image;
    final overlay = _overlay;
    if (image != null && overlay != null) {
      final maximumWidth =
          0.8 * (overlay.width / overlay.height) / (image.width / image.height);
      if (maximumWidth < _widthFraction) _widthFraction = maximumWidth;
      _leftFraction = (1 - _widthFraction) / 2;
      _topFraction = (1 - _overlayHeightFraction()) / 2;
    }
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

  double _overlayHeightFraction() {
    final image = _image;
    final overlay = _overlay;
    if (image == null || overlay == null) return 0;
    return _widthFraction *
        (image.width / image.height) /
        (overlay.width / overlay.height);
  }

  Rect _overlayRect(Rect imageRect) {
    final overlay = _overlay;
    if (overlay == null) return Rect.zero;
    final width = imageRect.width * _widthFraction;
    final height = width * overlay.height / overlay.width;
    return Rect.fromLTWH(
      imageRect.left + imageRect.width * _leftFraction,
      imageRect.top + imageRect.height * _topFraction,
      width,
      height,
    );
  }

  void _moveOverlay(DragUpdateDetails details, Rect imageRect) {
    final heightFraction = _overlayHeightFraction();
    setState(() {
      _leftFraction = (_leftFraction + details.delta.dx / imageRect.width)
          .clamp(0.0, 1.0 - _widthFraction)
          .toDouble();
      _topFraction = (_topFraction + details.delta.dy / imageRect.height)
          .clamp(0.0, 1.0 - heightFraction)
          .toDouble();
    });
  }

  void _resizeOverlay(DragUpdateDetails details, Rect imageRect) {
    final image = _image;
    final overlay = _overlay;
    if (image == null || overlay == null || imageRect.isEmpty) return;
    final imageAspect = image.width / image.height;
    final overlayAspect = overlay.width / overlay.height;
    final maximumWidth = (0.9 * overlayAspect / imageAspect).clamp(0.001, 0.9);
    final nextWidth = (_widthFraction + details.delta.dx / imageRect.width)
        .clamp(maximumWidth < 0.08 ? maximumWidth : 0.08, maximumWidth)
        .toDouble();
    setState(() {
      _widthFraction = nextWidth;
      _leftFraction = _leftFraction.clamp(0.0, 1.0 - nextWidth).toDouble();
      _topFraction = _topFraction
          .clamp(0.0, 1.0 - _overlayHeightFraction())
          .toDouble();
    });
  }

  Future<void> _apply() async {
    final image = _image;
    final overlay = _overlay;
    if (_isApplying || image == null || overlay == null) return;
    setState(() => _isApplying = true);

    try {
      final targetWidth = (image.width * _widthFraction).round().clamp(
        1,
        image.width,
      );
      final resizedOverlay = img.copyResize(overlay, width: targetWidth);
      final targetX = (image.width * _leftFraction).round().clamp(
        0,
        image.width - resizedOverlay.width,
      );
      final targetY = (image.height * _topFraction).round().clamp(
        0,
        image.height - resizedOverlay.height,
      );
      img.compositeImage(image, resizedOverlay, dstX: targetX, dstY: targetY);
      if (!mounted) return;
      Navigator.pop(
        context,
        Uint8List.fromList(img.encodeJpg(image, quality: 100)),
      );
    } finally {
      if (mounted) {
        setState(() => _isApplying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null || _overlay == null) {
      return AlertDialog(
        title: const Text('Place image'),
        content: const Text('The selected image could not be read.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Place image'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final imageRect = _imageRect(
              Size(constraints.maxWidth, constraints.maxHeight),
            );
            final overlayRect = _overlayRect(imageRect);
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black12,
                    child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                  ),
                ),
                Positioned.fromRect(
                  rect: overlayRect,
                  child: GestureDetector(
                    key: const ValueKey('image-overlay'),
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) => _moveOverlay(details, imageRect),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: Image.memory(
                            widget.overlayBytes,
                            fit: BoxFit.fill,
                          ),
                        ),
                        Positioned(
                          right: -10,
                          bottom: -10,
                          child: GestureDetector(
                            key: const ValueKey('image-overlay-resize'),
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) =>
                                _resizeOverlay(details, imageRect),
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
        FilledButton(
          onPressed: _isApplying ? null : _apply,
          child: _isApplying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Apply'),
        ),
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
  final bool isWatermark;

  const TextEntryDialog({this.isWatermark = false, super.key});

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

  @override
  void initState() {
    super.initState();
    if (widget.isWatermark) {
      _controller.text = 'WATERMARK';
      _opacity = 0.35;
      _alignment = TextAlign.center;
    }
  }

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
      title: Text(widget.isWatermark ? 'Add watermark' : 'Add text'),
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
              onChanged: (value) =>
                  setState(() => _fontFamily = value ?? 'Default'),
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
                DropdownMenuItem(
                  value: TextAlign.center,
                  child: Text('Center'),
                ),
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
  final bool isWatermark;

  const TextPlacementDialog({
    required this.imageBytes,
    required this.options,
    this.isWatermark = false,
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
  bool _isApplying = false;

  @override
  void initState() {
    super.initState();
    _image = img.decodeImage(widget.imageBytes);
    _fontFraction = widget.options.fontSize / 600;
    if (widget.isWatermark) {
      _leftFraction = 0.1;
      _topFraction = 0.42;
    }
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
          fontWeight: widget.options.bold ? FontWeight.bold : FontWeight.normal,
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
          .clamp(
            0.0,
            ((imageRect.right - textRect.width - imageRect.left) /
                    imageRect.width)
                .clamp(0.0, 1.0),
          )
          .toDouble();
      _topFraction = (_topFraction + details.delta.dy / imageRect.height)
          .clamp(
            0.0,
            ((imageRect.bottom - textRect.height - imageRect.top) /
                    imageRect.height)
                .clamp(0.0, 1.0),
          )
          .toDouble();
    });
  }

  void _resizeText(DragUpdateDetails details, Rect imageRect) {
    final nextFontFraction = _fontFraction + details.delta.dx / imageRect.width;
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
    if (_isApplying || image == null) return;
    setState(() => _isApplying = true);

    try {
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
      Navigator.pop(
        context,
        Uint8List.fromList(img.encodeJpg(image, quality: 100)),
      );
    } finally {
      if (mounted) {
        setState(() => _isApplying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return AlertDialog(
        title: Text(widget.isWatermark ? 'Place watermark' : 'Place text'),
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
      title: Text(widget.isWatermark ? 'Place watermark' : 'Place text'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
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
        FilledButton(
          onPressed: _isApplying ? null : _apply,
          child: _isApplying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Apply'),
        ),
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
    final documents = rootDirectory
        .listSync()
        .whereType<Directory>()
        .map(DocumentFolder.new)
        .where(
          (document) =>
              document.images.isNotEmpty || document.pdfFile.existsSync(),
        )
        .toList();
    for (final document in documents) {
      await document.preserveCreatedDate();
    }
    documents.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return documents;
  }

  Stream<List<DocumentFolder>> documentBatches({int batchSize = 12}) async* {
    final rootDirectory = await root();
    final batch = <DocumentFolder>[];

    await for (final entity in rootDirectory.list()) {
      if (entity is! Directory) continue;

      final document = DocumentFolder(entity);
      if (document.images.isEmpty && !document.pdfFile.existsSync()) continue;
      await document.preserveCreatedDate();

      batch.add(document);
      if (batch.length < batchSize) continue;

      batch.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      yield List<DocumentFolder>.from(batch);
      batch.clear();
      await Future<void>.delayed(Duration.zero);
    }

    if (batch.isNotEmpty) {
      batch.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      yield List<DocumentFolder>.from(batch);
    }
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
    final document = DocumentFolder(directory);
    await document.preserveCreatedDate();
    return document;
  }

  Future<DocumentFolder> importFile(
    File source,
    String originalName, {
    void Function(int)? onProgress,
  }) async {
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
        await _importPdfPages(source, document, onProgress: onProgress);
      } else {
        await source.copy(path.join(document.directory.path, '1$extension'));
        onProgress?.call(100);
      }
    } catch (_) {
      await document.directory.delete(recursive: true);
      rethrow;
    }

    return document;
  }

  Future<void> _importPdfPages(
    File source,
    DocumentFolder document, {
    void Function(int)? onProgress,
  }) async {
    final pdfFile = await source.copy(document.pdfFile.path);
    final pdfDocument = await PdfDocument.openFile(pdfFile.path);
    try {
      for (
        var pageNumber = 1;
        pageNumber <= pdfDocument.pagesCount;
        pageNumber++
      ) {
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
          onProgress?.call((pageNumber * 100 / pdfDocument.pagesCount).round());
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
    final document = DocumentFolder(directory);
    await document.preserveCreatedDate();
    return document;
  }

  Future<void> mergeDocuments(List<DocumentFolder> selectedDocuments) async {
    if (selectedDocuments.length < 2) {
      throw const FormatException('Select at least two documents to merge');
    }

    final winner = selectedDocuments.first;
    final losers = selectedDocuments.skip(1).toList();
    var nextIndex =
        winner.images
            .map(
              (file) => int.tryParse(path.basenameWithoutExtension(file.path)),
            )
            .whereType<int>()
            .fold<int>(
              0,
              (highest, value) => value > highest ? value : highest,
            ) +
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
    await runWithProgressDialog(
      context,
      message: 'Saving settings...',
      action: () async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('home_sort_field', _sortField);
        await preferences.setBool('home_sort_ascending', _sortAscending);
        await preferences.setBool('home_grid_view', _gridView);
      },
    );
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
                  DropdownMenuItem(
                    value: 'created',
                    child: Text('Created date'),
                  ),
                  DropdownMenuItem(
                    value: 'modified',
                    child: Text('Modified date'),
                  ),
                ],
                onChanged: (value) =>
                    setDialogState(() => field = value ?? 'name'),
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
    final isInitialLoad = documents.isEmpty;
    if (mounted && isInitialLoad) {
      setState(() => loading = true);
    }

    try {
      final loadedDocuments = <DocumentFolder>[];
      await for (final batch in storage.documentBatches()) {
        loadedDocuments.addAll(batch);
        if (!mounted) return;
        setState(() {
          documents = List<DocumentFolder>.from(loadedDocuments);
          loading = false;
        });
      }

      if (!mounted) return;
      setState(() {
        documents = loadedDocuments;
        loading = false;
      });
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
    var progressDialogShown = false;
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
      if (sources.isEmpty) return;

      showGeneratingDialog(context, message: 'Importing...');
      progressDialogShown = true;
      DocumentFolder? importedDocument;
      for (var index = 0; index < sources.length; index++) {
        final file = sources[index];
        final sourcePath = file['path'] as String?;
        if (sourcePath == null) continue;
        final source = File(sourcePath);
        final name = file['name'] as String? ?? 'Document';
        final document = await storage.importFile(
          source,
          name,
          onProgress: (progress) {
            _generatingProgress.value =
                ((index * 100 + progress) / sources.length).round();
          },
        );
        importedDocument ??= document;
        await source.delete();
      }
      _generatingProgress.value = 100;
      if (progressDialogShown && mounted) {
        hideGeneratingDialog(context);
        progressDialogShown = false;
      }
      _message('Document imported.');
      if (importedDocument != null && mounted) {
        await _openDocument(importedDocument);
      } else {
        await _refresh();
      }
    } on PlatformException catch (error) {
      _message('Could not open document: ${error.message ?? error.code}');
    } catch (error) {
      _message('Could not import document: $error');
    } finally {
      if (progressDialogShown && mounted) {
        hideGeneratingDialog(context);
      }
    }
  }

  Future<void> _addToNewDocument(ImageSource source) async {
    final document = await storage.createDocument();
    if (!mounted) return;

    try {
      if (source == ImageSource.gallery) {
        final selectedImages = await ImagePicker().pickMultiImage();
        if (!mounted) return;
        if (selectedImages.isEmpty) {
          await document.directory.delete(recursive: true);
          return;
        }

        await runWithProgressDialog(
          context,
          message: 'Saving images...',
          action: () async {
            var nextIndex = 1;
            for (final selectedImage in selectedImages) {
              final extension = path
                  .extension(selectedImage.name)
                  .toLowerCase();
              final safeExtension =
                  ['.jpg', '.jpeg', '.png', '.heic'].contains(extension)
                  ? extension
                  : '.jpg';
              final target = File(
                path.join(
                  document.directory.path,
                  '${nextIndex++}$safeExtension',
                ),
              );
              final bytes = await selectedImage.readAsBytes();
              if (bytes.isEmpty) continue;
              await target.writeAsBytes(bytes);
            }
          },
        );

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
        if (!mounted) return;
        if (scannedPaths == null || scannedPaths.isEmpty) {
          await document.directory.delete(recursive: true);
          return;
        }

        await runWithProgressDialog(
          context,
          message: 'Saving scanned pages...',
          action: () async {
            var nextIndex = 1;
            for (final scannedPath in scannedPaths) {
              final scannedFile = File(scannedPath);
              if (!await scannedFile.exists()) continue;

              final target = File(
                path.join(document.directory.path, '${nextIndex++}.jpg'),
              );
              await scannedFile.copy(target.path);
            }
          },
        );

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
            child: const Text('Save'),
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
    if (!mounted) return;
    await runWithProgressDialog(
      context,
      message: 'Renaming document...',
      action: () async {
        await document.directory.rename(destination.path);
        await _refresh();
      },
    );
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

    if (confirmed != true || !mounted) return;

    await runWithProgressDialog(
      context,
      message: 'Deleting document...',
      action: () async {
        if (await document.directory.exists()) {
          await document.directory.delete(recursive: true);
        }
        await _refresh();
      },
    );
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

    if (confirmed != true || !mounted) return;

    await runWithProgressDialog(
      context,
      message: 'Deleting documents...',
      action: () async {
        for (final document in _selectedDocuments.toList()) {
          if (await document.directory.exists()) {
            await document.directory.delete(recursive: true);
          }
        }
        _clearSelection();
        await _refresh();
      },
    );
  }

  Future<void> _shareSelectedDocuments() async {
    if (_selectedDocuments.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';
    Future<int> calculateEstimate() => estimateExportSizeForImages(
      images: _selectedDocuments.expand((document) => document.images).toList(),
      fileType: fileType,
      fileSize: fileSize,
    );
    var exportEstimate = calculateEstimate();

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
                        setDialogState(() {
                          fileType = nextType;
                          exportEstimate = calculateEstimate();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: InputDecoration(
                        labelText: fileType == 'pdf'
                            ? 'PDF output size'
                            : 'JPG output size',
                      ),
                      items: buildExportSizeItems(),
                      onChanged: (value) => setDialogState(() {
                        fileSize = value ?? 'Actual';
                        exportEstimate = calculateEstimate();
                      }),
                    ),
                    const SizedBox(height: 4),
                    ExportSizeEstimate(estimate: exportEstimate),
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
      await runWithProgressDialog(
        context,
        message: 'Merging documents...',
        action: () async {
          await storage.mergeDocuments(_selectedDocuments);
          _clearSelection();
          await _refresh();
        },
      );
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

  Widget _buildGridDocumentCard(BuildContext context, DocumentFolder document) {
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
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.8),
                    ],
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
                    leading: Icon(
                      _gridView ? Icons.view_list : Icons.grid_view,
                    ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _addToNewDocument(ImageSource.camera),
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
                        _isMultiSelectMode ? (isNarrowLayout ? 100 : 120) : 100,
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
                        _isMultiSelectMode ? (isNarrowLayout ? 100 : 120) : 100,
                      ),
                      itemCount: _filteredDocuments.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final document = _filteredDocuments[index];
                        final selected = _selectedDocuments.contains(document);
                        final documentImages = document.images;
                        final firstImage = documentImages.firstOrNull;
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
                            '${documentImages.length} picture${documentImages.length == 1 ? '' : 's'} • ${formatByteSize(document.sizeBytes)}',
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
                children: [Icon(icon), const SizedBox(height: 2), Text(label)],
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

int estimateExportSizeBytes({
  required List<int> sourceFileSizes,
  required String fileType,
  required String fileSize,
}) {
  final sourceBytes = sourceFileSizes.fold<int>(
    0,
    (total, size) => total + size,
  );
  if (sourceBytes == 0) return 0;

  final scaleRatio =
      exportScaleForSize(fileSize) / exportScaleForSize('Actual');
  final qualityRatio =
      exportQualityForSize(fileSize) / exportQualityForSize('Actual');
  final encodedBytes = sourceBytes * scaleRatio * scaleRatio * qualityRatio;
  final containerBytes = fileType.toLowerCase() == 'pdf'
      ? sourceFileSizes.length * 1024 + 512
      : 2048;
  return encodedBytes.round() + containerBytes;
}

Future<int> estimateExportSizeForImages({
  required List<File> images,
  required String fileType,
  required String fileSize,
}) async {
  final sourceFileSizes = await Future.wait(
    images.map((image) => image.length()),
  );
  return estimateExportSizeBytes(
    sourceFileSizes: sourceFileSizes,
    fileType: fileType,
    fileSize: fileSize,
  );
}

class ExportSizeEstimate extends StatelessWidget {
  const ExportSizeEstimate({required this.estimate, super.key});

  final Future<int> estimate;

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: estimate,
    builder: (context, snapshot) {
      final message = snapshot.hasError
          ? 'Approximate file size unavailable'
          : snapshot.hasData
          ? 'Approximate file size: ~${formatByteSize(snapshot.data!)}'
          : 'Estimating file size...';
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    },
  );
}

List<DropdownMenuItem<String>> buildExportSizeItems() => exportSizeOptions
    .entries
    .map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.key)))
    .toList();

double exportScaleForDimensions({
  required int width,
  required int height,
  required double requestedScale,
}) {
  const maxExportDimension = 1800;
  final longestDimension = width > height ? width : height;
  final resolutionScale = longestDimension > maxExportDimension
      ? maxExportDimension / longestDimension
      : 1.0;
  return requestedScale.clamp(0.01, 1.0).toDouble() * resolutionScale;
}

bool shouldKeepOriginalJpegExport({
  required double scaleFactor,
  required int quality,
  required int width,
  required int height,
}) {
  return scaleFactor >= 1.0 &&
      quality >= 100 &&
      width <= 1800 &&
      height <= 1800;
}

bool shouldEmbedOriginalJpegInPdf({
  required double scaleFactor,
  required int quality,
}) {
  return scaleFactor >= 1.0 && quality >= 100;
}

bool shouldRunExportInline({
  required int imageCount,
  required String fileType,
  required double scaleFactor,
  required int quality,
}) {
  final normalizedType = fileType.toLowerCase();
  final actualQuality = scaleFactor >= 0.95 && quality >= 95;

  if (normalizedType == 'jpg' && imageCount <= 1) {
    return true;
  }

  if (imageCount <= 3 && actualQuality) {
    return true;
  }

  return false;
}

Future<File> _generateExportFile({
  required List<File> images,
  required String fileType,
  required File outputFile,
  required double scaleFactor,
  required int quality,
  void Function(int)? onProgress,
}) async {
  final embedsOriginalJpegPages =
      fileType.toLowerCase() == 'pdf' &&
      images.length <= 3 &&
      scaleFactor >= 1.0 &&
      quality >= 100 &&
      images.every((file) {
        final extension = path.extension(file.path).toLowerCase();
        return extension == '.jpg' || extension == '.jpeg';
      });
  final shouldInline =
      embedsOriginalJpegPages ||
      shouldRunExportInline(
        imageCount: images.length,
        fileType: fileType,
        scaleFactor: scaleFactor,
        quality: quality,
      );

  final progressPort = ReceivePort();
  final progressSubscription = progressPort.listen((message) {
    if (message is int) onProgress?.call(message);
  });
  final arguments = <String, Object?>{
    'imagePaths': images.map((image) => image.path).toList(),
    'fileType': fileType,
    'outputPath': outputFile.path,
    'scaleFactor': scaleFactor,
    'quality': quality,
    'progressPort': progressPort.sendPort,
  };

  try {
    if (shouldInline) {
      await _generateExportFileInBackground(arguments);
    } else {
      await compute<Map<String, Object?>, String>(
        _generateExportFileInBackground,
        arguments,
      );
    }
  } finally {
    await progressSubscription.cancel();
    progressPort.close();
  }

  return outputFile;
}

Future<String> _generateExportFileInBackground(
  Map<String, Object?> arguments,
) async {
  final images = (arguments['imagePaths'] as List<String>)
      .map(File.new)
      .toList();
  final fileType = arguments['fileType'] as String;
  final outputFile = File(arguments['outputPath'] as String);
  final scaleFactor = arguments['scaleFactor'] as double;
  final quality = arguments['quality'] as int;
  final progressPort = arguments['progressPort'] as SendPort?;
  void reportProgress(int progress) {
    progressPort?.send(progress.clamp(0, 100));
  }

  if (images.isEmpty) {
    throw const FormatException('No images available for export');
  }

  reportProgress(1);

  if (fileType.toLowerCase() == 'jpg') {
    if (images.length == 1) {
      final bytes = await images.single.readAsBytes();
      if (img.JpegDecoder().isValidFile(bytes)) {
        final jpeg = pw.MemoryImage(bytes);
        if (jpeg.width != null &&
            jpeg.height != null &&
            shouldKeepOriginalJpegExport(
              scaleFactor: scaleFactor,
              quality: quality,
              width: jpeg.width!,
              height: jpeg.height!,
            )) {
          await outputFile.writeAsBytes(bytes);
          reportProgress(100);
          return outputFile.path;
        }
      }
    }

    final decodedImages = <img.Image>[];
    for (var index = 0; index < images.length; index++) {
      final imageFile = images[index];
      final bytes = await imageFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        decodedImages.add(_scaleExportImage(decoded, scaleFactor));
      }
      reportProgress(5 + ((index + 1) * 80 / images.length).round());
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
    reportProgress(100);
    return outputFile.path;
  }

  final pdf = pw.Document();
  final pageFormat = pdf_lib.PdfPageFormat.standard;

  for (var index = 0; index < images.length; index++) {
    final imageFile = images[index];
    final bytes = await imageFile.readAsBytes();
    pw.ImageProvider imageProvider;
    final isActualJpeg = img.JpegDecoder().isValidFile(bytes);
    if (isActualJpeg) {
      imageProvider = pw.MemoryImage(
        shouldEmbedOriginalJpegInPdf(scaleFactor: scaleFactor, quality: quality)
            ? bytes
            : _resizeJpegForPdf(
                bytes,
                scaleFactor: scaleFactor,
                quality: quality,
              ),
      );
    } else {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) continue;
      final scaledImage = _scaleExportImage(decoded, scaleFactor);
      imageProvider = pw.MemoryImage(
        Uint8List.fromList(img.encodeJpg(scaledImage, quality: quality)),
      );
    }

    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (_) => pw.Center(
          child: pw.Image(
            imageProvider,
            fit: pw.BoxFit.contain,
            width: pageFormat.width,
            height: pageFormat.height,
          ),
        ),
      ),
    );
    reportProgress(5 + ((index + 1) * 85 / images.length).round());
  }

  await outputFile.writeAsBytes(await pdf.save());
  reportProgress(100);
  return outputFile.path;
}

Uint8List _resizeJpegForPdf(
  Uint8List bytes, {
  required double scaleFactor,
  required int quality,
}) {
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    try {
      final info = bicubic.BicubicResizer.getImageInfo(bytes);
      final scale = exportScaleForDimensions(
        width: info.orientedWidth,
        height: info.orientedHeight,
        requestedScale: scaleFactor,
      );
      final width = (info.orientedWidth * scale).round().clamp(
        1,
        info.orientedWidth,
      );
      final height = (info.orientedHeight * scale).round().clamp(
        1,
        info.orientedHeight,
      );
      return bicubic.BicubicResizer.resizeJpeg(
        jpegBytes: bytes,
        outputWidth: width,
        outputHeight: height,
        quality: quality,
        cropAspectRatio: bicubic.CropAspectRatio.original,
      );
    } catch (_) {
      // Fall back to the Dart encoder if native processing is unavailable.
    }
  }

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Could not decode JPEG image');
  }
  final scaledImage = _scaleExportImage(decoded, scaleFactor);
  return Uint8List.fromList(img.encodeJpg(scaledImage, quality: quality));
}

img.Image _scaleExportImage(img.Image source, double scaleFactor) {
  final effectiveScale = exportScaleForDimensions(
    width: source.width,
    height: source.height,
    requestedScale: scaleFactor,
  );
  if (effectiveScale >= 1) return source;
  return img.copyResize(
    source,
    width: (source.width * effectiveScale).round().clamp(1, source.width),
    height: (source.height * effectiveScale).round().clamp(1, source.height),
  );
}

Future<String> saveToPublicDownloads({
  required String fileName,
  required File sourceFile,
  required String mimeType,
}) async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('scanner_pro/downloads');
    try {
      final savedPath = await channel.invokeMethod<String>('saveFile', {
        'fileName': fileName,
        'mimeType': mimeType,
        'sourcePath': sourceFile.path,
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
  await sourceFile.copy(outputFile.path);
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
  void Function(int)? onProgress,
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
    onProgress:
        onProgress ?? (progress) => _generatingProgress.value = progress,
  );

  if (!saveToDownloads) {
    return tempFile.path;
  }

  final mimeType = extension == 'jpg' ? 'image/jpeg' : 'application/pdf';

  final targetName = fileNameWithExtension;
  final publicPath = await saveToPublicDownloads(
    fileName: targetName,
    sourceFile: tempFile,
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
  final Set<String> _selectedImages = <String>{};
  late String _currentName;

  List<File> get images => widget.document.images;

  bool get _isImageSelectionMode => _selectedImages.isNotEmpty;

  List<File> get _selectedImageFiles =>
      images.where((file) => _selectedImages.contains(file.path)).toList();

  void _toggleImageSelection(File file) {
    setState(() {
      if (!_selectedImages.add(file.path)) _selectedImages.remove(file.path);
    });
  }

  void _clearImageSelection() {
    setState(_selectedImages.clear);
  }

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
        if (!mounted) return;
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
        final importedCount = await runWithProgressDialog<int>(
          context,
          message: 'Saving images...',
          action: () async {
            var nextIndex = nextIndexStart + 1;
            var count = 0;
            for (final selectedImage in selectedImages) {
              final extension = path
                  .extension(selectedImage.name)
                  .toLowerCase();
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
              count++;
            }
            return count;
          },
        );

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

      if (!mounted) return;
      if (scannedPaths == null || scannedPaths.isEmpty) return;

      final nextIndexStart = images
          .map((file) => int.tryParse(path.basenameWithoutExtension(file.path)))
          .whereType<int>()
          .fold<int>(0, (highest, value) => value > highest ? value : highest);
      await runWithProgressDialog(
        context,
        message: 'Saving scanned pages...',
        action: () async {
          var nextIndex = nextIndexStart + 1;
          for (final scannedPath in scannedPaths) {
            final scannedFile = File(scannedPath);
            if (!await scannedFile.exists()) continue;

            final target = File(
              path.join(widget.document.directory.path, '${nextIndex++}.jpg'),
            );
            await scannedFile.copy(target.path);
          }
        },
      );

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
      MaterialPageRoute(
        builder: (_) => ImageEditorPage(file: file, files: images),
      ),
    );

    if (!mounted) return;
    if (result is! EditedImageResult) {
      setState(() => _imageRefreshToken++);
      return;
    }

    final updated = result.editedFile;
    final target = File(result.sourceFile.path);
    if (updated.path == target.path) return;
    if (!await updated.exists()) return;
    if (!mounted) return;

    await runWithProgressDialog(
      context,
      message: 'Saving image...',
      action: () async {
        final updatedBytes = await updated.readAsBytes();
        await target.writeAsBytes(updatedBytes, flush: true);
        await FileImage(target).evict();
        if (updated.path != target.path && await updated.exists()) {
          await updated.delete();
        }
      },
    );
    if (!mounted) return;
    setState(() => _imageRefreshToken++);
  }

  Future<void> _remove(File file) async {
    if (!await file.exists()) return;
    if (!mounted) return;

    await runWithProgressDialog(
      context,
      message: 'Deleting image...',
      action: file.delete,
    );
    if (!mounted) return;
    if (mounted) {
      setState(() {
        _selectedImages.remove(file.path);
        _imageRefreshToken++;
      });
    }
  }

  Future<void> _deleteSelectedImages() async {
    final selected = _selectedImageFiles;
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete selected images?'),
        content: Text('Delete ${selected.length} selected images?'),
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
    if (confirmed != true || !mounted) return;

    await runWithProgressDialog(
      context,
      message: 'Deleting images...',
      action: () async {
        for (final file in selected) {
          if (await file.exists()) await file.delete();
        }
      },
    );
    if (!mounted) return;
    setState(() {
      _selectedImages.clear();
      _imageRefreshToken++;
    });
  }

  Future<void> _transferSelectedImages({required bool move}) async {
    final selected = _selectedImageFiles;
    if (selected.isEmpty) return;

    final targets = (await StorageService().documents())
        .where(
          (document) =>
              document.directory.path != widget.document.directory.path,
        )
        .toList();
    if (!mounted) return;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create another document first.')),
      );
      return;
    }

    final target = await showDialog<DocumentFolder>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(move ? 'Move images to' : 'Copy images to'),
        content: SizedBox(
          width: 360,
          height: 320,
          child: ListView(
            shrinkWrap: true,
            children: targets
                .map(
                  (document) => ListTile(
                    title: Text(document.name),
                    onTap: () => Navigator.pop(dialogContext, document),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;

    setState(() => processing = true);
    try {
      await runWithProgressDialog(
        context,
        message: move ? 'Moving images...' : 'Copying images...',
        action: () async {
          var nextIndex =
              target.images
                  .map(
                    (file) =>
                        int.tryParse(path.basenameWithoutExtension(file.path)),
                  )
                  .whereType<int>()
                  .fold<int>(
                    0,
                    (highest, value) => value > highest ? value : highest,
                  ) +
              1;
          for (final source in selected) {
            final extension = path.extension(source.path).toLowerCase();
            final destination = File(
              path.join(target.directory.path, '${nextIndex++}$extension'),
            );
            if (move) {
              await source.rename(destination.path);
            } else {
              await source.copy(destination.path);
            }
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _selectedImages.clear();
        _imageRefreshToken++;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${selected.length} image${selected.length == 1 ? '' : 's'} '
            '${move ? 'moved' : 'copied'} to ${target.name}.',
          ),
        ),
      );
      unawaited(
        Navigator.of(context).pushReplacement<void, void>(
          MaterialPageRoute<void>(
            builder: (_) => DocumentPage(document: target),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not ${move ? 'move' : 'copy'} images: $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> _createCollage() async {
    final selected = _selectedImageFiles;
    final layouts = collageLayoutsForImageCount(selected.length);
    if (layouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Collage supports up to 12 images.')),
      );
      return;
    }
    var layout = layouts.first;
    final choice = await showDialog<(int, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Create collage page'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<(int, int)>(
                  initialValue: layout,
                  decoration: const InputDecoration(labelText: 'Grid layout'),
                  items: layouts
                      .map(
                        (option) => DropdownMenuItem(
                          value: option,
                          child: Text('${option.$1} x ${option.$2}'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setDialogState(() => layout = value);
                  },
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _CollageLayoutPreview(
                    key: ValueKey(layout),
                    rows: layout.$1,
                    columns: layout.$2,
                    selectedCount: selected.length,
                  ),
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
              onPressed: () => Navigator.pop(dialogContext, layout),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => processing = true);
    try {
      await runWithProgressDialog(
        context,
        message: 'Creating collage...',
        action: () async {
          const pageWidth = 1800;
          const pageHeight = 2400;
          const margin = 36;
          const gutter = 24;
          final rows = choice.$1;
          final columns = choice.$2;
          final cellWidth =
              (pageWidth - margin * 2 - gutter * (columns - 1)) ~/ columns;
          final cellHeight =
              (pageHeight - margin * 2 - gutter * (rows - 1)) ~/ rows;
          final collage = img.Image(
            width: pageWidth,
            height: pageHeight,
            numChannels: 3,
          );
          img.fill(collage, color: img.ColorRgb8(255, 255, 255));

          for (var index = 0; index < selected.length; index++) {
            final decoded = img.decodeImage(
              await selected[index].readAsBytes(),
            );
            if (decoded == null) {
              throw FormatException(
                'Could not read ${path.basename(selected[index].path)}',
              );
            }
            final scale = (cellWidth / decoded.width).clamp(
              0.0,
              cellHeight / decoded.height,
            );
            final resized = img.copyResize(
              decoded,
              width: (decoded.width * scale).round().clamp(1, cellWidth),
              height: (decoded.height * scale).round().clamp(1, cellHeight),
            );
            final row = index ~/ columns;
            final column = index % columns;
            final x =
                margin +
                column * (cellWidth + gutter) +
                (cellWidth - resized.width) ~/ 2;
            final y =
                margin +
                row * (cellHeight + gutter) +
                (cellHeight - resized.height) ~/ 2;
            img.compositeImage(collage, resized, dstX: x, dstY: y);
          }

          final nextIndex =
              images
                  .map(
                    (file) =>
                        int.tryParse(path.basenameWithoutExtension(file.path)),
                  )
                  .whereType<int>()
                  .fold<int>(
                    0,
                    (highest, value) => value > highest ? value : highest,
                  ) +
              1;
          final output = File(
            path.join(widget.document.directory.path, '$nextIndex.jpg'),
          );
          await output.writeAsBytes(img.encodeJpg(collage, quality: 92));
          if (!mounted) return;
          setState(() {
            _selectedImages.clear();
            _imageRefreshToken++;
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Collage page added.')));
        },
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create collage: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> _reorderImages(String fromPath, String toPath) async {
    final currentImages = images;
    final fromIndex = currentImages.indexWhere((file) => file.path == fromPath);
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
      await runWithProgressDialog(
        context,
        message: 'Reordering images...',
        action: () async {
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
        },
      );
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
          if (reordered) {
            final selectedPaths = <String>{};
            for (var index = 0; index < orderedImages.length; index++) {
              if (_selectedImages.contains(orderedImages[index].path)) {
                selectedPaths.add(
                  path.join(
                    widget.document.directory.path,
                    '${index + 1}${stagedImages[index].extension}',
                  ),
                );
              }
            }
            _selectedImages
              ..clear()
              ..addAll(selectedPaths);
            _imageRefreshToken++;
          }
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
    if (!mounted) return;
    await runWithProgressDialog(
      context,
      message: 'Renaming document...',
      action: () async {
        await widget.document.directory.rename(destination.path);
        widget.document.directory = destination;
      },
    );
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
    List<File>? sourceImages,
    bool saveToDownloads = true,
  }) async {
    return exportDocumentImagesToDownloads(
      images: sourceImages ?? images,
      fileType: fileType,
      fileName: fileName,
      fileSize: fileSize,
      saveToDownloads: saveToDownloads,
    );
  }

  Future<void> _shareDocument({List<File>? selectedImages}) async {
    final imagesToShare = selectedImages ?? images;
    if (imagesToShare.isEmpty) return;

    String fileType = 'pdf';
    String fileSize = 'Actual';
    Future<int> calculateEstimate() => estimateExportSizeForImages(
      images: imagesToShare,
      fileType: fileType,
      fileSize: fileSize,
    );
    var exportEstimate = calculateEstimate();
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
                        setDialogState(() {
                          fileType = nextType;
                          exportEstimate = calculateEstimate();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: InputDecoration(
                        labelText: fileType == 'pdf'
                            ? 'PDF output size'
                            : 'JPG output size',
                      ),
                      items: buildExportSizeItems(),
                      onChanged: (value) => setDialogState(() {
                        fileSize = value ?? 'Actual';
                        exportEstimate = calculateEstimate();
                      }),
                    ),
                    const SizedBox(height: 4),
                    ExportSizeEstimate(estimate: exportEstimate),
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
        sourceImages: imagesToShare,
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
        if (selectedImages != null) _clearImageSelection();
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
    Future<int> calculateEstimate() => estimateExportSizeForImages(
      images: images,
      fileType: fileType,
      fileSize: fileSize,
    );
    var exportEstimate = calculateEstimate();
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
                        setDialogState(() {
                          fileType = nextType;
                          exportEstimate = calculateEstimate();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: InputDecoration(
                        labelText: fileType == 'pdf'
                            ? 'PDF output size'
                            : 'JPG output size',
                      ),
                      items: buildExportSizeItems(),
                      onChanged: (value) => setDialogState(() {
                        fileSize = value ?? 'Actual';
                        exportEstimate = calculateEstimate();
                      }),
                    ),
                    const SizedBox(height: 4),
                    ExportSizeEstimate(estimate: exportEstimate),
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
      leading: _isImageSelectionMode
          ? IconButton(
              tooltip: 'Clear selection',
              onPressed: _clearImageSelection,
              icon: const Icon(Icons.close),
            )
          : null,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final maxTitleWidth = (constraints.maxWidth - 136.0).clamp(
            80.0,
            constraints.maxWidth,
          );
          return ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTitleWidth),
            child: GestureDetector(
              onTap: _isImageSelectionMode ? null : _renameDocument,
              child: Text(
                _isImageSelectionMode
                    ? '${_selectedImages.length} selected'
                    : _currentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
          );
        },
      ),
      actions: [
        if (_isImageSelectionMode)
          PopupMenuButton<String>(
            tooltip: 'Selected image actions',
            enabled: !processing,
            onSelected: (action) {
              switch (action) {
                case 'delete':
                  _deleteSelectedImages();
                case 'move':
                  _transferSelectedImages(move: true);
                case 'copy':
                  _transferSelectedImages(move: false);
                case 'collage':
                  _createCollage();
                case 'share':
                  _shareDocument(
                    selectedImages: List<File>.from(_selectedImageFiles),
                  );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Delete')),
              PopupMenuItem(value: 'move', child: Text('Move')),
              PopupMenuItem(value: 'copy', child: Text('Copy')),
              PopupMenuItem(value: 'collage', child: Text('Collage')),
              PopupMenuItem(value: 'share', child: Text('Share')),
            ],
          ),
        if (!_isImageSelectionMode && images.isNotEmpty)
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
        if (!_isImageSelectionMode && images.isNotEmpty)
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
                            onDragStarted: () {
                              if (!_selectedImages.contains(file.path)) {
                                _toggleImageSelection(file);
                              }
                            },
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
                                border: _selectedImages.contains(file.path)
                                    ? Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        width: 3,
                                      )
                                    : isDropTarget
                                    ? Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
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
                                      onTap: () {
                                        if (_isImageSelectionMode) {
                                          _toggleImageSelection(file);
                                        } else {
                                          _openImageEditor(file);
                                        }
                                      },
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
                                  if (_selectedImages.contains(file.path))
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: CircleAvatar(
                                        radius: 14,
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        child: const Icon(
                                          Icons.check,
                                          size: 18,
                                          color: Colors.white,
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
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
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
                                  if (!_isImageSelectionMode)
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
    if (!mounted) return;

    await runWithProgressDialog(
      context,
      message: 'Renaming document...',
      action: () async {
        await widget.document.directory.rename(destination.path);
        widget.document.directory = destination;
      },
    );

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
    Future<int> calculateEstimate() => estimateExportSizeForImages(
      images: widget.document.images,
      fileType: fileType,
      fileSize: fileSize,
    );
    var exportEstimate = calculateEstimate();
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
                        setDialogState(() {
                          fileType = nextType;
                          exportEstimate = calculateEstimate();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: InputDecoration(
                        labelText: fileType == 'pdf'
                            ? 'PDF output size'
                            : 'JPG output size',
                      ),
                      items: buildExportSizeItems(),
                      onChanged: (value) => setDialogState(() {
                        fileSize = value ?? 'Actual';
                        exportEstimate = calculateEstimate();
                      }),
                    ),
                    const SizedBox(height: 4),
                    ExportSizeEstimate(estimate: exportEstimate),
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
    Future<int> calculateEstimate() => estimateExportSizeForImages(
      images: widget.document.images,
      fileType: fileType,
      fileSize: fileSize,
    );
    var exportEstimate = calculateEstimate();
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
                        setDialogState(() {
                          fileType = nextType;
                          exportEstimate = calculateEstimate();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: fileSize,
                      decoration: InputDecoration(
                        labelText: fileType == 'pdf'
                            ? 'PDF output size'
                            : 'JPG output size',
                      ),
                      items: buildExportSizeItems(),
                      onChanged: (value) => setDialogState(() {
                        fileSize = value ?? 'Actual';
                        exportEstimate = calculateEstimate();
                      }),
                    ),
                    const SizedBox(height: 4),
                    ExportSizeEstimate(estimate: exportEstimate),
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
