import 'package:flutter/material.dart';

import 'core/state/orchestrator_controller.dart';
import 'features/dashboard/dashboard_page.dart';

class NimbleHitlApp extends StatefulWidget {
  const NimbleHitlApp({super.key});

  @override
  State<NimbleHitlApp> createState() => _NimbleHitlAppState();
}

class _NimbleHitlAppState extends State<NimbleHitlApp> {
  late final OrchestratorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = OrchestratorController.bootstrap();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NimBLE HITL',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: DashboardPage(controller: _controller),
    );
  }
}

