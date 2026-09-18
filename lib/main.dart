import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'firebase_options.dart';
import 'services/service_providers.dart';
import 'services/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolved once here so everything downstream can treat the documents
  // directory as a plain value instead of a future.
  final docsDir = await getApplicationDocumentsDirectory();

  // Cloud backup is optional. With no project wired in at build time the whole
  // feature stays dormant; when there is one, initialise the client (which just
  // restores any saved session locally — no network) so sign-in survives
  // restarts. Guarded so a bad config can never stop the app from booting.
  if (SupabaseConfig.isConfigured) {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.key,
      );
    } on Object {
      // Cloud stays unavailable; the local app is unaffected.
    }
  }

  // The cloud mirror (Firestore). Only when `flutterfire configure` has
  // written real options; otherwise the app runs offline-only exactly as
  // before. Guarded so a bad config can never stop the app from booting.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on Object {
    // No cloud; every sync hook is a no-op.
  }

  runApp(
    ProviderScope(
      overrides: [appDocsDirProvider.overrideWithValue(docsDir)],
      child: const CbeTrackerApp(),
    ),
  );
}
