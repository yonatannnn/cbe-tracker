import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  // ProviderScope hosts the Riverpod providers introduced in later phases.
  runApp(const ProviderScope(child: CbeTrackerApp()));
}
