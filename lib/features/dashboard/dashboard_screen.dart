import 'package:flutter/material.dart';

/// Home tab (§8 Phase 8 → Dashboard, FR-8). Placeholder for Phase 0.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: const Center(child: Text('Home')),
    );
  }
}
