import 'dart:io';
import 'dart:ui' as ui;

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf_lib;
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';

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

class DocumentFolder {
  Directory directory;
  DocumentFolder(this.directory);

  String get name => path.basename(directory.path);
  File get pdfFile => File(path.join(directory.path, '$name.pdf'));

  List<File> get images => directory
      .listSync()
      .whereType<File>()
      .where((file) => ['.jpg', '.jpeg', '.png', '.heic']
          .contains(path.extension(file.path).toLowerCase()))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

class StorageService {
  Future<Directory> root() async {
    if (Platform.isAndroid) {
      final permission = await Permission.manageExternalStorage.status;
      if (!permission.isGranted) await Permission.manageExternalStorage.request();
    }
    final root = Platform.isAndroid
        ? Directory('/storage/emulated/0/Documents/Scanner Pro')
        : Directory(path.join(Directory.current.path, 'Scanner Pro'));
    await root.create(recursive: true);
    return root;
  }

  Future<Directory> downloads() async {
    if (Platform.isAndroid) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final dir = Directory(path.join(downloads.path, 'Scanner Pro'));
        await dir.create(recursive: true);
        return dir;
      }

      final fallback = Directory('/storage/emulated/0/Download/Scanner Pro');
      await fallback.create(recursive: true);
      return fallback;
    }

    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      final dir = Directory(path.join(home, 'Downloads', 'Scanner Pro'));
      await dir.create(recursive: true);
      return dir;
    }

    final dir = await getApplicationDocumentsDirectory();
    final downloads = Directory(path.join(dir.path, 'Downloads', 'Scanner Pro'));
    await downloads.create(recursive: true);
    return downloads;
  }

  Future<List<DocumentFolder>> documents() async {
    final rootDirectory = await root();
    return rootDirectory
        .listSync()
        .whereType<Directory>()
        .map(DocumentFolder.new)
        .where((document) =>
            document.images.isNotEmpty || document.pdfFile.existsSync())
        .toList()
      ..sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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
  String _searchQuery = '';

  List<DocumentFolder> get _filteredDocuments {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return documents;
    return documents
        .where((document) => document.name.toLowerCase().contains(query))
        .toList();
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
    final destination = Directory(path.join(document.directory.parent.path, clean));
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
        content: Text('This will delete "${document.name}" and all its scanned files.'),
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
              : Text('My Docs (${documents.length})'),
          actions: [
            IconButton(
              onPressed: _toggleSearch,
              icon: Icon(_searchOpen ? Icons.close : Icons.search),
              tooltip: 'Search documents',
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _newDocument,
          icon: const Icon(Icons.add),
          label: const Text('New file'),
        ),
        body: RefreshIndicator(
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
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                      itemCount: _filteredDocuments.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final document = _filteredDocuments[index];
                        return ListTile(
                          tileColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(
                            document.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                              '${document.images.length} picture${document.images.length == 1 ? '' : 's'}'),
                          onTap: () => _openDocument(document),
                          trailing: IconButton(
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => _menu(document),
                          ),
                        );
                      },
                    ),
        ),
      );
}

class DocumentPage extends StatefulWidget {
  final DocumentFolder document;
  const DocumentPage({required this.document, super.key});

  static const Map<String, double> pdfScales = {
    'Actual': 1.0,
    'Medium': 0.8,
    'Small': 0.6,
    'Smallest': 0.5,
  };

  static String _formatBytesLabel(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}KB';
    final megabytes = bytes / (1024 * 1024);
    return '${megabytes.round()}MB';
  }

  static String sizeLabel(String key, int totalBytes) {
    final scale = pdfScales[key] ?? 1.0;
    final scaledBytes = (totalBytes * scale).round();
    return '$key - ${_formatBytesLabel(scaledBytes)}';
  }

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

class _DocumentPageState extends State<DocumentPage> {
  bool processing = false;
  late String _currentName;

  int get _documentBytes => images.fold<int>(0, (sum, file) => sum + file.lengthSync());

  List<File> get images => widget.document.images;

