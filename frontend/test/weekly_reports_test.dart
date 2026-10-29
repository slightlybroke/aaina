import 'dart:async';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/weekly_reports_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;

Map<String, dynamic> report() => {
  'id': 'fixture',
  'week_start': '2026-10-19',
  'week_end': '2026-10-25',
  'timezone': 'UTC',
  'generated_at': '2026-10-28T00:00:00Z',
  'read_at': null,
  'content': {
    'routine': <String, dynamic>{
      'completed': 1,
      'partial': 1,
      'scheduled': 2,
      'adherence_percent': 50,
      'routines': [],
    },
    'skin': {
      'count': 1,
      'message': 'Two compatible analyses are needed.',
      'comparison': null,
      'latest': {'overall_score': 92.25},
    },
    'journal': {
      'entries': 1,
      'concerns': {'dryness': 1},
      'severity_counts': {'mild': 1},
    },
    'suggestions': ['A new scan is optional.'],
    'notes': 'Separate signals; snapshot available records.',
  },
};

class ReportsApi extends AnalysisApi {
  ReportsApi() : super(ClientStub(), 'http://test');
  List<Map<String, dynamic>> rows = [];
  bool fail = false, saveFail = false;
  Completer<void>? gate;
  List<String> writes = [];
  @override
  Future<dynamic> get(String path) async {
    if (gate != null) await gate!.future;
    if (fail) throw ApiException('Reports unavailable');
    if (path == '/v1/skincare/settings') {
      return {'timezone': 'UTC', 'timezone_locked': true};
    }
    if (path.startsWith('/v1/weekly-reports?') ||
        path == '/v1/weekly-reports') {
      return {
        'items': rows,
        'has_more': false,
        'has_unread': rows.any((r) => r['read_at'] == null),
      };
    }
    return rows.single;
  }

  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    writes.add(path);
    if (saveFail) throw ApiException('Report save unavailable; retry');
    if (path == '/v1/skincare/settings') return {'timezone': body!['timezone']};
    if (path.endsWith('/generate')) {
      if (rows.isEmpty) rows = [report()];
      return rows.single;
    }
    rows.single['read_at'] = '2026-10-28T01:00:00Z';
    return rows.single;
  }
}

void main() {
  testWidgets(
    'Legacy locked UTC can be explicitly confirmed for report enrollment',
    (t) async {
      final api = ReportsApi();
      await t.binding.setSurfaceSize(const Size(1000, 2000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(BeautyApp(home: WeeklyReportsPage(api: api)));
      await t.pumpAndSettle();
      await t.tap(find.text('Set report timezone'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('Routine history fixes this timezone'),
        findsOneWidget,
      );
      expect(
        t.widget<TextFormField>(find.byType(TextFormField)).enabled,
        false,
      );
      await t.tap(find.text('Confirm timezone'));
      await t.pumpAndSettle();
      expect(api.writes.single, '/v1/skincare/settings');
    },
  );
  Future<void> open(WidgetTester t, ReportsApi api) async {
    await t.binding.setSurfaceSize(const Size(1000, 2300));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(BeautyApp(home: WeeklyReportsPage(api: api)));
    await t.pumpAndSettle();
  }

  testWidgets(
    'Empty report state, safe generation retry, separate signals and read acknowledgement',
    (t) async {
      final api = ReportsApi();
      await open(t, api);
      expect(find.textContaining('No weekly reports yet'), findsOneWidget);
      api.saveFail = true;
      await t.tap(find.text('Prepare last week’s brief'));
      await t.pumpAndSettle();
      expect(find.text('Report save unavailable; retry'), findsOneWidget);
      api.saveFail = false;
      await t.tap(find.text('Prepare last week’s brief'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('1 complete · 1 partial · 2 scheduled'),
        findsOneWidget,
      );
      expect(find.text('Latest overall score: 92.25 / 100'), findsOneWidget);
      expect(find.textContaining('user-reported, not AI'), findsOneWidget);
      expect(api.rows.length, 1);
      await t.tap(find.text('Mark this report as read'));
      await t.pumpAndSettle();
      expect(api.writes.last, endsWith('/fixture/read'));
      expect(find.text('Mark this report as read'), findsNothing);
      await t.tap(find.text('Prepare last week’s brief'));
      await t.pumpAndSettle();
      expect(api.rows.length, 1);
      expect(find.text('Mark this report as read'), findsNothing);
    },
  );
  testWidgets('Loading and error retry preserve access to history', (t) async {
    final api = ReportsApi()..gate = Completer<void>();
    await t.pumpWidget(BeautyApp(home: WeeklyReportsPage(api: api)));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.fail = true;
    api.gate!.complete();
    api.gate = null;
    await t.pumpAndSettle();
    expect(find.text('Reports unavailable'), findsOneWidget);
    api.fail = false;
    api.rows = [report()];
    await t.tap(find.text('Retry loading reports'));
    await t.pumpAndSettle();
    await t.tap(find.text('2026-10-19 to 2026-10-25'));
    await t.pumpAndSettle();
    expect(find.text('Completion: 50%'), findsOneWidget);
  });
  testWidgets('Dashboard notification refreshes after returning from reports', (
    t,
  ) async {
    final api = ReportsApi()..rows = [report()];
    var opened = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeeklyReportsShortcut(
            api: api,
            open: () async {
              opened++;
              api.rows.single['read_at'] = 'read';
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('new report'), findsOneWidget);
    await t.tap(find.textContaining('new report'));
    await t.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Weekly Beauty Brief'), findsOneWidget);
  });
  testWidgets('Missing data is explicit and does not render a fake score', (
    t,
  ) async {
    final r = report();
    r['content']['routine']['adherence_percent'] = null;
    r['content']['skin'] = {
      'count': 0,
      'comparison': null,
      'message': 'No compatible analyses.',
    };
    final api = ReportsApi()..rows = [r];
    await open(t, api);
    await t.tap(find.text('2026-10-19 to 2026-10-25'));
    await t.pumpAndSettle();
    expect(find.textContaining('adherence is not calculated'), findsOneWidget);
    expect(find.textContaining('Latest overall score:'), findsNothing);
  });
}
