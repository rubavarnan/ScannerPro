import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:scanner_pro/main.dart';

void main() {
  testWidgets('shows the scanner app shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('progress dialog stays visible until the action completes', (
    WidgetTester tester,
  ) async {
    final completer = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                await runWithProgressDialog<void>(
                  context,
                  message: 'Saving...',
                  action: () => completer.future,
                );
              },
              child: const Text('Save'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Saving...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.text('Saving...'), findsNothing);
  });

  test('collage layouts expand with the selected image count', () {
    expect(collageLayoutsForImageCount(1), [
      (1, 1),
      (1, 2),
      (1, 3),
      (2, 1),
      (2, 2),
      (2, 3),
      (3, 1),
      (3, 2),
      (3, 3),
      (4, 1),
      (4, 2),
      (4, 3),
    ]);
    expect(collageLayoutsForImageCount(5), [
      (2, 3),
      (3, 2),
      (3, 3),
      (4, 2),
      (4, 3),
    ]);
    expect(collageLayoutsForImageCount(12), [(4, 3)]);
    expect(collageLayoutsForImageCount(13), isEmpty);
  });

  test('drag reorder inserts at the actual target index', () {
    final files = [File('1.jpg'), File('2.jpg'), File('3.jpg')];

    expect(reorderFilesForDrag(files, 0, 1), [files[1], files[0], files[2]]);
    expect(reorderFilesForDrag(files, 0, 2), [files[1], files[2], files[0]]);
    expect(reorderFilesForDrag(files, 2, 0), [files[2], files[0], files[1]]);
  });

  test('document created date stays stable when images are added', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'scanner_pro_document_date_test_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final documentDirectory = Directory('${tempDir.path}/Document')
      ..createSync();
    final firstImage = File('${documentDirectory.path}/1.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    final document = DocumentFolder(documentDirectory);

    await document.preserveCreatedDate();
    final createdDate = document.createdDate;
    final firstImageLength = firstImage.lengthSync();
    File('${documentDirectory.path}/2.jpg').writeAsBytesSync([4, 5]);

    final reloadedDocument = DocumentFolder(documentDirectory);
    expect(reloadedDocument.createdDate, createdDate);
    expect(reloadedDocument.sizeBytes, firstImageLength + 2);
  });

  testWidgets('swiping between edited images asks before leaving', (
    WidgetTester tester,
  ) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'scanner_pro_editor_swipe_test_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final pathProviderChannel = const MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => tempDir.path,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null),
    );

    final firstImage = img.Image(width: 24, height: 12);
    final secondImage = img.Image(width: 18, height: 10);
    final firstFile = File('${tempDir.path}/1.jpg')
      ..writeAsBytesSync(img.encodeJpg(firstImage));
    final secondFile = File('${tempDir.path}/2.jpg')
      ..writeAsBytesSync(img.encodeJpg(secondImage));
    final secondBytes = await secondFile.readAsBytes();

    Future<void> pumpEditorFrames() async {
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> settleEditorAction() async {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await pumpEditorFrames();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ImageEditorPage(file: firstFile, files: [firstFile, secondFile]),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await pumpEditorFrames();

    await tester.tap(find.byTooltip('Rotate'));
    await settleEditorAction();
    await tester.drag(
      find.byKey(const ValueKey('edit-image-preview')),
      const Offset(-300, 0),
    );
    await pumpEditorFrames();
    expect(find.text('Save changes?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await pumpEditorFrames();
    expect(find.text('Save changes?'), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('edit-image-preview')),
      const Offset(-300, 0),
    );
    await pumpEditorFrames();
    await tester.tap(find.text('Save and continue'));
    await pumpEditorFrames();

    final savedFirst = img.decodeImage(await firstFile.readAsBytes());
    expect(savedFirst?.width, 12);
    expect(savedFirst?.height, 24);
    final previewImage = tester.widget<Image>(find.byType(Image));
    expect((previewImage.image as MemoryImage).bytes, secondBytes);

    await tester.tap(find.byTooltip('Rotate'));
    await settleEditorAction();
    await tester.drag(
      find.byKey(const ValueKey('edit-image-preview')),
      const Offset(300, 0),
    );
    await pumpEditorFrames();
    expect(find.text('Save changes?'), findsOneWidget);
  });

  testWidgets('watermark dialog starts with watermark text and opacity', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<TextAnnotationOptions>(
                context: context,
                builder: (_) => const TextEntryDialog(isWatermark: true),
              ),
              child: const Text('Open watermark'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open watermark'));
    await tester.pumpAndSettle();

    expect(find.text('Add watermark'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'WATERMARK',
    );
    expect(tester.widgetList<Slider>(find.byType(Slider)).last.value, 0.35);
  });

  test(
    'uses the standard platform Downloads directory without nesting a Scanner Pro folder',
    () {
      final androidDownloads = StorageService.standardDownloadsDirectory(
        operatingSystem: 'android',
        downloadsDirectoryPath: '/storage/emulated/0/Download',
      );
      expect(androidDownloads.path, '/storage/emulated/0/Download');

      final windowsDownloads = StorageService.standardDownloadsDirectory(
        operatingSystem: 'windows',
        homeDirectory: r'C:\Users\TestUser',
      );
      expect(windowsDownloads.path, r'C:\Users\TestUser\Downloads');
    },
  );

  test(
    'keeps the custom export filename without duplicating the extension',
    () {
      expect(sanitizeExportFileName('Invoice', 'jpg'), 'Invoice');
      expect(sanitizeExportFileName('Invoice.jpg', 'jpg'), 'Invoice');
      expect(sanitizeExportFileName('Invoice.pdf', 'jpg'), 'Invoice.pdf');
      expect(sanitizeExportFileName('  My Report  ', 'jpg'), 'My Report');
    },
  );

  test('Actual export uses 95 percent scale', () {
    expect(exportScaleForSize('Actual'), 0.95);
    expect(exportQualityForSize('Actual'), 95);
    expect(
      shouldEmbedOriginalJpegInPdf(scaleFactor: 1.0, quality: 100),
      isTrue,
    );
    expect(
      shouldEmbedOriginalJpegInPdf(
        scaleFactor: exportScaleForSize('Actual'),
        quality: exportQualityForSize('Actual'),
      ),
      isFalse,
    );
    expect(
      shouldKeepOriginalJpegExport(
        scaleFactor: 1.0,
        quality: 100,
        width: 1200,
        height: 800,
      ),
      isTrue,
    );
    expect(
      shouldKeepOriginalJpegExport(
        scaleFactor: 0.9,
        quality: 100,
        width: 1200,
        height: 800,
      ),
      isFalse,
    );
    expect(
      shouldKeepOriginalJpegExport(
        scaleFactor: 1.0,
        quality: 95,
        width: 1200,
        height: 800,
      ),
      isFalse,
    );
    expect(
      shouldKeepOriginalJpegExport(
        scaleFactor: 1.0,
        quality: 100,
        width: 2000,
        height: 800,
      ),
      isFalse,
    );
  });

  test('export size estimate follows the selected preset and format', () {
    final actualJpg = estimateExportSizeBytes(
      sourceFileSizes: [1024 * 1024, 512 * 1024],
      fileType: 'jpg',
      fileSize: 'Actual',
    );
    final smallJpg = estimateExportSizeBytes(
      sourceFileSizes: [1024 * 1024, 512 * 1024],
      fileType: 'jpg',
      fileSize: 'Small',
    );
    final actualPdf = estimateExportSizeBytes(
      sourceFileSizes: [1024 * 1024, 512 * 1024],
      fileType: 'pdf',
      fileSize: 'Actual',
    );

    expect(smallJpg, lessThan(actualJpg));
    expect(actualPdf, greaterThan(actualJpg));
    expect(formatByteSize(actualJpg), contains('MB'));
  });

  test('reduced export sizes stay distinct after the resolution cap', () {
    (int, int) dimensionsFor(String size) {
      final scale = exportScaleForDimensions(
        width: 4000,
        height: 2000,
        requestedScale: exportScaleForSize(size),
      );
      return ((4000 * scale).round(), (2000 * scale).round());
    }

    expect(dimensionsFor('Actual'), (1710, 855));
    expect(dimensionsFor('Medium'), (1620, 810));
    expect(dimensionsFor('Small'), (1440, 720));
    expect(dimensionsFor('X-Small'), (1260, 630));
    expect(dimensionsFor('Smallest'), (1080, 540));
  });

  test(
    'exports JPG and PDF files successfully without a size selector',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'scanner_pro_export_test_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final image = img.Image(width: 480, height: 320);
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          image.setPixelRgba(
            x,
            y,
            (x * 73 + y * 31) % 256,
            (x * 17 + y * 97) % 256,
            (x * 43 + y * 11) % 256,
            255,
          );
        }
      }

      final sourceFile = File('${tempDir.path}/source.jpg');
      await sourceFile.writeAsBytes(img.encodeJpg(image, quality: 100));
      final originalJpegBytes = await sourceFile.readAsBytes();

      final jpgPath = await exportDocumentImagesToDownloads(
        images: [sourceFile],
        fileType: 'jpg',
        fileName: 'exported_jpg',
      );
      final pdfPaths = <String>[];
      for (final fileSize in [
        'Actual',
        'Medium',
        'Small',
        'X-Small',
        'Smallest',
      ]) {
        final pdfPath = await exportDocumentImagesToDownloads(
          images: [sourceFile],
          fileType: 'pdf',
          fileName: 'exported_pdf_$fileSize',
          fileSize: fileSize,
          saveToDownloads: false,
        );
        pdfPaths.add(pdfPath);
        addTearDown(() async => File(pdfPath).delete());
      }

      expect(File(jpgPath).existsSync(), isTrue);
      for (final pdfPath in pdfPaths) {
        expect(File(pdfPath).existsSync(), isTrue);
      }
      expect(File(jpgPath).lengthSync(), greaterThan(0));
      final pdfSizes = pdfPaths.map((pdfPath) => File(pdfPath).lengthSync());
      expect(pdfSizes.toSet(), hasLength(5));
      final orderedPdfSizes = pdfSizes.toList();
      for (var index = 0; index < orderedPdfSizes.length - 1; index++) {
        expect(orderedPdfSizes[index], greaterThan(orderedPdfSizes[index + 1]));
      }
      for (final pdfPath in pdfPaths) {
        expect(
          _containsBytes(await File(pdfPath).readAsBytes(), originalJpegBytes),
          isFalse,
        );
      }
    },
  );

  testWidgets('image placement moves and resizes an image overlay', (
    WidgetTester tester,
  ) async {
    final baseImage = img.Image(width: 32, height: 32);
    img.fill(baseImage, color: img.ColorRgb8(20, 40, 180));
    final overlayImage = img.Image(width: 8, height: 8);
    img.fill(overlayImage, color: img.ColorRgb8(220, 30, 20));
    Uint8List? placedBytes;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                placedBytes = await showDialog<Uint8List>(
                  context: context,
                  builder: (_) => ImagePlacementDialog(
                    imageBytes: Uint8List.fromList(img.encodePng(baseImage)),
                    overlayBytes: Uint8List.fromList(
                      img.encodePng(overlayImage),
                    ),
                  ),
                );
              },
              child: const Text('Open placement'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open placement'));
    await tester.pumpAndSettle();
    expect(find.text('Place image'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('image-overlay')),
      const Offset(24, 12),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('image-overlay-resize')),
      const Offset(24, 12),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(placedBytes, isNotNull);
    final composited = img.decodeImage(placedBytes!);
    expect(composited, isNotNull);
    expect(composited!.width, baseImage.width);
    expect(composited.height, baseImage.height);
    final overlayPixel = composited.getPixel(16, 16);
    expect(overlayPixel.r, greaterThan(overlayPixel.b));
  });

  testWidgets('tapping the document name opens the rename dialog', (
    WidgetTester tester,
  ) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'scanner_pro_rename_test_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));

    final documentDir = Directory('${tempDir.path}/Invoice');
    await documentDir.create(recursive: true);
    final image = img.Image(width: 1200, height: 800);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 20, 40, 80, 255);
      }
    }
    final imageFile = File('${documentDir.path}/1.jpg');
    await imageFile.writeAsBytes(img.encodeJpg(image, quality: 90));

    await tester.pumpWidget(
      MaterialApp(home: DocumentPage(document: DocumentFolder(documentDir))),
    );

    await tester.tap(find.text('Invoice'));
    await tester.pumpAndSettle();

    expect(find.text('Rename file'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets(
    'keeps document actions visible with a long name on a narrow screen',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final tempDir = await Directory.systemTemp.createTemp(
        'scanner_pro_narrow_test_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final documentDir = Directory(
        '${tempDir.path}/A document name that is deliberately very long',
      );
      await documentDir.create(recursive: true);
      final image = img.Image(width: 8, height: 8);
      await File(
        '${documentDir.path}/1.jpg',
      ).writeAsBytes(img.encodeJpg(image));

      await tester.pumpWidget(
        MaterialApp(home: DocumentPage(document: DocumentFolder(documentDir))),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Share document'), findsOneWidget);
      expect(find.byTooltip('Download document'), findsOneWidget);
    },
  );
}

bool _containsBytes(List<int> bytes, List<int> sequence) {
  for (var start = 0; start <= bytes.length - sequence.length; start++) {
    var matches = true;
    for (var index = 0; index < sequence.length; index++) {
      if (bytes[start + index] != sequence[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
