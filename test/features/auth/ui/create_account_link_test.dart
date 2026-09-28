import 'package:boltmesh/core/env.dart';
import 'package:boltmesh/features/auth/ui/create_account_link.dart';
import 'package:boltmesh/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _url = 'https://boltmesh.mooo.com';

Future<void> pumpLink(
  WidgetTester tester, {
  String url = _url,
  WebsiteLauncher? launcher,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CreateAccountLink(url: url, launcher: launcher),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('isLaunchableWebUrl', () {
    test('accepts absolute http and https URLs', () {
      expect(isLaunchableWebUrl('https://boltmesh.mooo.com'), isTrue);
      expect(isLaunchableWebUrl('http://localhost:5173'), isTrue);
    });

    test('rejects empty, relative, and non-web schemes', () {
      // A stray define must not hand the platform a `file:` or app scheme.
      expect(isLaunchableWebUrl(''), isFalse);
      expect(isLaunchableWebUrl('   '), isFalse);
      expect(isLaunchableWebUrl('boltmesh.mooo.com'), isFalse);
      expect(isLaunchableWebUrl('file:///etc/passwd'), isFalse);
      expect(isLaunchableWebUrl('boltmesh://auth/callback'), isFalse);
      expect(isLaunchableWebUrl('javascript:alert(1)'), isFalse);
    });

    test('rejects a scheme with no host', () {
      expect(isLaunchableWebUrl('https:///register'), isFalse);
    });
  });

  testWidgets('shows the button and the URL, and launches on tap', (
    tester,
  ) async {
    final launched = <Uri>[];
    await pumpLink(
      tester,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
    );

    expect(find.text('Create account'), findsOneWidget);
    // The URL is printed so it survives a launch that does not open.
    expect(find.text(_url), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);

    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(launched, [Uri.parse(_url)]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('an unhandled launch is a hint, not a crash', (tester) async {
    await pumpLink(
      tester,
      launcher: (uri) async => throw MissingPluginException('no url_launcher'),
    );

    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('Visit the site below'),
      ),
      findsOneWidget,
    );
    // The URL is still on screen as the fallback.
    expect(find.text(_url), findsOneWidget);
  });

  testWidgets('a refused launch is a hint, not a crash', (tester) async {
    await pumpLink(tester, launcher: (uri) async => false);

    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('renders nothing when the site is not configured', (
    tester,
  ) async {
    // The hidden case is the plain `flutter run` default and every release
    // job that has not pinned WEBSITE_URL: no dead affordance.
    await pumpLink(tester, url: '');

    expect(find.byType(CreateAccountLink), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.text('Create account'), findsNothing);
  });

  testWidgets('renders nothing for a value that is not a web URL', (
    tester,
  ) async {
    // Defence in depth: the login screen reads the already-checked
    // Env.websiteUrl, so this only fires on a hand-built widget.
    await pumpLink(tester, url: 'file:///etc/passwd');

    expect(find.text('Create account'), findsNothing);
  });
}
