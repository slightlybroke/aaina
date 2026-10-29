import 'package:beauty_intelligence/api.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:beauty_intelligence/makeup_preferences_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;
import 'gemini_look_test.dart' as chat;

class PrefApi extends AnalysisApi {
  PrefApi() : super(ClientStub(), 'http://test');
  bool fail = false;
  Map<String, dynamic> data = {
    'preferred_shade': '',
    'preferred_finish': '',
    'excluded_categories': [],
    'source': null,
    'updated_at': null,
  };
  int writes = 0;
  @override
  Future<dynamic> get(String path) async {
    if (fail) throw ApiException('Preferences unavailable');
    return data;
  }

  @override
  Future<dynamic> write(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    writes++;
    if (method == 'DELETE') {
      data = {
        'preferred_shade': '',
        'preferred_finish': '',
        'excluded_categories': [],
        'source': null,
        'updated_at': null,
      };
      return {'deleted': true};
    }
    data = {
      ...body!,
      'source': 'explicit_profile',
      'updated_at': '2026-10-28T00:00:00Z',
    };
    return data;
  }
}

void main() {
  testWidgets('Explicit preferences save reload and confirmed deletion', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1000, 2100));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final api = PrefApi();
    await t.pumpWidget(BeautyApp(home: MakeupPreferencesPage(api: api)));
    await t.pumpAndSettle();
    expect(find.textContaining('No saved preferences yet'), findsOneWidget);
    await t.enterText(
      find.widgetWithText(TextField, 'Preferred finish label (optional)'),
      'satin',
    );
    await t.enterText(
      find.widgetWithText(TextField, 'Excluded categories (comma separated)'),
      'foundation, eyeliner',
    );
    await t.tap(find.text('Save preferences'));
    await t.pumpAndSettle();
    expect(api.data['preferred_finish'], 'satin');
    expect(api.data['excluded_categories'], ['foundation', 'eyeliner']);
    await t.tap(find.text('Delete saved preferences'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(api.writes, 1);
    await t.tap(find.text('Delete saved preferences'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete preferences'));
    await t.pumpAndSettle();
    expect(api.data['source'], null);
    expect(find.text('Saved preferences deleted.'), findsOneWidget);
  });
  testWidgets('Preference read failure has explicit retry', (t) async {
    final api = PrefApi()..fail = true;
    await t.pumpWidget(BeautyApp(home: MakeupPreferencesPage(api: api)));
    await t.pumpAndSettle();
    expect(find.text('Preferences unavailable'), findsOneWidget);
    api.fail = false;
    await t.tap(find.text('Reload preferences'));
    await t.pumpAndSettle();
    expect(find.text('Preferences unavailable'), findsNothing);
  });
  testWidgets('Saved context is off by default and opt-in is sent explicitly', (
    t,
  ) async {
    final api = chat.ChatApi();
    await chat.open(t, api);
    await chat.consent(t);
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Use saved makeup preferences',
    );
    expect(t.widget<SwitchListTile>(toggle).value, false);
    await t.tap(toggle);
    await t.pumpAndSettle();
    await chat.send(t, 'Plan using my preferences');
    expect(api.calls.single['use_saved_preferences'], true);
    expect(t.widget<SwitchListTile>(toggle).onChanged, null);
  });
  testWidgets('Memory retrieval and narrow capture are separate opt-ins', (
    t,
  ) async {
    final api = chat.ChatApi();
    await chat.open(t, api);
    await chat.consent(t);
    final memory = find.widgetWithText(
      SwitchListTile,
      'Use shared Beauty Memory',
    );
    final capture = find.widgetWithText(
      SwitchListTile,
      'Remember clearly stated finish preferences',
    );
    expect(t.widget<SwitchListTile>(memory).value, false);
    expect(t.widget<SwitchListTile>(capture).value, false);
    await t.tap(memory);
    await t.tap(capture);
    await t.pumpAndSettle();
    await chat.send(t, 'I prefer matte finishes.');
    expect(api.calls.single['use_beauty_memory'], true);
    expect(api.calls.single['remember_stable_preferences'], true);
    expect(t.widget<SwitchListTile>(memory).onChanged, null);
    expect(t.widget<SwitchListTile>(capture).onChanged, null);
  });
}
