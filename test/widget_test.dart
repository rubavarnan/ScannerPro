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

  test('uses the resized pixel area, not a linear scale, in the menu labels', () {
    expect(DocumentPage.sizeLabel('Actual', 50 * 1024), 'Actual - 50KB');
    expect(DocumentPage.sizeLabel('Actual', 1024 * 1024), 'Actual - 1MB');
    expect(DocumentPage.sizeLabel('Medium', 50 * 1024), 'Medium - 20KB');
    expect(DocumentPage.sizeLabel('Small', 50 * 1024), 'Small - 6KB');
    expect(DocumentPage.sizeLabel('Smallest', 50 * 1024), 'Smallest - 1KB');
  });

  test('selected export size actually reduces the generated JPG file size', () async {
    final tempDir = await Directory.systemTemp.createTemp('scanner_pro_export_test_');
    addTearDown(() async => tempDir.delete(recursive: true));

    final image = img.Image(width: 3000, height: 2000);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 120, 140, 180, 255);
      }
    }

    final sourceFile = File('${tempDir.path}/source.jpg');
    await sourceFile.writeAsBytes(img.encodeJpg(image, quality: 100));

    final actualPath = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'jpg',
      fileSizeKey: 'Actual',
      fileName: 'actual_size',
    );
    final smallPath = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'jpg',
      fileSizeKey: 'Smallest',
      fileName: 'small_size',
    );

    final actualSize = File(actualPath).lengthSync();
    final smallestSize = File(smallPath).lengthSync();

    expect(actualSize, greaterThan(smallestSize));
    expect(actualSize - smallestSize, greaterThan(1000));
  });

  test('selected size key reduces both PDF and JPG downloads through the shared export helper', () async {
    final tempDir = await Directory.systemTemp.createTemp('scanner_pro_export_size_test_');
    addTearDown(() async => tempDir.delete(recursive: true));

    final image = img.Image(width: 3000, height: 2000);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 120, 140, 180, 255);
      }
    }

    final sourceFile = File('${tempDir.path}/source.jpg');
    await sourceFile.writeAsBytes(img.encodeJpg(image, quality: 100));

    final actualPdf = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'pdf',
      fileSizeKey: 'Actual',
      fileName: 'actual_pdf',
    );
    final smallestPdf = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'pdf',
      fileSizeKey: 'Smallest',
      fileName: 'smallest_pdf',
    );
    final actualJpg = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'jpg',
      fileSizeKey: 'Actual',
      fileName: 'actual_jpg',
    );
    final smallestJpg = await exportDocumentImagesToDownloads(
      images: [sourceFile],
      fileType: 'jpg',
      fileSizeKey: 'Smallest',
      fileName: 'smallest_jpg',
    );

    expect(File(actualPdf).lengthSync(), greaterThan(File(smallestPdf).lengthSync()));
    expect(File(actualJpg).lengthSync(), greaterThan(File(smallestJpg).lengthSync()));
  });
}
