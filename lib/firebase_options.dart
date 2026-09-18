// PLACEHOLDER — replaced wholesale by `flutterfire configure`, which writes
// the real per-platform options for the chosen Firebase project here.
//
// Until then the app boots with Firebase OFF: main() catches the error below
// and every cloud hook is a no-op.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform =>
      throw UnsupportedError('Firebase is not configured for this build');
}
