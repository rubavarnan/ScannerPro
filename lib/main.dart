import 'dart:io';

import 'package:document_scanner_flutter/document_scanner_flutter.dart';
import 'package:document_scanner_flutter/configs/configs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      title: 'Scanner Pro',
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: const ScannerHomePage(),
    );
  }
}

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({super.key});

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

class _ScannerHomePageState extends State<ScannerHomePage> {
  final List<File> _documents = [];
  late Directory _storageDir;
  bool _isLoading = true;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _initStorage();
  }

  Future<void> _initStorage() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _storageDir = Directory(path.join(dir.path, 'Scanner Pro'));
      if (!await _storageDir.exists()) await _storageDir.create(recursive: true);
      await _refreshDocuments();
    } catch (e) {
      print('Storage init error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshDocuments() async {
    setState(() => _isLoading = true);
    final files = _storageDir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    setState(() {
      _documents
        ..clear()
        ..addAll(files.where((f) {
          final ext = path.extension(f.path).toLowerCase();
          return ext == '.pdf' || ext == '.jpg' || ext == '.jpeg' || ext == '.png';
        }));
      _isLoading = false;
    });
  }

  Future<void> _scanDocument({required bool createPdf, bool fromGallery = false}) async {
    setState(() => _isScanning = true);
    // Ensure runtime permissions before launching scanner
    final ok = await _ensurePermissions(forGallery: fromGallery);
    if (!ok) {
      _showMessage('Permissions required to scan documents.');
      if (mounted) setState(() => _isScanning = false);
      return;
    }
    try {
      final source = fromGallery ? ScannerFileSource.GALLERY : ScannerFileSource.CAMERA;
      dynamic result;
      final scannerContext = rootNavigatorKey.currentContext;
      if (scannerContext == null || !scannerContext.mounted) {
        if (mounted) setState(() => _isScanning = false);
        return;
      }
      if (createPdf) {
        result = await DocumentScannerFlutter.launchForPdf(scannerContext, source: source);
      } else {
        result = await DocumentScannerFlutter.launch(scannerContext, source: source);
      }

      if (result == null) {
        return;
      }

      String? filePath;
      if (result is String) {
        filePath = result;
      }
      else if (result is Map && result['filePath'] != null) {
        filePath = result['filePath'] as String;
      } else if (result is Map && result['scannedFiles'] is List && (result['scannedFiles'] as List).isNotEmpty) {
        filePath = (result['scannedFiles'] as List).first as String;
      } else if (result is List && result.isNotEmpty) {
        filePath = result.first as String;
      }

      if (filePath == null) {
        return;
      }

      final scanned = File(filePath);
      if (!await scanned.exists()) {
        return;
      }

      if (!mounted) {
        return;
      }
      await _previewAndMaybeSave(scanned);
    } on PlatformException catch (e) {
      _showMessage('Scanner error: ${e.message}');
    } catch (e) {
      _showMessage('Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<bool> _ensurePermissions({required bool forGallery}) async {
    try {
      // Camera required for camera source
      if (!forGallery) {
        final cameraStatus = await Permission.camera.status;
        if (!cameraStatus.isGranted) {
          final res = await Permission.camera.request();
          if (!res.isGranted) return false;
        }
      }

      // For gallery import and saving, request photos permission (works on Android 6.0+)
      if (Platform.isIOS) {
        final ps = await Permission.photos.status;
        if (!ps.isGranted) {
          final res = await Permission.photos.request();
          if (!ps.isGranted) return false;
        }
      } else {
        // On Android 13+, use photos instead of storage
        final photoStatus = await Permission.photos.status;
        if (!photoStatus.isGranted) {
          final res = await Permission.photos.request();
          if (!res.isGranted) return false;
        }
      }
      return true;
    } catch (e) {
      print('Permission error: $e');
      return true; // Continue anyway for better UX
    }
  }

  Future<void> _previewAndMaybeSave(File scannedFile) async {
    final ext = path.extension(scannedFile.path).toLowerCase();
    final isPdf = ext == '.pdf';
    final dialogContext = rootNavigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final save = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text(isPdf ? 'Scanned PDF' : 'Scanned Image'),
        content: SizedBox(
          width: double.maxFinite,
          child: isPdf
              ? Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.picture_as_pdf, size: 64), Text(path.basename(scannedFile.path))])
              : Image.file(scannedFile),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Discard')),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    );

    if (!mounted) return;

    if (save == true) {
      await _saveScannedFile(scannedFile);
    } else {
      try {
        if (await scannedFile.exists()) {
          await scannedFile.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> _saveScannedFile(File scanned) async {
    final now = DateTime.now();
    final ext = path.extension(scanned.path).toLowerCase();
    final filename = '${now.millisecondsSinceEpoch}$ext';
    final dest = File(path.join(_storageDir.path, filename));
    await scanned.copy(dest.path);
    await _refreshDocuments();
    _showMessage('Saved ${path.basename(dest.path)}');
  }

  Future<void> _deleteDocument(File file) async {
    final dialogContext = rootNavigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final ok = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Delete document'),
        content: Text('Delete ${path.basename(file.path)}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      try {
        await file.delete();
        await _refreshDocuments();
        _showMessage('Deleted ${path.basename(file.path)}');
      } catch (e) {
        _showMessage('Delete failed: $e');
      }
    }
  }

  Future<void> _openDocument(File file) async {
    final ext = path.extension(file.path).toLowerCase();
    final isPdf = ext == '.pdf';
    if (isPdf) {
      await OpenFile.open(file.path);
      return;
    }
    if (!mounted) {
      return;
    }
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    await navigator.push(MaterialPageRoute(builder: (_) => ImagePreviewPage(file: file, onDelete: () async {
      await _deleteDocument(file);
      navigator.pop();
    })));
  }

  void _showMessage(String message) {
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
    }
  }

  Widget _buildDocumentTile(File file) {
    final ext = path.extension(file.path).toLowerCase();
    final isPdf = ext == '.pdf';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: isPdf ? const Icon(Icons.picture_as_pdf, color: Colors.redAccent, size: 42) : Image.file(file, width: 56, height: 56, fit: BoxFit.cover),
        title: Text(path.basename(file.path)),
        subtitle: Text(isPdf ? 'PDF document' : 'Scanned image'),
        onTap: () => _openDocument(file),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteDocument(file)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner Pro'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _refreshDocuments),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Text(_isLoading ? 'Loading documents...' : 'Saved documents: ${_documents.length}', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _documents.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: Text('No scanned documents yet. Use the buttons below to scan or import images.', textAlign: TextAlign.center)))
                    : ListView.builder(itemCount: _documents.length, itemBuilder: (c, i) => _buildDocumentTile(_documents[i])),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        color: Colors.white,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.camera_alt, size: 32),
                  onPressed: _isScanning ? null : () => _scanDocument(createPdf: false, fromGallery: false),
                  tooltip: 'Camera',
                ),
                const SizedBox(width: 48),
                IconButton(
                  icon: const Icon(Icons.photo_library, size: 32),
                  onPressed: _isScanning ? null : () => _scanDocument(createPdf: false, fromGallery: true),
                  tooltip: 'Gallery',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ImagePreviewPage extends StatelessWidget {
  final File file;
  final VoidCallback onDelete;

  const ImagePreviewPage({super.key, required this.file, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(path.basename(file.path)),
        actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete)],
      ),
      body: Center(child: InteractiveViewer(child: Image.file(file))),
    );
  }
}
