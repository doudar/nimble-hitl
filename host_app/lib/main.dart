import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(),
      () async {
        await windowManager.setFullScreen(false);
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const NimbleHitlApp());
}

