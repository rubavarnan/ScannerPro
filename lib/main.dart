import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:pdf/pdf.dart' as pdf_lib;
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const ScannerProApp());

class ScannerProApp extends StatelessWidget {
  const ScannerProApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Scanner Pro',
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

class DocumentFolder {
  Directory directory;
  DocumentFolder(this.directory);

  String get name => path.basename(directory.path);
  File get pdfFile => File(path.join(directory.path, '$name.pdf'));

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
        ..sort((a, b) => a.path.compareTo(b.path));

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
    final source = _showOriginal ? widget.file : _currentFile;
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
    });
  }

  Future<void> _enhanceImage() async {
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
      });
    }
  }

  Future<void> _resetImage() async {
    setState(() {
      _brightness = 0;
      _contrast = 0;
      _showOriginal = false;
      _currentFile = widget.file;
    });
  }

  Future<void> _saveImage() async {
    final updatedBytes = await _currentFile.readAsBytes();
    final savedFile = await _persistEditedImage(updatedBytes, 'saved');
    if (!mounted) return;
    Navigator.pop(context, savedFile);
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
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _isBusy ? null : () => _runAction(_cropImage),
                      child: const Icon(Icons.crop),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isBusy
                          ? null
                          : () => _runAction(_rotateImage),
                      child: const Icon(Icons.rotate_90_degrees_ccw),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isBusy
                          ? null
                          : () => _runAction(_enhanceImage),
                      child: const Icon(Icons.auto_fix_high),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isBusy ? null : () => _runAction(_resetImage),
                      child: const Icon(Icons.restart_alt),
                    ),
                  ),
                ],
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
    if (Platform.isAndroid) {
      final permission = await Permission.manageExternalStorage.status;
      if (!permission.isGranted)
        await Permission.manageExternalStorage.request();
    }
    final root = Platform.isAndroid
        ? Directory('/storage/emulated/0/Documents/Scanner Pro')
        : Directory(path.join(Directory.current.path, 'Scanner Pro'));
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
  final Set<DocumentFolder> _selectedDocuments = <DocumentFolder>{};

  List<DocumentFolder> get _filteredDocuments {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return documents;
    return documents
        .where((document) => document.name.toLowerCase().contains(query))
        .toList();
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => loading = true);
    try {
      await storage.root();
      documents = await storage.documents();
    } catch (error) {
      _message('Storage could not be prepared: $error');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _newDocument() async {
    final document = await storage.createDocument();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DocumentPage(document: document)),
    );
    _refresh();
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
                        documentTotalBytes(
                          _selectedDocuments.toList(),
                        ),
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
                  onPressed: () =>
                      Navigator.pop(dialogContext, {
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

    if (result == null) return;

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
        );
        exportedFiles.add(XFile(exportPath));
      }

      if (exportedFiles.isEmpty) {
        hideGeneratingDialog(context);
        _message('No documents were available to share.');
        return;
      }

      hideGeneratingDialog(context);
      if (!mounted) return;
      await Share.shareXFiles(exportedFiles, text: 'Shared from Scanner Pro');
      _clearSelection();
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      _message('Export failed: $error');
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

  @override
  Widget build(BuildContext context) => Scaffold(
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
      ],
    ),
    floatingActionButton: _isMultiSelectMode
        ? null
        : FloatingActionButton.extended(
            onPressed: _newDocument,
            icon: const Icon(Icons.add),
            label: const Text('New file'),
          ),
    body: Stack(
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
                            ? 'No files yet. Tap New file to start scanning.'
                            : 'No documents match "$_searchQuery".',
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    16,
                    16,
                    _isMultiSelectMode ? 120 : 100,
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
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _bulkProcessing
                            ? null
                            : _deleteSelectedDocuments,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _bulkProcessing
                            ? null
                            : _shareSelectedDocuments,
                        icon: const Icon(Icons.share),
                        label: const Text('Share'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
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
  'Actual': 0.50,
  'Medium': 0.40,
  'Small': 0.35,
  'Smallest': 0.30,
};

double exportScaleForSize(String fileSize) =>
    exportSizeOptions[fileSize] ?? exportSizeOptions['Actual']!;

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
          (entry) => DropdownMenuItem(
            value: entry.key,
            child: Text(
              '${entry.key}',
            ),
          ),
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
  if (scaleFactor >= 1) return source;
  return img.copyResize(
    source,
    width: (source.width * scaleFactor).round().clamp(1, source.width),
    height: (source.height * scaleFactor).round().clamp(1, source.height),
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
    candidate = File(path.join(directory.path, '$baseName\_$suffix$extension'));
    suffix++;
  }
  return candidate;
}

