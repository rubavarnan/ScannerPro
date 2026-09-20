import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scanner_pro/main.dart';

void main() {
  test('brightness and contrast adjustment preserves valid pixel range', () {
    final image = img.Image(width: 2, height: 1);
    image.setPixelRgba(0, 0, 128, 128, 128, 255);
    image.setPixelRgba(1, 0, 64, 64, 64, 255);

    final adjusted = applyBrightnessAndContrast(image, brightness: 10, contrast: 20);

    expect(adjusted.width, 2);
    expect(adjusted.height, 1);
    expect(adjusted.getPixel(0, 0).r, inInclusiveRange(0, 255));
    expect(adjusted.getPixel(0, 0).g, inInclusiveRange(0, 255));
    expect(adjusted.getPixel(0, 0).b, inInclusiveRange(0, 255));
    expect(adjusted.getPixel(1, 0).r, inInclusiveRange(0, 255));
    expect(adjusted.getPixel(1, 0).g, inInclusiveRange(0, 255));
    expect(adjusted.getPixel(1, 0).b, inInclusiveRange(0, 255));
    expect(adjusted.getPixel(0, 0).r, isNot(equals(0)));
    expect(adjusted.getPixel(0, 0).g, isNot(equals(0)));
    expect(adjusted.getPixel(0, 0).b, isNot(equals(0)));
  });

  test('edited jpeg storage is compressed to a smaller size than raw 100% quality output', () {
    final image = img.Image(width: 1200, height: 1200);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, 120, 140, 160, 255);
      }
    }

    final raw = Uint8List.fromList(img.encodeJpg(image, quality: 100));
    final compressed = compressEditedImage(raw, quality: 82);

    expect(compressed.lengthInBytes, lessThan(raw.lengthInBytes));
    expect(compressed.lengthInBytes, greaterThan(0));
  });
}
