import 'dart:io';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/photo_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ClientStub implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfflineApi extends AnalysisApi {
  int submits = 0;
  OfflineApi() : super(ClientStub(), 'http://offline');
  @override
  Future<dynamic> get(String path) async => [];
  @override
  Future<Map<String, dynamic>> submit(Uint8List image, String key) async {
    submits++;
    throw StateError('No test may submit an analysis');
  }
}

class FakeInput extends PhotoInput {
  int selections = 0;
  Uint8List? selected, recovered;
  Object? error;
  @override
  Future<Uint8List?> recover() async => recovered;
  @override
  Future<Uint8List?> gallery() async {
    selections++;
    if (error != null) throw error!;
    return selected;
  }
}

void main() {
  Future<void> show(
    WidgetTester tester,
    FakeInput input,
    OfflineApi api, {
    WidgetBuilder? capture,
  }) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BeautyApp(
        home: ScanHome(
          client: ClientStub(),
          apiUrl: 'http://offline',
          api: api,
          photoInput: input,
          captureBuilder: capture,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Gallery denial offers retry, never starts camera or submits', (
    tester,
  ) async {
    final input = FakeInput()
      ..error = PlatformException(code: 'photo_access_denied');
    final api = OfflineApi();
    int cameraStarts = 0;
    await show(
      tester,
      input,
      api,
      capture: (_) {
        cameraStarts++;
        return const Scaffold();
      },
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Photo access was denied'), findsOneWidget);
    expect(find.text('Retry photo selection'), findsOneWidget);
    expect(cameraStarts, 0);
    expect(api.submits, 0);
    input.error = null;
    await tester.tap(find.text('Retry photo selection'));
    await tester.pumpAndSettle();
    expect(input.selections, 2);
    expect(cameraStarts, 0);
    expect(api.submits, 0);
  });

  testWidgets(
    'Valid gallery preview waits for explicit upload; cancellation is harmless',
    (tester) async {
      final input = FakeInput()
        ..selected = File('test/fixtures/gallery.png').readAsBytesSync();
      final api = OfflineApi();
      await show(tester, input, api);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Choose photo'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Analyze photo / retry upload'), findsOneWidget);
      expect(api.submits, 0);
      input.selected = null;
      await tester.tap(find.text('Choose photo'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(api.submits, 0);
    },
  );

  testWidgets(
    'Recovered selection requires consent and is never automatically uploaded',
    (tester) async {
      final input = FakeInput()
        ..recovered = File('test/fixtures/gallery.png').readAsBytesSync();
      final api = OfflineApi();
      await show(tester, input, api);
      expect(
        find.textContaining('interrupted photo selection was recovered'),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('Analyze photo / retry upload'), findsNothing);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(api.submits, 0);
    },
  );

  testWidgets(
    'Decode failure clears stale selection and still allows explicit camera choice',
    (tester) async {
      final input = FakeInput()
        ..selected = File('test/fixtures/gallery.png').readAsBytesSync();
      final api = OfflineApi();
      int cameraStarts = 0;
      await show(
        tester,
        input,
        api,
        capture: (context) {
          cameraStarts++;
          return Scaffold(
            body: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel capture'),
            ),
          );
        },
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Choose photo'));
      await tester.pumpAndSettle();
      input.error = const PhotoInputException(
        'Unsupported or damaged image. Choose another original.',
      );
      await tester.tap(find.text('Choose photo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unsupported or damaged'), findsOneWidget);
      expect(find.text('Analyze photo / retry upload'), findsNothing);
      expect(cameraStarts, 0);
      await tester.tap(find.text('Take photo'));
      await tester.pumpAndSettle();
      expect(cameraStarts, 1);
      await tester.tap(find.text('Cancel capture'));
      await tester.pumpAndSettle();
      expect(api.submits, 0);
    },
  );
}
