import 'dart:async';
import 'dart:typed_data';

import 'package:beauty_intelligence/camera_capture.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const rear = CameraDescription(
  name: 'rear',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

class FakeCamera implements PhotoCamera {
  @override
  final List<CameraDescription> cameras;
  final opened = <CameraDescription>[];
  int captures = 0, closes = 0;
  CameraException? failure;
  Completer<void>? opening;
  XFile? result;
  FakeCamera(this.cameras);
  @override
  Future<void> open(CameraDescription camera) async {
    opened.add(camera);
    await opening?.future;
    if (failure != null) throw failure!;
  }

  @override
  Widget preview() =>
      const SizedBox(key: Key('preview'), width: 100, height: 100);
  @override
  Future<XFile> capture() async {
    captures++;
    if (result != null) return result!;
    throw CameraException('captureFailed', 'test');
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  testWidgets(
    'Background during initialization can resume instead of leaving a spinner',
    (tester) async {
      final camera = FakeCamera([front])..opening = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(home: CameraCapture(load: () async => camera)),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      camera.opening!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('preview')), findsOneWidget);
    },
  );

  testWidgets(
    'Explicit capture returns a file for review, not an automatic upload',
    (tester) async {
      final output = XFile.fromData(Uint8List.fromList([1, 2, 3]));
      final camera = FakeCamera([front])..result = output;
      Object? returned;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                returned = await Navigator.of(context).push<XFile>(
                  MaterialPageRoute(
                    builder: (_) => CameraCapture(load: () async => camera),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use photo'));
      await tester.pumpAndSettle();
      expect(returned, same(output));
      expect(camera.captures, 1);
    },
  );
  testWidgets('Switch prefers opposite facing lens over another front lens', (
    tester,
  ) async {
    const otherFront = CameraDescription(
      name: 'front-2',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 270,
    );
    final camera = FakeCamera([rear, front, otherFront]);
    await tester.pumpWidget(
      MaterialApp(home: CameraCapture(load: () async => camera)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch camera'));
    await tester.pumpAndSettle();
    expect(camera.opened.last, rear);
    await tester.tap(find.text('Switch camera'));
    await tester.pumpAndSettle();
    expect(camera.opened.last, front);
  });
  testWidgets(
    'Explicit front selection works regardless of enumeration order, then switches',
    (tester) async {
      final camera = FakeCamera([rear, front]);
      await tester.pumpWidget(
        MaterialApp(home: CameraCapture(load: () async => camera)),
      );
      await tester.pumpAndSettle();
      expect(camera.opened.single, front);
      expect(find.text('Front camera'), findsOneWidget);
      await tester.tap(find.text('Switch camera'));
      await tester.pumpAndSettle();
      expect(camera.opened.last, rear);
      expect(find.byKey(const Key('preview')), findsOneWidget);
      expect(camera.captures, 0);
    },
  );

  testWidgets(
    'Device without front camera uses rear and disables unavailable switch',
    (tester) async {
      final camera = FakeCamera([rear]);
      await tester.pumpWidget(
        MaterialApp(home: CameraCapture(load: () async => camera)),
      );
      await tester.pumpAndSettle();
      expect(camera.opened.single, rear);
      expect(find.textContaining('No front camera'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Switch camera'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('No camera shows retry and gallery guidance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CameraCapture(load: () async => FakeCamera([]))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No usable camera'), findsOneWidget);
    expect(find.text('Retry camera'), findsOneWidget);
  });

  testWidgets('Permission denial is actionable and retry is explicit', (
    tester,
  ) async {
    final camera = FakeCamera([front])
      ..failure = CameraException('CameraAccessDenied', 'test');
    await tester.pumpWidget(
      MaterialApp(home: CameraCapture(load: () async => camera)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Allow camera access'), findsOneWidget);
    camera.failure = null;
    await tester.tap(find.text('Retry camera'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('preview')), findsOneWidget);
  });

  testWidgets(
    'Background releases camera and foreground reopens selected lens',
    (tester) async {
      final camera = FakeCamera([rear, front]);
      await tester.pumpWidget(
        MaterialApp(home: CameraCapture(load: () async => camera)),
      );
      await tester.pumpAndSettle();
      final before = camera.closes;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(camera.closes, greaterThan(before));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(camera.opened.length, 2);
      expect(camera.opened.last, front);
    },
  );

  testWidgets('Cancel exits capture without taking or returning a photo', (
    tester,
  ) async {
    final camera = FakeCamera([front]);
    Object? returned = 'pending';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              returned = await Navigator.of(context).push<XFile>(
                MaterialPageRoute(
                  builder: (_) => CameraCapture(load: () async => camera),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(returned, isNull);
    expect(camera.captures, 0);
  });
}
