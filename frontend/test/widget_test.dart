import 'dart:typed_data';

import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:beauty_intelligence/photo_input.dart';

class NoRecoveryPhotoInput extends PhotoInput {
  @override
  Future<Uint8List?> recover() async => null;
}

class EmptyApi extends AnalysisApi {
  bool fail = false;
  EmptyApi(SupabaseClient client) : super(client, 'http://test');
  @override
  Future<dynamic> get(String path) async {
    if (fail) throw ApiException('Connection failed');
    return [];
  }
}

class ClientStub implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'Failed face-size job shows recovery without a loading indicator',
    (tester) async {
      await tester.pumpWidget(
        BeautyApp(
          home: Scaffold(
            body: JobCard(
              job: {
                'status': 'failed',
                'error_code': 'error_src_face_too_small',
                'cleanup_status': 'deleted',
              },
              onRefresh: () {},
            ),
          ),
        ),
      );
      expect(
        find.textContaining('closer, front-facing portrait'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
  testWidgets(
    'Photo selection requires consent and empty history is explicit',
    (tester) async {
      await tester.view.setSurfaceSizeForTest();
      final client = ClientStub();
      final api = EmptyApi(client);
      await tester.pumpWidget(
        BeautyApp(
          home: ScanHome(
            client: client,
            apiUrl: 'http://test',
            api: api,
            photoInput: NoRecoveryPhotoInput(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final choose = find.widgetWithText(OutlinedButton, 'Choose photo');
      expect(tester.widget<OutlinedButton>(choose).onPressed, isNull);
      expect(
        find.text('No scans yet. Your first analysis will appear here.'),
        findsOneWidget,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(tester.widget<OutlinedButton>(choose).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Connection failure offers retry', (tester) async {
    await tester.view.setSurfaceSizeForTest();
    final client = ClientStub();
    final api = EmptyApi(client)..fail = true;
    await tester.pumpWidget(
      BeautyApp(
        home: ScanHome(
          client: client,
          apiUrl: 'http://test',
          api: api,
          photoInput: NoRecoveryPhotoInput(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Retry connection'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Results preserve provider values and disclose missing fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      BeautyApp(
        home: Scaffold(
          body: ResultCard(
            analysis: {
              'overall_score': 75.75,
              'analyzed_at': '2026-10-25',
              'metrics': [
                {
                  'concern': 'hd_acne',
                  'region': 'whole',
                  'ui_score': 76,
                  'raw_score': null,
                },
              ],
              'warnings': ['missing_raw_score:hd_acne:whole'],
            },
          ),
        ),
      ),
    );
    expect(find.textContaining('75.8 / 100'), findsOneWidget);
    expect(find.textContaining('UI: 76   Raw: Unavailable'), findsOneWidget);
    expect(
      find.textContaining('Some requested data was unavailable'),
      findsOneWidget,
    );
  });
  testWidgets('Uncertain submission explains duplicate prevention', (
    tester,
  ) async {
    await tester.pumpWidget(
      BeautyApp(
        home: Scaffold(
          body: JobCard(
            job: {
              'status': 'failed',
              'error_code': 'submission_unknown',
              'cleanup_status': 'pending',
            },
            onRefresh: () {},
          ),
        ),
      ),
    );
    expect(
      find.textContaining('did not automatically submit again'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}

extension on TestFlutterView {
  Future<void> setSurfaceSizeForTest() async {
    physicalSize = const Size(1200, 1800);
    devicePixelRatio = 1;
    addTearDown(resetPhysicalSize);
    addTearDown(resetDevicePixelRatio);
  }
}
