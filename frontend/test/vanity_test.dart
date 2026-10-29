import 'dart:async';

import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/skincare_home.dart';
import 'package:beauty_intelligence/vanity_page.dart';
import 'package:beauty_intelligence/vanity_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;
import 'skincare_test.dart' show TrackingApi;

Map<String, dynamic> product(
  String id, {
  String name = 'My lipstick',
  String category = 'lipstick',
}) => {
  'id': id,
  'name': name,
  'brand': '',
  'category': category,
  'shade_name': '',
  'shade_identifier': '',
  'finish': '',
  'undertone': '',
  'notes': '',
  'version': 1,
};

class VanityApi extends AnalysisApi {
  VanityApi() : super(ClientStub(), 'http://test');
  List<Map<String, dynamic>> items = [];
  List<Map<String, dynamic>> writes = [];
  List<Uri> reads = [];
  bool failRead = false, failWrite = false, loseResponse = false;
  Completer<void>? gate;
  int pageSize = 50;
  @override
  Future<dynamic> get(String path) async {
    if (gate != null) await gate!.future;
    if (failRead) throw ApiException('Inventory unavailable');
    final uri = Uri.parse(path);
    reads.add(uri);
    if (uri.path != '/v1/vanity') {
      return {...items.firstWhere((i) => i['id'] == uri.pathSegments.last)};
    }
    final query = (uri.queryParameters['q'] ?? '').toLowerCase();
    final category = uri.queryParameters['category'] ?? '';
    final offset = int.parse(uri.queryParameters['offset'] ?? '0');
    final matches = items
        .where(
          (r) =>
              (category.isEmpty || r['category'] == category) &&
              r.values.join(' ').toLowerCase().contains(query),
        )
        .toList();
    return {
      'items': matches.skip(offset).take(pageSize).toList(),
      'has_more': matches.length > offset + pageSize,
      'categories': items.map((r) => r['category']).toSet().toList(),
    };
  }

  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    if (failWrite) {
      throw ApiException('Product changed. Reload before editing.');
    }
    writes.add({'method': method, 'path': path, 'data': data});
    final id = Uri.parse(path).pathSegments.last;
    if (method == 'DELETE') {
      items.removeWhere((r) => r['id'] == id);
      if (loseResponse) {
        loseResponse = false;
        throw ApiException('Delete response lost. Refresh your inventory.');
      }
      return {'deleted': true};
    }
    final index = items.indexWhere((r) => r['id'] == id);
    final unchanged =
        index >= 0 &&
        data!.entries
            .where((e) => e.key != 'expected_version')
            .every((e) => items[index][e.key] == e.value);
    final value = {
      ...product(id),
      ...data!,
      'version': index < 0 ? 1 : items[index]['version'] + (unchanged ? 0 : 1),
    };
    if (index < 0) {
      items.add(value);
    } else {
      items[index] = value;
    }
    if (loseResponse) {
      loseResponse = false;
      throw ApiException('Save response lost. Retry safely.');
    }
    return value;
  }
}

