import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/photo_input.dart';
import 'package:beauty_intelligence/vto_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widget_test.dart' show ClientStub;
import 'photo_selection_widget_test.dart' show FakeInput;

Uint8List synthetic() =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: 200, height: 300)));

class VtoApi extends AnalysisApi {
  VtoApi() : super(ClientStub(), 'http://test');
  bool fail = false, loseReply = false;
  Completer<void>? wait;
  List<Map<String, dynamic>> jobs = [];
  List<String> keys = [];
  Map<String, dynamic>? submittedOptions;
  @override
  Future<dynamic> get(String path) async {
    if (wait != null) await wait!.future;
    if (fail) throw ApiException('VTO unavailable');
    return path.endsWith('templates')
        ? [
            {'id': 'real-template', 'title': 'Provider look'},
          ]
        : jobs;
  }

  @override
  Future<Map<String, dynamic>> submitVto(
    Uint8List image,
    String key,
    Map<String, dynamic> options,
  ) async {
    keys.add(key);
    submittedOptions = options;
    if (loseReply) throw ApiException('Connection lost');
    final job = {
      'id': 'job',
      'status': 'pending',
      'options': options,
      'expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    };
    jobs = [job];
    return job;
  }

  @override
  Future<Uint8List> vtoPreview(String id) async {
    if (fail) throw ApiException('Preview expired');
    return synthetic();
  }
}

Future<void> show(WidgetTester tester, VtoApi api, FakeInput input) async {
  tester.view.physicalSize = const Size(1100, 2300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    BeautyApp(
      home: VtoPage(api: api, photoInput: input),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('VTO consent, photo review and lost-reply idempotency', (
    tester,
  ) async {
    final api = VtoApi()..loseReply = true;
    final input = FakeInput()..selected = synthetic();
    await show(tester, api, input);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Choose photo'),
          )
          .onPressed,
      isNull,
    );
    expect(api.keys, isEmpty);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not uploaded until'), findsOneWidget);
    expect(api.keys, isEmpty);
    await tester.tap(find.text('Create preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connection lost'), findsOneWidget);
    api.loseReply = false;
    await tester.tap(find.text('Retry same request'));
    await tester.pumpAndSettle();
    expect(api.keys[0], api.keys[1]);
    expect(find.textContaining('lip_color · pending'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '#123456');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create preview'));
    await tester.pumpAndSettle();
    expect(api.keys.last, isNot(api.keys.first));
  });
  testWidgets('VTO loading empty failure and retry', (tester) async {
    final api = VtoApi()..wait = Completer<void>();
    await show(tester, api, FakeInput());
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.wait!.complete();
    api.wait = null;
    await tester.pumpAndSettle();
    expect(find.textContaining('No previews yet'), findsOneWidget);
    api.fail = true;
    await tester.tap(find.byTooltip('Refresh VTO jobs'));
    await tester.pumpAndSettle();
    expect(find.text('VTO unavailable'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.byTooltip('Refresh VTO jobs'));
    await tester.pumpAndSettle();
    expect(find.text('VTO unavailable'), findsNothing);
  });
  testWidgets('Gallery failure never submits or falls back to camera', (
    tester,
  ) async {
    final input = FakeInput()
      ..error = const PhotoInputException('Unreadable test photo');
    final api = VtoApi();
    await show(tester, api, input);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();
    expect(find.text('Unreadable test photo'), findsOneWidget);
    expect(api.keys, isEmpty);
  });
  testWidgets('Private preview and retention states', (tester) async {
    final api = VtoApi()
      ..jobs = [
        {
          'id': 'job',
          'status': 'completed',
          'options': {'mode': 'lip_color'},
          'expires_at': DateTime.now()
              .add(const Duration(minutes: 30))
              .toIso8601String(),
        },
      ];
    await show(tester, api, FakeInput());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View private preview'));
    await tester.tap(find.text('View private preview'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    api.jobs.first['expires_at'] = DateTime.now()
        .subtract(const Duration(minutes: 1))
        .toIso8601String();
    await show(tester, api, FakeInput());
    await tester.pumpAndSettle();
    expect(find.text('Preview retention ended.'), findsOneWidget);
    expect(find.text('View private preview'), findsNothing);
  });
  test(
    'VTO photo rules accept a small image without changing HD rules',
    () async {
      final bytes = synthetic();
      await expectLater(
        preparePhoto(bytes),
        throwsA(isA<PhotoInputException>()),
      );
      final result = await preparePhoto(
        bytes,
        minimumSide: 100,
        maximumWidth: 1919,
        maximumHeight: 1079,
      );
      final image = img.decodeJpg(result)!;
      expect(image.width, 200);
      expect(image.height, 300);
    },
  );
  test(
    'VTO multipart and private preview use authenticated backend only',
    () async {
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-token');
        expect(request.url.host, 'backend.test');
        if (request.method == 'POST') {
          expect(request.headers['Idempotency-Key'], 'same-key');
          expect(latin1.decode(request.bodyBytes), contains('makeup-vto-v1'));
          expect(latin1.decode(request.bodyBytes), contains('lip_color'));
          return http.Response('{"id":"job"}', 202);
        }
        return http.Response.bytes(
          synthetic(),
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });
      final transport = HeaderApi(client: client);
      expect(
        (await transport.submitVto(synthetic(), 'same-key', {
          'mode': 'lip_color',
        }))['id'],
        'job',
      );
      expect(await transport.vtoPreview('job'), isNotEmpty);
      client.close();
    },
  );
}

class HeaderApi extends AnalysisApi {
  HeaderApi({super.client}) : super(ClientStub(), 'https://backend.test');
  @override
  Future<Map<String, String>> headers() async => {
    'Authorization': 'Bearer test-token',
  };
}
