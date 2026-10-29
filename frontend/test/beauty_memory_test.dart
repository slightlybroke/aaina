import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/beauty_memory_page.dart';
import 'package:beauty_intelligence/education_page.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;

class MemoryApi extends AnalysisApi {
  MemoryApi() : super(ClientStub(), 'http://test');
  List<Map<String, dynamic>> rows = [];
  bool fail = false, saveFail = false;
  final calls = <Map<String, dynamic>>[];
  @override
  Future<dynamic> get(String path) async {
    if (fail) throw ApiException('Memory unavailable');
    return {'items': rows, 'has_more': false};
  }

  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add({'method': method, 'path': path, 'body': body});
    if (saveFail) throw ApiException('Save unavailable; retry');
    if (method == 'DELETE') {
      rows = [];
      return {'deleted': true};
    }
    if (path.endsWith('/confirm')) {
      rows = [
        {
          ...rows.single,
          'status': 'confirmed',
          'share_with_ai': body!['share_with_ai'],
          'version': 2,
        },
      ];
      return rows.single;
    }
    rows = [
      {
        ...body!,
        'id': path.split('/').last,
        'status': 'confirmed',
        'source': 'user_entry',
        'updated_at': '2026-10-28T00:00:00Z',
        'version': 1,
      },
    ];
    return rows.single;
  }
}

class LessonApi extends AnalysisApi {
  LessonApi() : super(ClientStub(), 'http://test');
  bool fail = false;
  Map<String, dynamic>? sent;
  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    sent = body;
    if (fail) throw ApiException('Lesson unavailable');
    return {
      'title': 'Understanding sunscreen labels',
      'status': body!['use_ai'] ? 'reference_fallback' : 'reference_only',
      'facts': [
        {'id': 'protection', 'text': 'Reviewed protection facts'},
      ],
      'caution': 'General education only',
      'limitations': 'Suitability not verified',
      'memory_context': [],
      'sources': [
        {'title': 'AAD', 'url': 'https://www.aad.org/'},
      ],
      'reviewed_at': '2026-10-28',
    };
  }
}

void main() {
  Future<void> large(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1000, 2200));
    addTearDown(() => t.binding.setSurfaceSize(null));
  }

  testWidgets('Memory empty, loading failure and explicit reload', (t) async {
    await large(t);
    final api = MemoryApi()..fail = true;
    await t.pumpWidget(BeautyApp(home: BeautyMemoryPage(api: api)));
    await t.pumpAndSettle();
    expect(find.text('Memory unavailable'), findsOneWidget);
    api.fail = false;
    await t.tap(find.text('Reload memories'));
    await t.pumpAndSettle();
    expect(find.textContaining('No memories found'), findsOneWidget);
  });
  testWidgets(
    'Memory creation keeps failed draft, retries stable ID, edits version and confirms deletion',
    (t) async {
      await large(t);
      final api = MemoryApi();
      await t.pumpWidget(BeautyApp(home: BeautyMemoryPage(api: api)));
      await t.pumpAndSettle();
      await t.tap(find.text('Add memory'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextField, 'Memory text'),
        'I prefer satin finishes',
      );
      api.saveFail = true;
      await t.tap(find.text('Save reviewed memory'));
      await t.pumpAndSettle();
      expect(find.text('Save unavailable; retry'), findsOneWidget);
      expect(find.text('I prefer satin finishes'), findsOneWidget);
      api.saveFail = false;
      await t.tap(find.text('Save reviewed memory'));
      await t.pumpAndSettle();
      expect(api.calls[0]['path'], api.calls[1]['path']);
      expect(api.rows.single['share_with_ai'], false);
      await t.tap(find.text('Edit'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextField, 'Memory text'),
        'Updated preference',
      );
      await t.tap(find.text('Save reviewed memory'));
      await t.pumpAndSettle();
      expect(api.calls.last['body']['expected_version'], 1);
      expect(find.text('Updated preference'), findsOneWidget);
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(find.text('Delete this memory?'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await t.pumpAndSettle();
      expect(api.rows, isEmpty);
    },
  );
  testWidgets('Pending inference review explicitly chooses AI sharing', (
    t,
  ) async {
    await large(t);
    final api = MemoryApi()
      ..rows = [
        {
          'id': 'fixture',
          'text': 'Might like matte',
          'kind': 'inference',
          'category': 'preference',
          'status': 'pending',
          'share_with_ai': false,
          'source': 'user_entry',
          'source_quote': '',
          'version': 1,
          'updated_at': 'today',
        },
      ];
    await t.pumpWidget(BeautyApp(home: BeautyMemoryPage(api: api)));
    await t.pumpAndSettle();
    await t.tap(find.text('Review and confirm'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm and allow sharing'));
    await t.pumpAndSettle();
    expect(api.calls.single['body']['share_with_ai'], true);
    expect(find.textContaining('inference · confirmed'), findsOneWidget);
  });
  testWidgets(
    'Education reference defaults, consent gating, source display and stale result clearing',
    (t) async {
      await large(t);
      final api = LessonApi();
      await t.pumpWidget(BeautyApp(home: EducationPage(api: api)));
      await t.pumpAndSettle();
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Use Gemini to select relevant facts',
      );
      expect(t.widget<SwitchListTile>(toggle).onChanged, isNull);
      await t.tap(find.text('Show lesson'));
      await t.pumpAndSettle();
      expect(api.sent!['use_ai'], false);
      expect(api.sent!.containsKey('consent_version'), false);
      expect(find.textContaining('https://www.aad.org/'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Explain water resistance');
      await t.pump();
      expect(find.text('Reviewed protection facts'), findsNothing);
      await t.tap(find.byType(CheckboxListTile));
      await t.pump();
      await t.tap(toggle);
      await t.pump();
      await t.tap(find.text('Show lesson'));
      await t.pumpAndSettle();
      expect(api.sent!['consent_version'], 'beauty-education-v1');
      expect(
        find.textContaining('Gemini selection was unavailable'),
        findsOneWidget,
      );
    },
  );
  testWidgets('Education failure is retryable', (t) async {
    await large(t);
    final api = LessonApi()..fail = true;
    await t.pumpWidget(BeautyApp(home: EducationPage(api: api)));
    await t.pumpAndSettle();
    await t.tap(find.text('Show lesson'));
    await t.pumpAndSettle();
    expect(find.text('Lesson unavailable'), findsOneWidget);
    api.fail = false;
    await t.tap(find.text('Retry lesson'));
    await t.pumpAndSettle();
    expect(find.text('Reviewed protection facts'), findsOneWidget);
  });
}
