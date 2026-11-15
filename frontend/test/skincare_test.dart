import 'dart:async';
import 'dart:convert';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/skincare_home.dart';
import 'package:beauty_intelligence/routine_editor.dart';
import 'package:beauty_intelligence/journal_editor.dart';
import 'package:beauty_intelligence/skin_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widget_test.dart' show ClientStub;

const rid = '11111111-1111-4111-8111-111111111111';
const sid = '22222222-2222-4222-8222-222222222222';
const tid = '33333333-3333-4333-8333-333333333333';
Map<String, dynamic> routine() => {
  'routine_id': rid,
  'revision_id': 'revision',
  'local_date': '2026-10-26',
  'scheduled': true,
  'completion': 'incomplete',
  'completed_steps': <String>[],
  'definition': {
    'name': 'My morning',
    'kind': 'morning',
    'status': 'active',
    'days': [1, 2, 3, 4, 5, 6, 7],
    'steps': [
      {'id': sid, 'name': 'Cleanser'},
      {'id': tid, 'name': 'Moisturizer'},
    ],
  },
  'latest_revision': {
    'id': 'revision',
    'effective_from': '2026-10-26',
    'definition': {
      'name': 'My morning',
      'kind': 'morning',
      'status': 'active',
      'days': [1, 2, 3, 4, 5, 6, 7],
      'steps': [
        {'id': sid, 'name': 'Cleanser'},
        {'id': tid, 'name': 'Moisturizer'},
      ],
    },
  },
};

class TrackingApi extends AnalysisApi {
  bool fail = false;
  String? failPath;
  Completer<void>? gate;
  List<Map<String, dynamic>> rows = [];
  List<dynamic> journal = [];
  List<Map<String, dynamic>> writes = [];
  TrackingApi() : super(ClientStub(), 'http://test');
  @override
  Future<dynamic> get(String path) async {
    if (gate != null) await gate!.future;
    if (fail || path == failPath) throw ApiException('Tracking is unavailable');
    if (path.startsWith('/v1/skincare/routines')) {
      return {
        'today': '2026-10-26',
        'date': '2026-10-26',
        'timezone': 'UTC',
        'timezone_locked': rows.isNotEmpty,
        'routines': rows,
      };
    }
    if (path.startsWith('/v1/skincare/history')) {
      return {
        'summary': {
          'start': '2026-09-27',
          'end': '2026-10-26',
          'completed': 0,
          'scheduled': rows.length,
          'partial': 0,
          'adherence_percent': null,
          'routines': [],
        },
        'days': [],
      };
    }
    if (path.startsWith('/v1/skincare/journal')) return journal;
    if (path.startsWith('/v1/analyses')) return [];
    throw StateError('Unexpected request $path');
  }

  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    if (fail) throw ApiException('Save unavailable');
    writes.add({'method': method, 'path': path, 'data': data});
    if (path.endsWith('/checkins')) {
      rows.first['completed_steps'] = data!['completed_steps'];
      rows.first['completion'] = (data['completed_steps'] as List).length == 2
          ? 'complete'
          : (data['completed_steps'] as List).isEmpty
          ? 'incomplete'
          : 'partial';
    }
    return data ?? {};
  }
}

class HeadersApi extends AnalysisApi {
  HeadersApi(http.Client client)
    : super(ClientStub(), 'http://test', client: client);
  @override
  Future<Map<String, String>> headers() async => {
    'Authorization': 'Bearer test',
  };
}

