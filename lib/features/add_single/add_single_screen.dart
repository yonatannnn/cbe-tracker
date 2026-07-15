import 'package:flutter/material.dart';

/// Add tab (§8 Phase 4, FR-2). Placeholder for Phase 0.
class AddScreen extends StatelessWidget {
  const AddScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add')),
      body: const Center(child: Text('Add')),
    );
  }
}

/// Route target for the dashboard FAB's "Single screenshot" option.
/// The real OCR → confirm flow arrives in Phase 4 (§FR-2).
class AddSinglePlaceholderScreen extends StatelessWidget {
  const AddSinglePlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Single screenshot')),
      body: const Center(child: Text('Single screenshot flow arrives in Phase 4')),
    );
  }
}
