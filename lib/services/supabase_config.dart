/// Points the app at the owner's Supabase project (Phase 10 — cloud backup).
///
/// The URL and publishable key are supplied at build time via --dart-define.
/// Both are safe to embed: the publishable (a.k.a. anon) key is public by
/// design, and every backup is gated behind email/password sign-in plus
/// per-user Storage rules, so the key on its own opens nothing. An empty config
/// — a build with no --dart-define — leaves the whole cloud feature dormant and
/// hidden, so the app runs exactly as before for anyone who hasn't set up a
/// project.
library;

class SupabaseConfig {
  const SupabaseConfig._();

  static const String url = String.fromEnvironment('SUPABASE_URL');

  /// The project's public client key. Supabase labels this "publishable key" on
  /// newer projects and "anon public" on older ones — either string works.
  static const String key = String.fromEnvironment('SUPABASE_KEY');

  /// Whether a project was wired in at build time. Everything cloud-related
  /// checks this first and stays inert when it's false.
  static bool get isConfigured => url.isNotEmpty && key.isNotEmpty;
}