Future<String> exportDocumentImagesToDownloads({
  required List<File> images,
  required String fileType,
  required String fileName,
  String fileSize = 'Actual',
}) async {
  final extension = fileType.toLowerCase() == 'jpg' ? 'jpg' : 'pdf';
  final cleanName = sanitizeExportFileName(fileName, extension);
  final fileNameWithExtension = '$cleanName.$extension';

  final tempFile = File(
    path.join(
      Directory.systemTemp.path,
      'scanner_pro_${DateTime.now().millisecondsSinceEpoch}_$fileNameWithExtension',
    ),
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
    quality: 100,
  );

  final bytes = await tempFile.readAsBytes();
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

  Future<void> _add(ImageSource source) async {
    final scannerSource = source == ImageSource.camera
        ? ScannerSource.camera
        : ScannerSource.gallery;

    try {
      final scannedPaths = await CunningDocumentScanner.getPictures(
        scannerSource: scannerSource,
        noOfPages: 50,
      );

      if (scannedPaths == null || scannedPaths.isEmpty) return;

      var nextIndex = 1;
      final existingNames = images.map((file) => path.basenameWithoutExtension(file.path)).toSet();
      while (existingNames.contains('$nextIndex')) {
        nextIndex++;
      }
      for (final scannedPath in scannedPaths) {
        final scannedFile = File(scannedPath);
        if (!await scannedFile.exists()) continue;

        final target = File(
          path.join(widget.document.directory.path, '${nextIndex++}.jpg'),
        );
        await scannedFile.copy(target.path);
        existingNames.add(path.basenameWithoutExtension(target.path));
        while (existingNames.contains('$nextIndex')) {
          nextIndex++;
        }
      }

      await CunningDocumentScanner.cleanCache();
      if (mounted) setState(() {});
    } on CunningDocumentScannerException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _openImageEditor(File file) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImageEditorPage(file: file)),
    );

    if (result is File && mounted) {
      final updated = result;
      final target = File(file.path);
      if (await target.exists()) await target.delete();
      await updated.copy(target.path);
      setState(() {});
    }
  }

  Future<void> _remove(File file) async {
    if (!await file.exists()) return;

    await file.delete();
    if (mounted) setState(() {});
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
  }) async {
    return exportDocumentImagesToDownloads(
      images: images,
      fileType: fileType,
      fileName: fileName,
      fileSize: fileSize,
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

    if (result == null) return;

    setState(() => processing = true);
  showGeneratingDialog(context);
    try {
      final outputPath = await _exportDocumentFile(
        fileType: result['fileType'] ?? 'pdf',
        fileSize: result['fileSize'] ?? 'Actual',
        fileName: result['fileName'] ?? _currentName,
      );

      if (!mounted) return;

      hideGeneratingDialog(context);
      await Share.shareXFiles([
        XFile(outputPath),
      ], text: 'Shared from Scanner Pro');

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to $outputPath')));
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

    if (result == null) return;

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded to $outputPath')),
      );
    } catch (error) {
      if (mounted) hideGeneratingDialog(context);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $error')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: GestureDetector(onTap: _renameDocument, child: Text(_currentName)),
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
    body: Column(
      children: [
        Expanded(
          child: images.isEmpty
              ? const Center(
                  child: Text('Add a picture from the camera or gallery.'),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: images.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.8,
                  ),
                  itemBuilder: (_, index) {
                    final file = images[index];
                    return Stack(
                      key: ValueKey(file.path),
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              onTap: () => _openImageEditor(file),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(file, fit: BoxFit.cover),
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
                                  borderRadius: BorderRadius.circular(999),
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _add(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _add(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
        ),
      ],
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
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    final rawName = value?.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
    if (rawName == null || rawName.isEmpty || rawName == widget.document.name)
      return;

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

    if (result == null) return;

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
      await Share.shareXFiles([
        XFile(outputPath),
      ], text: 'Shared from Scanner Pro');

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to $outputPath')));
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

    if (result == null) return;

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
    appBar: AppBar(
      title: GestureDetector(
        onTap: _renameDocument,
        child: Text(widget.document.name),
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
    body: widget.document.images.isEmpty
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
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 0.75,
                    child: Image.file(file, fit: BoxFit.contain),
                  ),
                ),
              );
            },
          ),
  );
}
