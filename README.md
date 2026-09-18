# CBE Tracker

Per-branch totals from the payment screenshots customers send. Built for an
accountant keeping the books for ~5 branches: customers pay into a branch's
Commercial Bank of Ethiopia account, from CBE or any other bank or wallet, and
send her the screenshot. She drops the day's screenshots into the branch; the
app reads each one, catches repeats, shows the sum, files them on approval, and
produces end-of-day PDF reports. It reads no SMS and asks for no SMS
permission.

Money is integer cents everywhere. The CBE parser is pure Dart. The source of
truth for behaviour is `REQUIREMENTS.md`.

## Build

```sh
flutter analyze          # must be clean
flutter test             # must pass
flutter build apk --release
```

The plain build is fully local — no keys, no network, nothing leaves the phone
except what the owner shares herself.

### Optional build-time configuration (--dart-define)

| Define | Enables |
|---|---|
| `SUPABASE_URL` + `SUPABASE_KEY` | Daily cloud backup to the owner's Supabase project (Settings → Cloud backup). Setup: `docs/SUPABASE_SETUP.md`. |
| `GEMINI_API_KEY` | AI fallback for receipts the local parser can't read. Off by default; the local parser + manual entry cover normal use. Note: the key is embedded in the APK. |

```sh
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_KEY=YOUR-PUBLISHABLE-KEY
```

### Enable Gemini extraction fallback

Copy `secrets.example.json` to `secrets.json` (gitignored), then replace
`paste-your-key-here` with your Gemini API key from
[Google AI Studio](https://aistudio.google.com/apikey).

```sh
flutter run --dart-define-from-file=secrets.json
# Or build an installable APK:
flutter build apk --release --dart-define-from-file=secrets.json
```

Rebuild after changing the key; hot reload cannot update build-time values.
The key is embedded in the app, so this setup is intended for the personal
single-client build.

The local parser knows her CBE SMS plus the CBE app and USSD confirmations
and the receipts customers send from telebirr, Awash, Bank of Abyssinia,
Dashen and Zemen (REQUIREMENTS.md §4a). Every receipt is a customer's
payment in; the app has no money-out side.

Both single and bulk screenshot uploads try the local regex parser first.
Only a failed or low-confidence parse goes to Gemini, and that request
carries the OCR text AND the picture itself — a photo of a phone screen, or a
receipt from another bank (Awash, Telebirr, …), is exactly what OCR text alone
cannot carry. The fallback requests structured JSON. A CBE receipt is still
validated against the text (amount beside its credit/debit wording, no balance
figures, a real FT reference); another bank's receipt must show an amount the
OCR also read, and gets a reference derived from bank + time + amount so a
re-upload is caught as a duplicate. Accepted results are marked AI-parsed:
bulk AI rows start unchecked and require review. Missing keys, network errors,
invalid responses, and the 45-second timeout lead to manual entry.

### Release signing

`android/app/build.gradle.kts` still signs release builds with the debug key
(fine for sideloading on the owner's phone). Create a keystore and a
`key.properties` before distributing more widely.

## Device workflow

- Install preserving data: `adb install -r <apk>` — **never** `flutter install`,
  which uninstalls first and wipes the app's data.
- Manual regression script: `docs/MANUAL_TEST.md`. Run it on a real phone
  before calling a build done — this project has repeatedly caught things on
  device that 270 green tests missed.

## Layout

```
lib/core/parser/     CBE receipt parser (pure Dart, no Flutter imports)
lib/core/money/      integer-cents formatting
lib/data/db/         Drift schema, DAOs, providers
lib/services/        OCR, parse pipeline, bulk processor, backup (local+cloud),
                     PDF, notifications
lib/features/        one folder per screen/flow
docs/                Supabase setup, manual test script
```