Future<void> large(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Future<void> open(WidgetTester tester, Widget child) async {
  await large(tester);
  await tester.pumpWidget(BeautyApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Saved next-day steps are visible separately from today’s checklist',
    (tester) async {
      final row = routine();
      row['definition']['steps'] = [
        {'id': sid, 'name': 'Original step'},
      ];
      row['latest_revision'] = {
        'id': 'next-revision',
        'effective_from': '2026-10-27',
        'definition': {
          'name': 'Updated morning',
          'status': 'active',
          'steps': [
            {'id': sid, 'name': 'Renamed step'},
            {'id': tid, 'name': 'Added step'},
          ],
        },
      };
      final api = TrackingApi()..rows = [row];
      await open(
        tester,
        SkincareHome(client: ClientStub(), apiUrl: 'http://test', api: api),
      );
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('Original step'), findsOneWidget);
      expect(find.text('Saved version · starts 2026-10-27'), findsOneWidget);
      expect(find.text('Updated morning · 2 steps · active'), findsOneWidget);
      await tester.tap(find.text('Saved version · starts 2026-10-27'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed step'), findsOneWidget);
      expect(find.text('Added step'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(api.writes, isEmpty);
    },
  );
  testWidgets(
    'Progress compares shared regional metrics and charts saved values',
    (tester) async {
      Map<String, dynamic> result(String id, String time, num score) => {
        'id': id,
        'analyzed_at': time,
        'overall_score': score,
        'api_version': '2.1',
        'response_format': 'zip',
        'metrics': [
          {
            'concern': 'hd_acne',
            'region': 'whole',
            'ui_score': score,
            'raw_score': null,
          },
        ],
      };
      await open(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: SkinProgress(
              analyses: [
                result('a', '2026-10-01T10:00:00Z', 80),
                result('b', '2026-10-20T10:00:00Z', 90),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Shared metrics'), findsOneWidget);
      expect(find.textContaining('UI: 80.00 → 90.00'), findsOneWidget);
      expect(
        find.textContaining('Raw: Not available → Not available'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is ScoreTrend,
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'Dashboard fits a narrow phone and journal deletion requires confirmation',
    (tester) async {
      final api = TrackingApi()
        ..journal = [
          {
            'id': rid,
            'concerns': ['dryness'],
            'notes': 'Private observation',
            'observed_at': '2026-10-20T00:00:00Z',
          },
        ];
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        BeautyApp(
          home: SkincareHome(
            client: ClientStub(),
            apiUrl: 'http://test',
            api: api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      await tester.tap(find.text('Journal'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete observation'));
      await tester.tap(find.text('Delete observation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      await tester.tap(find.text('Delete observation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(api.writes.single['method'], 'DELETE');
      expect(api.writes.single['path'], '/v1/skincare/journal/$rid');
      expect(tester.takeException(), null);
    },
  );
  test('JSON writes preserve authentication and useful field errors', () async {
    final api = HeadersApi(
      MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.headers['authorization'], 'Bearer test');
        expect(jsonDecode(request.body), {'name': 'Morning'});
        return http.Response(
          '{"detail":[{"loc":["body","name"],"msg":"Enter a name"}]}',
          422,
        );
      }),
    );
    await expectLater(
      api.write('PUT', '/test', {'name': 'Morning'}),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('name: Enter a name'),
        ),
      ),
    );
    api.close();
  });
  testWidgets('Dashboard loading empty failure and retry states', (
    tester,
  ) async {
    final api = TrackingApi()..gate = Completer<void>();
    await large(tester);
    await tester.pumpWidget(
      BeautyApp(
        home: SkincareHome(
          client: ClientStub(),
          apiUrl: 'http://test',
          api: api,
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('No scheduled routines today'), findsOneWidget);
    expect(find.text('No skin analyses yet.'), findsOneWidget);
    expect(api.writes, isEmpty);
    api.fail = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Tracking is unavailable'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('Retry loading'));
    await tester.pumpAndSettle();
    expect(find.text('Create routine'), findsOneWidget);
  });
  testWidgets('Routine creation validates and saves custom ordered steps', (
    tester,
  ) async {
    final api = TrackingApi();
    await open(tester, RoutineEditor(api: api));
    await tester.ensureVisible(find.text('Save routine'));
    await tester.tap(find.text('Save routine'));
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Routine name'),
      'Custom care',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Step name'),
      'Wash',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Product name (optional)'),
      'Plain product',
    );
    await tester.ensureVisible(find.text('Add step'));
    await tester.tap(find.text('Add step'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Step name').last,
      'Protect',
    );
    await tester.ensureVisible(find.byTooltip('Move step up').last);
    await tester.tap(find.byTooltip('Move step up').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save routine'));
    await tester.tap(find.text('Save routine'));
    await tester.pumpAndSettle();
    final data = api.writes.single['data'];
    expect(data['name'], 'Custom care');
    expect(data['steps'][0]['name'], 'Protect');
    expect(data['steps'][1]['product'], 'Plain product');
    expect(data['expected_revision'], null);
  });
  testWidgets('Routine edits carry revision and preserve stable step IDs', (
    tester,
  ) async {
    final api = TrackingApi();
    await open(tester, RoutineEditor(api: api, routine: routine()));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Routine name'),
      'Updated',
    );
    await tester.ensureVisible(find.byTooltip('Delete step').last);
    await tester.tap(find.byTooltip('Delete step').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save changes for tomorrow'));
    await tester.tap(find.text('Save changes for tomorrow'));
    await tester.pumpAndSettle();
    expect(api.writes.single['data']['expected_revision'], 'revision');
    expect(api.writes.single['data']['steps'].length, 1);
    expect(api.writes.single['data']['steps'][0]['id'], sid);
  });
  testWidgets('Scan history failure still allows routine check-ins', (
    tester,
  ) async {
    final api = TrackingApi()
      ..failPath = '/v1/analyses'
      ..rows = [routine()];
    await open(
      tester,
      SkincareHome(client: ClientStub(), apiUrl: 'http://test', api: api),
    );
    expect(find.text('Latest scan unavailable.'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Cleanser'));
    await tester.pumpAndSettle();
    expect(api.writes.single['data']['completed_steps'], [sid]);
  });

  testWidgets('Today shortcut opens the skin analysis flow', (tester) async {
    final client = ClientStub();
    await open(
      tester,
      SkincareHome(client: client, apiUrl: 'http://test', api: TrackingApi()),
    );
    await tester.tap(find.text('Open skin analysis'));
    await tester.pump();
    expect(find.text('A closer look at your skin'), findsOneWidget);
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.byTooltip('Digital vanity'), findsOneWidget);
    await tester.tap(find.text('Today'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Today’s routines'), findsOneWidget);
  });

  testWidgets('Check-ins complete individual steps and can be corrected', (
    tester,
  ) async {
    final api = TrackingApi()..rows = [routine()];
    await open(
      tester,
      SkincareHome(client: ClientStub(), apiUrl: 'http://test', api: api),
    );
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Cleanser'));
    await tester.pumpAndSettle();
    expect(find.textContaining('partial ·'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Moisturizer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('complete ·'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Cleanser'));
    await tester.pumpAndSettle();
    expect(api.writes.last['data']['completed_steps'], [tid]);
    expect(find.textContaining('partial ·'), findsOneWidget);
  });
  testWidgets('Unscheduled routines cannot be marked complete', (tester) async {
    final api = TrackingApi()..rows = [routine()..['scheduled'] = false];
    await open(
      tester,
      SkincareHome(client: ClientStub(), apiUrl: 'http://test', api: api),
    );
    await tester.tap(find.text('Routines'));
    await tester.pumpAndSettle();
    final tile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Cleanser'),
    );
    expect(tile.onChanged, isNull);
    expect(api.writes, isEmpty);
  });
  testWidgets('Journal logging and editing are independent of analysis', (
    tester,
  ) async {
    final api = TrackingApi();
    await open(tester, JournalEditor(api: api));
    await tester.tap(find.text('Save observation'));
    await tester.pumpAndSettle();
    expect(find.text('Select at least one concern.'), findsOneWidget);
    await tester.tap(find.text('dryness'));
    await tester.enterText(find.byType(TextField), 'Feels dry');
    await tester.tap(find.text('Save observation'));
    await tester.pumpAndSettle();
    expect(api.writes.single['data']['concerns'], ['dryness']);
    expect(api.writes.single['data']['observed_at'], endsWith('Z'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      BeautyApp(
        home: JournalEditor(
          api: api,
          entry: {
            'id': rid,
            'concerns': ['redness'],
            'notes': 'Old',
            'severity': 'mild',
            'observed_at': '2026-01-01T12:00:00Z',
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Changed');
    await tester.tap(find.text('Save observation'));
    await tester.pumpAndSettle();
    expect(api.writes.last['path'], '/v1/skincare/journal/$rid');
    expect(api.writes.last['data']['notes'], 'Changed');
  });
  testWidgets('Editor API failure stays editable for retry', (tester) async {
    final api = TrackingApi()..fail = true;
    await open(
      tester,
      JournalEditor(
        api: api,
        entry: {
          'id': rid,
          'concerns': ['dryness'],
          'observed_at': '2026-01-01T00:00:00Z',
        },
      ),
    );
    await tester.tap(find.text('Save observation'));
    await tester.pumpAndSettle();
    expect(find.text('Save unavailable'), findsOneWidget);
    expect(find.text('Save observation'), findsOneWidget);
  });
  testWidgets(
    'Saved analysis handles missing metrics without invented scores',
    (tester) async {
      await open(
        tester,
        const Scaffold(
          body: SingleChildScrollView(
            child: SavedAnalysis(
              analysis: {
                'overall_score': 92.25,
                'metrics': [
                  {
                    'concern': 'hd_acne',
                    'region': 'whole',
                    'raw_score': null,
                    'ui_score': 99,
                  },
                ],
              },
            ),
          ),
        ),
      );
      expect(find.textContaining('92.25'), findsOneWidget);
      await tester.tap(find.text('Available metrics (1)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Raw: Not available'), findsOneWidget);
    },
  );
  test('Progress refuses incompatible modes and versions', () {
    final base = {
      'api_version': '2.1',
      'response_format': 'zip',
      'metrics': [
        {'concern': 'hd_acne', 'region': 'whole'},
      ],
    };
    expect(comparisonGroup(base), isNotNull);
    expect(comparisonGroup({...base, 'api_version': 'unknown'}), null);
    expect(comparisonGroup({...base, 'metrics': []}), null);
    expect(
      comparisonGroup({
        ...base,
        'metrics': [
          {'concern': 'acne'},
        ],
      }),
      null,
    );
    expect(validScore(double.nan), null);
    expect(validScore(0), null);
  });
}