Future<void> screen(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1100, 2300),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(BeautyApp(home: child));
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save product'));
  await tester.tap(find.text('Save product'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Refresh after a lost delete response removes stale displayed data',
    (tester) async {
      final api = VanityApi()
        ..items = [product('owned')]
        ..loseResponse = true;
      await screen(tester, VanityPage(api: api));
      await tester.tap(find.text('Delete product'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text('Delete response lost. Refresh your inventory.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry loading products'));
      await tester.pumpAndSettle();
      expect(find.text('My lipstick'), findsNothing);
      expect(find.textContaining('Your vanity is empty'), findsOneWidget);
    },
  );
  testWidgets('Inventory loading empty failure and retry', (tester) async {
    final api = VanityApi()..gate = Completer<void>();
    await tester.pumpWidget(BeautyApp(home: VanityPage(api: api)));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Your vanity is empty'), findsOneWidget);
    api.failRead = true;
    await tester.tap(find.byTooltip('Refresh products'));
    await tester.pumpAndSettle();
    expect(find.text('Inventory unavailable'), findsOneWidget);
    api.failRead = false;
    await tester.tap(find.text('Retry loading products'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your vanity is empty'), findsOneWidget);
  });
  testWidgets('Only name is required and unknown metadata stays blank', (
    tester,
  ) async {
    final api = VanityApi();
    await screen(tester, VanityEditor(api: api));
    await save(tester);
    expect(api.writes, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('vanity-name')),
      'My unlabeled product',
    );
    await save(tester);
    final data = api.writes.single['data'];
    expect(data['category'], 'other');
    expect(data['shade_name'], '');
    expect(data['brand'], '');
    expect(data['expected_version'], null);
  });
  testWidgets('Custom category and all optional metadata save and edit', (
    tester,
  ) async {
    final api = VanityApi()..items = [product('owned')];
    await screen(tester, VanityEditor(api: api, item: api.items.single));
    for (final key in [
      'brand',
      'category',
      'shade_name',
      'shade_identifier',
      'finish',
      'undertone',
      'notes',
    ]) {
      await tester.ensureVisible(find.byKey(ValueKey('vanity-$key')));
      await tester.enterText(
        find.byKey(ValueKey('vanity-$key')),
        'Recorded $key',
      );
    }
    await save(tester);
    expect(api.writes.single['path'], '/v1/vanity/owned');
    expect(api.writes.single['data']['expected_version'], 1);
    for (final key in [
      'brand',
      'category',
      'shade_name',
      'shade_identifier',
      'finish',
      'undertone',
      'notes',
    ]) {
      expect(api.items.single[key], 'Recorded $key');
    }
  });
  testWidgets('Lost save response retries same ID without duplicate product', (
    tester,
  ) async {
    final api = VanityApi()..loseResponse = true;
    await screen(tester, VanityEditor(api: api));
    await tester.enterText(
      find.byKey(const ValueKey('vanity-name')),
      'Retry product',
    );
    await save(tester);
    expect(find.text('Save response lost. Retry safely.'), findsOneWidget);
    await save(tester);
    expect(api.items.length, 1);
    expect(api.items.single['version'], 1);
    expect(api.writes[0]['path'], api.writes[1]['path']);
  });
  testWidgets(
    'Stale update stays editable and explicit reload refreshes version',
    (tester) async {
      final api = VanityApi()
        ..items = [product('owned')]
        ..failWrite = true;
      await screen(tester, VanityEditor(api: api, item: api.items.single));
      await tester.enterText(
        find.byKey(const ValueKey('vanity-name')),
        'Unsaved name',
      );
      await save(tester);
      expect(
        find.text('Product changed. Reload before editing.'),
        findsOneWidget,
      );
      api.items.single['name'] = 'Saved elsewhere';
      api.items.single['version'] = 2;
      api.failWrite = false;
      await tester.tap(find.text('Reload saved product (discards edits)'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('vanity-name')))
            .controller!
            .text,
        'Saved elsewhere',
      );
      await save(tester);
      expect(api.writes.single['data']['expected_version'], 2);
    },
  );
  testWidgets(
    'Search is encoded, categories filter, and no-match state can clear',
    (tester) async {
      final api = VanityApi()
        ..items = [
          product('one', name: 'Literal 50%_, shade'),
          product('two', name: 'Eye product', category: 'custom eyes'),
        ];
      await screen(tester, VanityPage(api: api));
      await tester.enterText(find.byType(TextField), '50%_,');
      await tester.tap(find.byTooltip('Search products'));
      await tester.pumpAndSettle();
      expect(api.reads.last.queryParameters['q'], '50%_,');
      expect(find.text('Literal 50%_, shade'), findsOneWidget);
      expect(find.text('Eye product'), findsNothing);
      await tester.tap(find.text('Clear search and filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('custom eyes').last);
      await tester.pumpAndSettle();
      expect(api.reads.last.queryParameters['category'], 'custom eyes');
      expect(find.text('Eye product'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.tap(find.byTooltip('Search products'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No products match'), findsOneWidget);
    },
  );
  testWidgets(
    'Delete is confirmed and failed delete preserves visible inventory',
    (tester) async {
      final api = VanityApi()..items = [product('owned')];
      await screen(tester, VanityPage(api: api));
      await tester.tap(find.text('Delete product'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      api.failWrite = true;
      await tester.tap(find.text('Delete product'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('My lipstick'), findsOneWidget);
      api.failWrite = false;
      await tester.tap(find.text('Delete product'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(api.items, isEmpty);
      expect(find.textContaining('Your vanity is empty'), findsOneWidget);
    },
  );
  testWidgets('Pagination appends owned items without resetting page', (
    tester,
  ) async {
    final api = VanityApi()
      ..pageSize = 1
      ..items = [product('one', name: 'First'), product('two', name: 'Second')];
    await screen(tester, VanityPage(api: api));
    await tester.ensureVisible(find.text('Load more products'));
    await tester.tap(find.text('Load more products'));
    await tester.pumpAndSettle();
    expect(api.reads.last.queryParameters['offset'], '1');
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
  });
  testWidgets(
    'Narrow screen handles incomplete metadata and long custom category',
    (tester) async {
      final api = VanityApi()
        ..items = [product('owned', category: 'custom category ' * 5)];
      await screen(tester, VanityPage(api: api), size: const Size(360, 800));
      expect(find.text('Brand not recorded'), findsOneWidget);
      expect(find.text('Shade not recorded'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'Dashboard exposes Vanity without replacing existing destinations',
    (tester) async {
      await screen(
        tester,
        SkincareHome(
          client: ClientStub(),
          apiUrl: 'http://test',
          api: TrackingApi(),
        ),
      );
      expect(find.byTooltip('Digital vanity'), findsOneWidget);
      expect(find.text('Open digital vanity'), findsOneWidget);
      for (final name in [
        'Today',
        'Routines',
        'Journal',
        'Progress',
        'Skin analysis',
      ]) {
        expect(find.text(name), findsOneWidget);
      }
    },
  );
}
