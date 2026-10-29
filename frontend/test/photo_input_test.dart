import 'dart:io';

import 'package:beauty_intelligence/photo_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

class TestPicker extends ImagePicker {
  LostDataResponse lost = LostDataResponse.empty();
  @override
  Future<LostDataResponse> retrieveLostData() async => lost;
  XFile? selected;
  PlatformException? failure;
  ImageSource? source;
  bool? fullMetadata;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    this.source = source;
    fullMetadata = requestFullMetadata;
    if (failure != null) throw failure!;
    return selected;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Browser fallback accepts JPEG/PNG/WebP, bakes orientation and keeps HD rules', () {
    final small = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 400, height: 600)),
    );
    expect(
      () => prepareBrowserPhoto(small),
      throwsA(isA<PhotoInputException>()),
    );
    for (final bytes in [
      small,
      Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 600))),
      Uint8List.fromList(img.encodeWebP(img.Image(width: 400, height: 600))),
    ]) {
      final result = prepareBrowserPhoto(
        bytes,
        minimumSide: 100,
        maximumWidth: 1919,
        maximumHeight: 1079,
      );
      final decoded = img.decodeJpg(result)!;
      expect((decoded.width, decoded.height), (400, 600));
      expect(decoded.exif.imageIfd.isEmpty, true);
    }
    final rotated = prepareBrowserPhoto(
      File('test/fixtures/rotated.jpg').readAsBytesSync(),
    );
    expect(
      (img.decodeJpg(rotated)!.width, img.decodeJpg(rotated)!.height),
      (1200, 2000),
    );
    expect(
      () => prepareBrowserPhoto(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<PhotoInputException>()),
    );
  });

  test(
    'Interrupted Android selection reads the recovered XFile bytes',
    () async {
      final bytes = File('test/fixtures/gallery.png').readAsBytesSync();
      final picker = TestPicker()
        ..lost = LostDataResponse(
          files: [XFile.fromData(bytes)],
          type: RetrieveType.image,
        );
      final output = await PhotoInput(
        picker: picker,
        prepare: (data) async => data,
      ).recover();
      expect(output, bytes);
    },
  );

  test(
    'WebP bytes with a content-style path become an actual JPEG upload',
    () async {
      final bytes = File('test/fixtures/gallery.webp').readAsBytesSync();
      final picker = TestPicker()
        ..selected = XFile.fromData(
          bytes,
          path: 'content://synthetic-provider/selection',
          name: 'wrong-extension.jpg',
        );
      final output = await PhotoInput(picker: picker).gallery();
      expect(picker.source, ImageSource.gallery);
      expect(picker.fullMetadata, isFalse);
      expect(output!.take(2), [0xff, 0xd8]);
      final decoded = img.decodeJpg(output)!;
      expect((decoded.width, decoded.height), (1200, 1200));
      expect(decoded.exif.isEmpty, isTrue);
    },
  );

  test('Orientation is applied before preparing upload pixels', () async {
    final output = await preparePhoto(
      File('test/fixtures/rotated.jpg').readAsBytesSync(),
    );
    final decoded = img.decodeJpg(output)!;
    expect((decoded.width, decoded.height), (1200, 2000));
  });

  test('Small images get a resolution error without upscaling', () async {
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 474, height: 474)),
    );
    await expectLater(
      preparePhoto(bytes),
      throwsA(
        isA<PhotoInputException>().having(
          (e) => e.message,
          'message',
          contains('474 × 474'),
        ),
      ),
    );
  });

  test(
    'Wide original that becomes too short after resizing is rejected locally',
    () async {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 4000, height: 1080)),
      );
      await expectLater(
        preparePhoto(bytes),
        throwsA(
          isA<PhotoInputException>().having(
            (e) => e.message,
            'message',
            contains('after resizing'),
          ),
        ),
      );
    },
  );

  test(
    'Corrupt files produce decoding guidance rather than connection errors',
    () async {
      await expectLater(
        preparePhoto(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<PhotoInputException>().having(
            (e) => e.message,
            'message',
            contains('JPEG or PNG'),
          ),
        ),
      );
    },
  );

  test('Cancel returns no photo and never switches to camera', () async {
    final picker = TestPicker();
    expect(await PhotoInput(picker: picker).gallery(), isNull);
    expect(picker.source, ImageSource.gallery);
  });

  test('Permission failure is distinct from network failure', () async {
    final picker = TestPicker()
      ..failure = PlatformException(code: 'photo_access_denied');
    try {
      await PhotoInput(picker: picker).gallery();
      fail('Expected denial');
    } catch (e) {
      expect(photoInputMessage(e), contains('Photo access was denied'));
    }
  });
}
