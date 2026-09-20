import 'dart:io';

import 'package:flutter/material.dart';
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

  test('uses the standard platform Downloads directory without nesting a Scanner Pro folder', () {
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
  });

  test('keeps the custom export filename without duplicating the extension', () {
    expect(sanitizeExportFileName('Invoice', 'jpg'), 'Invoice');
    expect(sanitizeExportFileName('Invoice.jpg', 'jpg'), 'Invoice');
    expect(sanitizeExportFileName('Invoice.pdf', 'jpg'), 'Invoice.pdf');
    expect(sanitizeExportFileName('  My Report  ', 'jpg'), 'My Report');
  });

  test('exports JPG and PDF files successfully without a size selector', () async {
    final tempDir = await Directory.systemTemp.createTemp('scanner_pro_export_test_');
    addTearDown(() async => tempDir.delete(recursive: true));

    final image = img.Image(width: 1200, height: 800);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 120, 140, 180, 255);
      }
    }

    final sourceFile = File('${tempDir.path}/source.jpg');
    await sourceFile.writeAsBytes(img.encodeJpg(image, quality: 100));

    final jpgPath = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'jpg',
      fileName: 'exported_jpg',
    );
    final pdfPath = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'pdf',
      fileName: 'exported_pdf',
    );

    expect(File(jpgPath).existsSync(), isTrue);
    expect(File(pdfPath).existsSync(), isTrue);
    expect(File(jpgPath).lengthSync(), greaterThan(0));
    expect(File(pdfPath).lengthSync(), greaterThan(0));
  });

  testWidgets('tapping the document name opens the rename dialog', (WidgetTester tester) async {
    final tempDir = await Directory.systemTemp.createTemp('scanner_pro_rename_test_');
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

    await tester.pumpWidget(MaterialApp(
      home: DocumentPage(document: DocumentFolder(documentDir)),
    ));

    await tester.tap(find.text('Invoice'));
    await tester.pumpAndSettle();

    expect(find.text('Rename file'), findsOneWidget);
  });
}
