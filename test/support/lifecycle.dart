import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Use the engine channel so Flutter synthesizes legal intermediate states.
/// Render the inactive frame before pausing: paused applications do not draw.
Future<void> transitionLifecycle(
  WidgetTester tester,
  AppLifecycleState state,
) async {
  Future<void> send(AppLifecycleState next) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(next.toString()),
      (_) {},
    );
  }

  if (state == AppLifecycleState.paused &&
      tester.binding.lifecycleState == AppLifecycleState.resumed) {
    await send(AppLifecycleState.inactive);
    await tester.pump();
  }
  await send(state);
}
