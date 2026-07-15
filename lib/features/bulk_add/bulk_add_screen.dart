/// Bulk upload flow + review modal (§8 Phase 5, FR-3).
library;

import 'package:flutter/material.dart';

/// Route target for the dashboard FAB's "Bulk upload" option.
/// The real multi-image flow arrives in Phase 5 (§FR-3).
class BulkAddPlaceholderScreen extends StatelessWidget {
  const BulkAddPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bulk upload')),
      body: const Center(child: Text('Bulk upload flow arrives in Phase 5')),
    );
  }
}
