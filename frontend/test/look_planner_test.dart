import 'dart:async';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/look_planner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;

class PlanApi extends AnalysisApi {
  PlanApi() : super(ClientStub(), 'http://test');
  bool fail = false;
  Completer<void>? gate;
  Map<String, dynamic>? request;
  Map<String, dynamic> response = {
    'inventory_count': 0,
    'status': 'needs_information',
    'suggestions': [],
    'questions': ['Which categories would you like?'],
    'gaps': [],
    'limitations': ['No color harmony is inferred.'],
  };
  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    expect(method, 'POST');
    expect(path, '/v1/looks/plan');
    request = data;
    if (gate != null) await gate!.future;
    if (fail) throw ApiException('Planner unavailable');
    return response;
  }
}

Future<void> open(WidgetTester tester, PlanApi api) async {
  await tester.binding.setSurfaceSize(const Size(1100, 2300));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(BeautyApp(home: LookPlannerPage(api: api)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Collects explicit context/preferences and shows empty/clarification state',
    (tester) async {
      final api = PlanApi();
      await open(tester, api);
      expect(api.request, null);
      await tester.enterText(
        find.byKey(const ValueKey('look-occasion')),
        'Dinner',
      );
      await tester.enterText(
        find.byKey(const ValueKey('look-outfit')),
        'Blue outfit',
      );
      await tester.enterText(
        find.byKey(const ValueKey('look-categories')),
        'lipstick, custom eyes',
      );
      await tester.enterText(
        find.byKey(const ValueKey('look-excluded_categories')),
        'foundation',
      );
      await tester.enterText(
        find.byKey(const ValueKey('look-preferred_shade')),
        'Rose',
      );
      await tester.tap(find.text('Build look plan'));
      await tester.pumpAndSettle();
      expect(api.request!['categories'], ['lipstick', 'custom eyes']);
      expect(api.request!['outfit'], 'Blue outfit');
      expect(api.request!.containsKey('user_id'), false);
      expect(find.textContaining('Your vanity is empty'), findsOneWidget);
      expect(find.text('Which categories would you like?'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('look-occasion')),
        'Changed request',
      );
      await tester.pumpAndSettle();
      expect(find.text('Your look plan'), findsNothing);
      expect(api.request!['occasion'], 'Dinner');
    },
  );
  testWidgets('Loading, error and retry preserve entered request', (
    tester,
  ) async {
    final api = PlanApi()..gate = Completer<void>();
    await open(tester, api);
    await tester.enterText(
      find.byKey(const ValueKey('look-preferred_finish')),
      'matte',
    );
    await tester.tap(find.text('Build look plan'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.fail = true;
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Planner unavailable'), findsOneWidget);
    api.fail = false;
    api.gate = null;
    await tester.tap(find.text('Retry look plan'));
    await tester.pumpAndSettle();
    expect(api.request!['preferred_finish'], 'matte');
  });
  testWidgets(
    'Renders only returned product facts, reasons, gaps and unknown labels',
    (tester) async {
      final api = PlanApi()
        ..response = {
          'inventory_count': 1,
          'status': 'partial',
          'questions': [],
          'limitations': ['Recorded labels only.'],
          'gaps': [
            {'category': 'mascara', 'reason': 'No owned product recorded.'},
          ],
          'suggestions': [
            {
              'category': 'lipstick',
              'product': {
                'id': 'owned',
                'name': 'My product',
                'brand': '',
                'shade_name': 'Rose',
                'shade_identifier': '',
                'finish': '',
                'undertone': '',
              },
              'reasons': ['Fills the lipstick step.'],
              'missing_fields': ['finish', 'undertone'],
            },
          ],
        };
      await open(tester, api);
      await tester.tap(find.text('Build look plan'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('lipstick: My product'));
      expect(find.text('shade name: Rose'), findsOneWidget);
      expect(find.text('brand: Not recorded'), findsOneWidget);
      expect(find.text('Fills the lipstick step.'), findsOneWidget);
      await tester.ensureVisible(find.text('Gap: mascara'));
      expect(find.text('Gap: mascara'), findsOneWidget);
    },
  );
}
