import 'dart:convert';
import 'dart:ui' as ui;

import 'package:beauty_intelligence/camera_capture.dart';
import 'package:beauty_intelligence/photo_input.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;

import 'synthetic_fixture.dart';

Future<void> waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var attempt = 0; attempt < 240; attempt++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (ready()) return;
  }
  fail(reason);
}

/// Intentionally no API client, credentials, network submission, or real shutter capture.
class ObservedCamera extends DevicePhotoCamera {
  final opened = <CameraLensDirection>[];
  int captures = 0;
  ObservedCamera(super.cameras);
  @override
  Future<void> open(CameraDescription camera) async {
    await super.open(camera);
    opened.add(camera.lensDirection);
  }

  @override
  Future<XFile> capture() async {
    captures++;
    throw StateError('Shutter disabled in offline device test');
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Device decoder converts synthetic gallery WebP into valid upload JPEG',
    (tester) async {
      final jpeg = await preparePhoto(base64Decode(syntheticWebp));
      expect(jpeg.take(2), [0xff, 0xd8]);
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (1200, 1200));
      frame.image.dispose();
      codec.dispose();
    },
  );

  testWidgets(
    'Real device initializes front lens, switches, and cancels without capturing',
    (tester) async {
      final camera = ObservedCamera(await availableCameras());
      expect(
        camera.cameras.any((c) => c.lensDirection == CameraLensDirection.front),
        isTrue,
        reason: 'This device test specifically requires a front camera; fallback is covered by widget tests.',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CameraCapture(load: () async => camera),
                ),
              ),
              child: const Text('Open offline camera check'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open offline camera check'));
      await waitFor(
        tester,
        () => find.text('Front camera').evaluate().isNotEmpty,
        'Front preview did not initialize',
      );
      expect(find.text('Front camera'), findsOneWidget);
      expect(camera.opened.first, CameraLensDirection.front);
      if (camera.cameras.any(
        (c) => c.lensDirection == CameraLensDirection.back,
      )) {
        await waitFor(
          tester,
          () =>
              tester
                  .widget<OutlinedButton>(
                    find.widgetWithText(OutlinedButton, 'Switch camera'),
                  )
                  .onPressed !=
              null,
          'Switch did not become available',
        );
        await tester.tap(find.text('Switch camera'));
        await waitFor(
          tester,
          () =>
              camera.opened.last == CameraLensDirection.back &&
              find.text('Rear / external camera').evaluate().isNotEmpty,
          'Rear preview did not initialize after explicit switch',
        );
        await tester.tap(find.text('Switch camera'));
        await waitFor(
          tester,
          () =>
              camera.opened.last == CameraLensDirection.front &&
              find.text('Front camera').evaluate().isNotEmpty,
          'Front preview did not return after switch',
        );
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(camera.captures, 0);
      expect(find.text('Open offline camera check'), findsOneWidget);
      binding.reportData = {
        'native_front_preview': true,
        'native_switch': camera.opened.length > 1,
        'cancelled_without_capture': camera.captures == 0,
      };
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  if (const bool.fromEnvironment('MANUAL_GALLERY_CHECK')) {
    testWidgets('Native gallery synthetic selection and cancellation', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text(
                'Offline gallery check: select the green/blue synthetic fixture once and cancel once, in either order. No upload occurs.',
              ),
            ),
          ),
        ),
      );
      final input = PhotoInput();
      bool selected = false, cancelled = false;
      for (
        var attempt = 0;
        attempt < 4 && (!selected || !cancelled);
        attempt++
      ) {
        final jpeg = await input.gallery();
        if (jpeg == null) {
          cancelled = true;
          debugPrint(
            'Gallery cancellation verified. Select the green/blue fixture next.',
          );
          continue;
        }
        expect(jpeg.take(2), [0xff, 0xd8]);
        final pixels = img.decodeJpg(jpeg)!;
        expect((pixels.width, pixels.height), (1200, 1200));
        expect(
          pixels.getPixel(100, 600).g > 120 &&
              pixels.getPixel(1100, 600).b > 150,
          isTrue,
          reason: 'Select only the synthetic green/blue fixture',
        );
        selected = true;
        debugPrint(
          'Synthetic gallery selection and JPEG preparation verified. Cancel next.',
        );
      }
      expect(
        selected && cancelled,
        isTrue,
        reason: 'Both synthetic selection and cancellation must be observed',
      );
      binding.reportData = {
        ...?binding.reportData,
        'native_gallery_cancel_and_selection': true,
      };
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
