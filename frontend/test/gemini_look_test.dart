import 'dart:async';
import 'dart:convert';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/gemini_look_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widget_test.dart' show ClientStub;
import 'skincare_test.dart' show HeadersApi;

class ChatApi extends AnalysisApi {
  ChatApi() : super(ClientStub(), 'http://test');
  final List<Map<String, dynamic>> calls = [];
  Completer<void>? gate;
  bool fail = false;
  Map<String, dynamic> response = {
    'reply': 'Which style do you prefer?',
    'plan': null,
    'questions': ['Natural or bold?'],
    'explanations': [],
    'ai_status': 'clarification',
  };
  @override
  Future<dynamic> converse(Map<String, dynamic> data) async {
    calls.add(data);
    if (gate != null) await gate!.future;
    if (fail) {
      throw ApiException('Gemini is unavailable. Use the manual planner.');
    }
    return response;
  }
}

Future<void> open(WidgetTester tester, ChatApi api) async {
  await tester.binding.setSurfaceSize(const Size(1000, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(BeautyApp(home: GeminiLookPage(api: api)));
  await tester.pumpAndSettle();
}

Future<void> consent(WidgetTester tester) async {
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
}

Future<void> send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.text('Send to Gemini'));
  await tester.pumpAndSettle();
}

void main() {
  test('Conversation transport authenticates without a provider key', () async {
    final api = HeadersApi(
      MockClient((r) async {
        expect(r.method, 'POST');
        expect(r.url.path, '/v1/looks/conversation');
        expect(r.headers['authorization'], 'Bearer test');
        expect(r.headers.containsKey('x-goog-api-key'), false);
        expect(jsonDecode(r.body)['consent_version'], 'gemini-look-v1');
        return http.Response('{"reply":"Question"}', 200);
      }),
    );
    await api.converse({'consent_version': 'gemini-look-v1', 'messages': []});
    api.close();
  });
  testWidgets('Consent gates all sends and clarification supports follow-up', (
    tester,
  ) async {
    final api = ChatApi();
    await open(tester, api);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Send to Gemini'),
          )
          .onPressed,
      null,
    );
    expect(api.calls, isEmpty);
    await consent(tester);
    await send(tester, 'Help me plan for dinner');
    expect(find.textContaining('Which style do you prefer?'), findsOneWidget);
    await send(tester, 'Natural, lipstick only');
    expect(api.calls.last['messages'].length, 3);
    expect(api.calls.last['consent_version'], 'gemini-look-v1');
    expect(api.calls.last.containsKey('user_id'), false);
    await consent(tester);
    expect(find.textContaining('You: Help me'), findsNothing);
  });
  testWidgets('Loading and failure retain draft for explicit retry', (
    tester,
  ) async {
    final api = ChatApi()
      ..gate = Completer<void>()
      ..fail = true;
    await open(tester, api);
    await consent(tester);
    await tester.enterText(find.byType(TextField), 'A natural look');
    await tester.pump();
    await tester.tap(find.text('Send to Gemini'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.text('Gemini is unavailable. Use the manual planner.'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'A natural look',
    );
    api.fail = false;
    api.gate = null;
    await tester.tap(find.text('Retry message'));
    await tester.pumpAndSettle();
    expect(api.calls.last['messages'].length, 1);
  });
  testWidgets('Shows only returned product facts and transparent fallback', (
    tester,
  ) async {
    final api = ChatApi()
      ..response = {
        'reply': 'Here is your plan.',
        'questions': [],
        'ai_status': 'deterministic_fallback',
        'plan': {
          'inventory_count': 1,
          'status': 'ready',
          'gaps': [],
          'limitations': ['No exact try-on.'],
          'suggestions': [
            {
              'category': 'lipstick',
              'product': {
                'id': 'owned',
                'name': 'Recorded lipstick',
                'brand': '',
                'shade_name': 'Rose',
                'shade_identifier': '',
                'finish': 'satin',
                'undertone': '',
              },
              'reasons': ['Stored category fits requested role.'],
            },
          ],
        },
        'explanations': [
          {
            'product_id': 'owned',
            'reasons': ['Stored category fits requested role.'],
          },
        ],
      };
    await open(tester, api);
    await consent(tester);
    await send(tester, 'Plan lips');
    await tester.ensureVisible(find.text('lipstick: Recorded lipstick'));
    expect(find.text('shade name: Rose'), findsOneWidget);
    expect(find.text('brand: Not recorded'), findsOneWidget);
    expect(
      find.textContaining('AI explanation selection was unavailable'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pumpAndSettle();
    expect(find.text('lipstick: Recorded lipstick'), findsNothing);
  });
}
