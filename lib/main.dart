import 'dart:io';
import 'dart:ui' as ui;

import 'package:document_scanner_flutter/configs/configs.dart';
import 'package:document_scanner_flutter/document_scanner_flutter.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path;
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
          ],
        ),
      ),
    );
    if (action == 'rename') await _rename(document);
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
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
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

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

class _DocumentPageState extends State<DocumentPage> {
  bool processing = false;
  late String _currentName;
  static const Map<String, double> pdfScales = {
    'Actual': 1.0,
    'Medium': 0.8,
    'Small': 0.6,
    'Smallest': 0.5,
  };

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

  String? _extractScannedFilePath(dynamic result) {
    if (result == null) return null;
    if (result is File) return result.path;
    if (result is String) return result;
    if (result is Map) {
      final direct = result['filePath'] ?? result['path'];
      if (direct is String) return direct;
      if (direct is File) return direct.path;
      final scannedFiles = result['scannedFiles'];
      if (scannedFiles is List && scannedFiles.isNotEmpty) {
        final first = scannedFiles.first;
        if (first is File) return first.path;
        if (first is String) return first;
      }
    }
    if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is File) return first.path;
      if (first is String) return first;
    }
    return null;
  }

  Future<void> _add(ImageSource source) async {
    if (source == ImageSource.camera) {
      final result = await DocumentScannerFlutter.launch(
        context,
        source: ScannerFileSource.CAMERA,
      );
      final filePath = _extractScannedFilePath(result);
      if (filePath == null) return;

      final scanned = File(filePath);
      if (!await scanned.exists()) return;

      final save = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Add to document?'),
          content: SizedBox(
            width: double.maxFinite,
            child: Image.file(scanned),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Select'),
            ),
          ],
        ),
      );

      if (save != true) {
        await scanned.delete();
        return;
      }

      final target = File(path.join(widget.document.directory.path, '${images.length + 1}.jpg'));
      await scanned.copy(target.path);
      if (mounted) setState(() {});
      return;
    }

    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    final target = File(path.join(widget.document.directory.path, '${images.length + 1}.jpg'));
    await File(picked.path).copy(target.path);
    if (mounted) setState(() {});
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
    final clean = value?.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '-');
    if (clean == null || clean.isEmpty || clean == _currentName) return;
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
    setState(() => _currentName = clean);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Renamed to $clean')),
      );
    }
  }

  Future<void> _savePdf([double scaleFactor = 1.0]) async {
    if (images.isEmpty) return;
    setState(() => processing = true);
    try {
      final pdf = pw.Document();
      for (final imageFile in images) {
        final bytes = await imageFile.readAsBytes();
        final decoded = await ui.instantiateImageCodec(bytes);
        await decoded.getNextFrame();

        pdf.addPage(pw.Page(
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
      if (mounted) setState(() => processing = false);
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
                tooltip: 'Save PDF size',
                onSelected: (label) async {
                  final scale = pdfScales[label] ?? 1.0;
                  await _savePdf(scale);
                },
                itemBuilder: (context) => pdfScales.entries
                    .map((entry) => PopupMenuItem<String>(
                          value: entry.key,
                          child: Text('${entry.key} - ${entry.key == 'Actual' ? 'Actual size' : entry.key == 'Medium' ? '80% of Actual Size' : entry.key == 'Small' ? '60% of Actual Size' : '50% Actual size'}'),
                        ))
                    .toList(),
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

  Future<void> _open(BuildContext context) async {
    if (!await widget.document.pdfFile.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the PDF first.')),
      );
      return;
    }
    await OpenFile.open(widget.document.pdfFile.path);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('${widget.document.name}')),
        body: Column(
          children: [
            Expanded(
              child: widget.document.images.isEmpty
                  ? const Center(child: Text('No pictures in this file.'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: widget.document.images.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemBuilder: (_, index) => Image.file(
                        widget.document.images[index],
                        fit: BoxFit.cover,
                      ),
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
                      onPressed: () => _open(context),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open PDF'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