  @override
  void initState() {
    super.initState();
    _currentName = widget.document.name;
  }

  String _formatDate(File file) {
    final date = file.lastModifiedSync();
    const months = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
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

      var nextIndex = images.length + 1;
      for (final scannedPath in scannedPaths) {
        final scannedFile = File(scannedPath);
        if (!await scannedFile.exists()) continue;

        final target = File(path.join(widget.document.directory.path, '${nextIndex++}.jpg'));
        await scannedFile.copy(target.path);
      }

      await CunningDocumentScanner.cleanCache();
      if (mounted) setState(() {});
    } on CunningDocumentScannerException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    }
  }

  Future<void> _remove(File file) async {
    await file.delete();
    final files = images;
    for (var index = 0; index < files.length; index++) {
      final target = File(path.join(widget.document.directory.path, '${index + 1}.jpg'));
      if (files[index].path != target.path) await files[index].rename(target.path);
    }
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
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    final rawName = value?.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
    if (rawName == null || rawName.isEmpty || rawName == _currentName) return;
    final clean = rawName;
    final destination = Directory(path.join(widget.document.directory.parent.path, clean));
    if (await destination.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A file with that name already exists.')),
        );
      }
      return;
    }
    await widget.document.directory.rename(destination.path);
    widget.document.directory = destination;
    if (!mounted) return;
    setState(() => _currentName = clean);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Renamed to $clean')),
    );
  }

  Future<void> _savePdf([double scaleFactor = 1.0]) async {
    if (images.isEmpty) return;
    setState(() => processing = true);
    try {
      final pdf = pw.Document();
      final pageFormat = pdf_lib.PdfPageFormat.standard.copyWith(
        width: pdf_lib.PdfPageFormat.standard.width * scaleFactor,
        height: pdf_lib.PdfPageFormat.standard.height * scaleFactor,
      );

      for (final imageFile in images) {
        final bytes = await imageFile.readAsBytes();
        final decoded = await ui.instantiateImageCodec(bytes);
        await decoded.getNextFrame();

        pdf.addPage(pw.Page(
          pageFormat: pageFormat,
          build: (_) => pw.Center(
            child: pw.Image(
              pw.MemoryImage(bytes),
              fit: pw.BoxFit.contain,
              width: pageFormat.width,
              height: pageFormat.height,
            ),
          ),
        ));
      }

      final pdfBytes = await pdf.save();
      final localFile = widget.document.pdfFile;
      await localFile.writeAsBytes(pdfBytes);

      final downloadsDir = await StorageService().downloads();
      final downloadedFile = File(path.join(downloadsDir.path, '${widget.document.name}.pdf'));
      await downloadedFile.writeAsBytes(pdfBytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded to ${downloadedFile.path}')),
        );
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> _saveCombinedJpg() async {
    if (images.isEmpty) return;

    final decodedImages = <ui.Image>[];
    for (final imageFile in images) {
      final bytes = await imageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      decodedImages.add(frame.image);
    }

    final maxWidth = decodedImages.fold<int>(
      0,
      (current, img) => img.width > current ? img.width : current,
    );
    final totalHeight = decodedImages.fold<int>(0, (total, img) => total + img.height);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final backgroundPaint = Paint()..color = Colors.white;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, maxWidth.toDouble(), totalHeight.toDouble()),
      backgroundPaint,
    );

    var offsetY = 0.0;
    for (final image in decodedImages) {
      final pageWidth = image.width.toDouble();
      final pageHeight = image.height.toDouble();
      final targetRect = Rect.fromLTWH(
        (maxWidth - pageWidth) / 2,
        offsetY,
        pageWidth,
        pageHeight,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, pageWidth, pageHeight),
        targetRect,
        Paint(),
      );
      offsetY += pageHeight;
    }

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(maxWidth, totalHeight);
    final pngBytesData = await rendered.toByteData(format: ui.ImageByteFormat.png);
    if (pngBytesData == null) {
      throw const FormatException('Unable to encode JPG');
    }

    final pngBytes = pngBytesData.buffer.asUint8List();
    final decoded = img.decodePng(pngBytes);
    if (decoded == null) {
      throw const FormatException('Unable to decode combined image');
    }

    final jpegBytes = img.encodeJpg(decoded);
    final downloadsDir = await StorageService().downloads();
    final outputFile = File(path.join(downloadsDir.path, '${widget.document.name}.jpg'));
    await outputFile.writeAsBytes(jpegBytes);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded JPG to ${outputFile.path}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _renameDocument,
            child: Text(_currentName),
          ),
          actions: [
            if (images.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Save document',
                onSelected: (label) async {
                  if (label == 'jpg') {
                    await _saveCombinedJpg();
                    return;
                  }

                  final scale = DocumentPage.pdfScales[label] ?? 1.0;
                  await _savePdf(scale);
                },
                itemBuilder: (context) => [
                  ...DocumentPage.pdfScales.entries.map(
                    (entry) => PopupMenuItem<String>(
                      value: entry.key,
                      child: Text(DocumentPage.sizeLabel(entry.key, _documentBytes)),
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    value: 'jpg',
                    child: Text('Download JPG'),
                  ),
                ],
                icon: const Icon(Icons.save_alt),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: images.isEmpty
                  ? const Center(child: Text('Add a picture from the camera or gallery.'))
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
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(file, fit: BoxFit.cover),
                              ),
                            ),
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black54],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                            Positioned(
                              bottom: 8,
                              left: 8,
                              right: 42,
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
                            Positioned(
                              top: 8,
                              right: 8,
                              child: GestureDetector(
                                onTap: () => _remove(file),
                                child: const CircleAvatar(
                                  radius: 13,
                                  backgroundColor: Colors.black54,
                                  child: Icon(Icons.close, size: 16, color: Colors.white),
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

  Future<void> _savePdf() async {
    setState(() => saving = true);
    try {
      final pdf = pw.Document();
      for (final image in widget.document.images) {
        final bytes = await image.readAsBytes();
        pdf.addPage(pw.Page(
          pageFormat: pdf_lib.PdfPageFormat.a4,
          build: (_) => pw.Center(
            child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
          ),
        ));
      }
      await widget.document.pdfFile.writeAsBytes(await pdf.save());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${widget.document.name}.pdf')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _saveCombinedJpg() async {
    if (widget.document.images.isEmpty) return;

    final decodedImages = <img.Image>[];
    for (final imageFile in widget.document.images) {
      final bytes = await imageFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) continue;
      decodedImages.add(decoded);
    }

    if (decodedImages.isEmpty) return;

    final maxWidth = decodedImages.fold<int>(
      0,
      (current, page) => page.width > current ? page.width : current,
    );
    final totalHeight = decodedImages.fold<int>(0, (total, page) => total + page.height);

    final combined = img.Image(width: maxWidth, height: totalHeight);
    var y = 0;
    for (final page in decodedImages) {
      final xOffset = (maxWidth - page.width) ~/ 2;
      img.compositeImage(combined, page, dstX: xOffset, dstY: y);
      y += page.height;
    }

    final jpegBytes = img.encodeJpg(combined);
    final downloadsDir = await StorageService().downloads();
    final outputFile = File(path.join(downloadsDir.path, '${widget.document.name}.jpg'));
    await outputFile.writeAsBytes(jpegBytes);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded JPG to ${outputFile.path}')),
      );
    }
  }

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final pdfExists = await widget.document.pdfFile.exists();
    if (!context.mounted) return;
    if (!pdfExists) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Save the PDF first.')),
      );
      return;
    }
    await OpenFile.open(widget.document.pdfFile.path);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.document.name)),
        body: Column(
          children: [
            Expanded(
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
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: saving ? null : _savePdf,
                      icon: const Icon(Icons.save),
                      label: Text(saving ? 'Saving...' : 'Save PDF'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saveCombinedJpg,
                      icon: const Icon(Icons.image),
                      label: const Text('Save JPG'),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open PDF'),
                ),
              ),
            ),
          ],
        ),
      );
}
