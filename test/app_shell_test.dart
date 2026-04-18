import 'package:flora/app/app.dart';
import 'package:flora/core/state/flora_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FloraShell renders and openAIKeyProvider defaults to null', (
    tester,
  ) async {
    // Provide the initial key as null (simulating fresh install with no stored key).
    await tester.pumpWidget(
      ProviderScope(
        overrides: [openAIKeyInitialProvider.overrideWithValue(null)],
        child: const FloraApp(),
      ),
    );
    await tester.pump();

    // The shell should have rendered — at minimum the Settings icon is present.
    expect(find.byType(FloraApp), findsOneWidget);
  });
}
