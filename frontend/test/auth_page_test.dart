import 'package:beauty_intelligence/auth_page.dart';
import 'package:beauty_intelligence/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show ClientStub;

void main() {
  testWidgets('Welcome previews multiple flows and opens password recovery', (
    tester,
  ) async {
    await tester.pumpWidget(
      BeautyApp(
        home: AuthPage(
          client: ClientStub(),
          initialMode: AuthMode.welcome,
          onPasswordUpdated: () async {},
          onSignedIn: () {},
        ),
      ),
    );
    expect(find.text('Understand your skin'), findsOneWidget);
    await tester.tap(find.byTooltip('Next feature'));
    await tester.pump();
    expect(find.text('Build a routine'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Sign in'), 100);
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.tap(find.text('Forgot password?'));
    await tester.pump();
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
  });

  testWidgets(
    'Signup validates that the two passwords match before submitting',
    (tester) async {
      await tester.pumpWidget(
        BeautyApp(
          home: AuthPage(
            client: ClientStub(),
            initialMode: AuthMode.signUp,
            onPasswordUpdated: () async {},
            onSignedIn: () {},
          ),
        ),
      );
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'test@example.com');
      await tester.enterText(fields.at(1), 'first-pass');
      await tester.enterText(fields.at(2), 'wrong-pass');
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pump();
      expect(find.text('The passwords must match.'), findsOneWidget);
    },
  );
}
