import 'dart:async';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/discovery_page.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;

Map<String, dynamic> product(String id) => {
  'id': id,
  'name': 'Recorded lipstick',
  'brand': 'Fixture brand',
  'category': 'lipstick',
  'shade_name': 'Recorded shade',
  'finish': 'satin',
  'source_url': 'https://www.elfcosmetics.com.au/',
  'source_region': 'Australia',
  'checked_on': '2026-10-28',
};

class DiscoveryApi extends AnalysisApi {
  DiscoveryApi() : super(ClientStub(), 'http://test');
  bool fail = false, empty = false;
  Completer<void>? gate;
  List<Uri> reads = [];
  List<Map<String, dynamic>> writes = [];
  @override
  Future<dynamic> get(String path) async {
    if (gate != null) await gate!.future;
    if (fail) throw ApiException('Catalogue unavailable');
    final uri = Uri.parse(path);
    reads.add(uri);
    return {
      'items': empty
          ? []
          : [
              product(
                uri.queryParameters['offset'] == '0'
                    ? 'catalogue-one'
                    : 'catalogue-two',
              ),
            ],
      'has_more': !empty && uri.queryParameters['offset'] == '0',
      'categories': ['lipstick'],
      'brands': ['Fixture brand'],
      'exact_vto_available': false,
    };
  }

  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    writes.add({'method': method, 'path': path, 'data': data});
    return {'id': path.split('/').last, ...?data, 'version': 1};
  }
}

Future<void> show(WidgetTester t, DiscoveryApi api) async {
  t.view.physicalSize = const Size(1000, 2200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(BeautyApp(home: DiscoveryPage(api: api)));
  await t.pump();
}

void main() {
  testWidgets(
    'Catalogue loading empty error retry and no automatic ownership',
    (t) async {
      final api = DiscoveryApi()..gate = Completer<void>();
      await show(t, api);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      api.empty = true;
      api.gate!.complete();
      api.gate = null;
      await t.pumpAndSettle();
      expect(find.textContaining('No products found'), findsOneWidget);
      expect(api.writes, isEmpty);
      api.fail = true;
      await t.tap(find.byTooltip('Refresh catalogue'));
      await t.pumpAndSettle();
      expect(find.text('Catalogue unavailable'), findsOneWidget);
      api.fail = false;
      api.empty = false;
      await t.tap(find.text('Retry catalogue'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('Fixture brand · Recorded lipstick'),
        findsOneWidget,
      );
      expect(
        find.textContaining('No verified exact product-to-VTO'),
        findsOneWidget,
      );
    },
  );
  testWidgets('Search/filter/pagination stays on backend catalogue', (t) async {
    final api = DiscoveryApi();
    await show(t, api);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'shade & words');
    await t.tap(find.byTooltip('Search catalogue'));
    await t.pumpAndSettle();
    expect(api.reads.last.queryParameters['q'], 'shade & words');
    await t.tap(find.text('All categories'));
    await t.pumpAndSettle();
    await t.tap(find.text('lipstick').last);
    await t.pumpAndSettle();
    expect(api.reads.last.queryParameters['category'], 'lipstick');
    await t.ensureVisible(find.text('Load more products'));
    await t.tap(find.text('Load more products'));
    await t.pumpAndSettle();
    expect(api.reads.last.queryParameters['offset'], '1');
    expect(
      find.textContaining('Fixture brand · Recorded lipstick'),
      findsNWidgets(2),
    );
    expect(api.writes, isEmpty);
  });
  testWidgets(
    'Owned copy is reviewed, uses a new ID, and never changes catalogue',
    (t) async {
      final api = DiscoveryApi();
      await show(t, api);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('I own this — add to Vanity'));
      await t.tap(find.text('I own this — add to Vanity'));
      await t.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, 'Recorded lipstick'),
        findsOneWidget,
      );
      expect(api.writes, isEmpty);
      final save = find.text('Save product');
      await t.ensureVisible(save);
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.writes.length, 1);
      expect(api.writes.single['path'], startsWith('/v1/vanity/'));
      expect(api.writes.single['path'], isNot(contains('catalogue-one')));
      expect(api.writes.single['data']['shade_name'], 'Recorded shade');
    },
  );
}
