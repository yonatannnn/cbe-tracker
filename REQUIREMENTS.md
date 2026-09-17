# CBE Branch Expense Tracker — Requirements & Build Plan

Flutter app for a business owner managing ~5 branches. All transactions flow
through CBE (Commercial Bank of Ethiopia). She records transactions by
uploading CBE screenshots; the app reads them via OCR, assigns them to a
branch, maintains per-branch balances, and produces end-of-day reports per
branch. (SMS reading and reconciliation were removed in September 2026: the
app asks for no SMS permission and reads no messages.)

**Design principle: automation first.** The user never types transaction
data. She picks a branch, adds screenshots, and confirms. OCR fills
everything else. Manual editing exists only as a fallback for unreadable
images.

---

## 1. Functional requirements

### FR-0 User (whose books these are)
- First open asks for the user's name, with a single Continue button. Nothing
  else is reachable until a name is given.
- The name is the key the data is filed under: each user has her OWN
  database and screenshot folder (`profiles.json` at the documents root maps
  name → folder; the first user keeps the root so pre-profile data survives).
  Two users on one phone never see each other's branches, balances or images.
- Typing an existing name (case-insensitive) signs that user back in rather
  than creating a second set of books.
- Settings shows who is signed in, switches between users, and adds another.

### FR-1 Branch management
- CRUD for branches (name only; balance is derived, never typed).
- A branch with transactions cannot be deleted — only archived.
- After the name, onboarding creates the initial branches ("Hi <name>").
- A full branch management PAGE (not a sheet), reached from the dashboard's
  "Manage" link and from Settings: add, rename, remove/archive, and each
  branch's balance; tapping a branch opens it.

### FR-2 Single screenshot transaction
- User picks/pastes a CBE transaction screenshot.
- On-device OCR (Google ML Kit) extracts: amount (ETB), type
  (credited/debited), FT reference number, transaction date/time.
- Confirmation screen shows parsed values READ-ONLY (large amount, type
  badge, mono reference) + branch chip picker (2-column grid, most recently
  used branch pre-selected) + single Confirm button.
- "Edit manually" is a small link that expands editable fields — fallback
  only.
- If OCR cannot find BOTH an amount and a credited/debited keyword, the app
  refuses to guess: it shows a "couldn't read" state and asks to retake or
  enter manually. Never silently save uncertain numbers.
- Duplicate protection: FT reference is UNIQUE. Re-uploading a recorded
  screenshot shows "Already recorded on <date>" and blocks saving.
- Saving a credit adds to the branch balance; a debit deducts.

### FR-3 Bulk screenshot upload — THE MAIN FLOW
- Entry: from inside a branch, "Add screenshots". The branch is already
  chosen, so the flow opens on the image step. (The dashboard FAB's "Bulk
  upload" still asks for the branch first.)
- The batch has a DAY: defaults to today, changeable with a date picker (no
  future dates), shown as a chip so a non-today choice is obvious. Every
  approved row is dated on that day; the receipt's own time of day is kept
  for ordering, and the receipt's date is NOT used.
- Flow: (branch) → day → multi-select up to 50 images → sequential OCR with
  progress ("Processing 4 of 7…") → approval modal.
- The approval modal leads with the count: "5 of 7 read correctly · 1 already
  recorded · 1 unreadable", then the branch and the day.
- Above the button, a live sum of the CHECKED rows: IN (credits), OUT
  (debits) and NET, in integer cents. It follows the checkboxes.
- Review modal rows, three states:
  1. Parsed OK — checkbox (checked by default), amount + type badge +
     reference, read-only. Edit icon appears ONLY on low-confidence rows;
     tapping expands inline editable fields.
  2. Duplicate — greyed out, locked, "Already recorded on <date/time>".
  3. Failed OCR — thumbnail + "Couldn't read this image" + "Add manually"
     button.
- Primary button states the exact count: "Approve 5 transactions".
- All checked rows commit in ONE database transaction (atomic — a crash
  mid-save must never leave half-applied balances).

### FR-4 / FR-5 — removed
SMS reading, the shadow ledger and the Reconcile tab were removed. The app
requests no SMS permission. Screenshots are the only source of transactions.

### FR-6 Daily reports
- Reports tab: date picker (default today) → per-branch summary cards:
  opening balance, total credited, total debited, closing balance,
  transaction count, verification badge ("12/12 verified" = matched
- Export: PDF per branch AND a combined PDF, shareable via share sheet
  (Telegram/WhatsApp). PDF mirrors the on-screen cards + full transaction
  list per branch.
- Balances/reports are COMPUTED from the transactions table for the chosen
  date, never from a stored running number — any past day can be
  regenerated and audited.
- Optional: local notification at a configurable time (default 6 PM)
  reminding to generate the report.

  

### FR-7 Branch detail
- Balance summary card (current balance, in/out today).
- Day-grouped transaction list: screenshot thumbnail, signed amount,
  reference (mono), time, SMS-verification icon per row
  (check = verified, muted = screenshot-only).
- Row tap → full detail: original screenshot full-size, raw OCR text,
  edit / delete. Delete requires confirmation and recomputes balance.

### FR-8 Dashboard
- Total balance across branches + today delta.
- Warning banner when unmatched SMS exist today → deep links to Reconcile.
- Branch cards (name, today's transaction count, balance) → Branch detail.
- FAB "+" → bottom sheet: "Single screenshot" / "Bulk upload".

## 2. Non-functional requirements
- **Offline-first.** OCR (ML Kit) is on-device; DB is local SQLite.
  No network required for any core flow.
- **Android is the primary target** (SMS features). iOS builds and works
  minus SMS.
- Screenshot images stored in app documents dir; DB stores relative paths.
  Thumbnails rendered with `cacheWidth` to avoid list jank.
- All money math in integer cents (or `Decimal`), never double arithmetic
  for balances.
- Amharic/English: CBE messages are English; UI copy in English for MVP,
  strings externalized for later localization.
- No auth for MVP (single-user personal device). Optional app PIN later.

### LLM fallback (Gemini Flash)
- Triggered ONLY when local parse throws or returns LOW confidence, AND
  device is online. Input is OCR text, never the image.
- Structured JSON output; response validated by three gates: amount
  appears verbatim in raw text, type keyword present, reference matches
  FT format and appears in text. Any gate fails → couldn't-read state.
- AI-parsed results are marked, badged in UI, unchecked by default in
  bulk review, and NEVER auto-saved without user confirmation.
- 10s timeout; timeout/error degrades silently to couldn't-read state.
- API key: for MVP, --dart-define at build time (single-client app).

## 3. Data model (Drift / SQLite)

```
branches
  id            INTEGER PK
  name          TEXT NOT NULL
  archived      BOOLEAN DEFAULT false
  createdAt     DATETIME

transactions            -- from screenshots; the ONLY source of balances
  id            INTEGER PK
  branchId      INTEGER FK -> branches
  amountCents   INTEGER NOT NULL
  type          TEXT CHECK(type IN ('credit','debit'))
  reference     TEXT UNIQUE NOT NULL        -- FT number; duplicate guard
  screenshotPath TEXT
  ocrText       TEXT
  source        TEXT CHECK(source IN ('screenshot','sms','manual'))
  transactionDate DATETIME                  -- parsed from the message
  createdAt     DATETIME

sms_transactions        -- shadow ledger; NEVER affects balances
  id            INTEGER PK
  amountCents   INTEGER NOT NULL
  type          TEXT
  reference     TEXT UNIQUE
  smsBody       TEXT
  receivedAt    DATETIME
  matchedTransactionId INTEGER NULL FK -> transactions
  ignored       BOOLEAN DEFAULT false
```

Balance of a branch = SUM(credits) − SUM(debits) over its transactions.
Opening balance for date D = same sum with transactionDate < D.

## 4. Shared CBE parser

One pure-Dart module used by BOTH the OCR path and the SMS path:

```
ParsedCbeMessage parseCbeText(String raw)
  amount     : RegExp r'ETB\s*([\d,]+\.\d{2})'   (also tolerate 'Br')
  type       : contains 'credited' → credit, 'debited' → debit (case-insens.)
  reference  : RegExp r'FT\w{10,}'
  date       : parse 'on <date> at <time>' patterns; fallback = now
  confidence : LOW if reference missing/malformed or date fallback used
  → throw ParseException if amount OR type not found (never guess)
```

Ship with a fixture file of ~10 real anonymized CBE SMS/screenshot texts
and unit tests against them. This parser is the highest-risk component —
test it first and hardest.

## 5. Package list

| Purpose | Package |
|---|---|
| State | flutter_riverpod |
| DB | drift + drift_flutter (sqlite3) |
| OCR | google_mlkit_text_recognition |
| Images | image_picker (multi-select) |
| SMS (Android) | another_telephony |
| PDF | pdf + printing |
| Share | share_plus |
| Paths | path_provider |
| Notifications | flutter_local_notifications |
| Routing | go_router |
| Money | decimal (or int cents by hand) |

## 6. Architecture

```
lib/
  main.dart
  app/            router, theme, bottom nav shell (IndexedStack)
  core/
    parser/       cbe_parser.dart + fixtures + tests
    money/        cents helpers, ETB formatting
  data/
    db/           drift tables, database.dart, DAOs
    repositories/ branch_repo, transaction_repo, sms_repo
  services/
    ocr_service.dart          (ML Kit wrapper)
    sms_service.dart          (platform-gated; no-op on iOS)
    reconcile_service.dart    (matching logic)
    bulk_processor.dart       (Stream<BulkProgress>)
    report_service.dart       (aggregation queries)
    pdf_service.dart
  features/
    dashboard/  add_single/  bulk_add/  reconcile/
    branch_detail/  reports/  settings/  onboarding/
```

- Riverpod providers per repo/service; UI watches streams from Drift so
  balances update live.
- `sms_service` behind an abstract interface with an Android impl and a
  no-op impl — keeps iOS builds clean.

## 7. Screens (agreed designs)

1. Dashboard — total, SMS warning banner, branch cards, FAB.
2. Add single — image → read-only parsed summary card, branch chips
   (2-col grid), Confirm, small "Edit manually" link.
3. Bulk add — branch select → image grid (max 50) → progress bar.
4. Bulk review modal — DraggableScrollableSheet, three row states,
   "Save N transactions".
5. Reconcile — daily summary cards, unmatched SMS list with
   Add-to-branch / Ignore, collapsed ignored section.
6. Branch detail — balance card, day-grouped rows with thumbnails and
   verification icons; row detail page.
7. Reports — date picker, per-branch cards with verified badges,
   Per-branch PDF / Share all.
8. Sheets: add-method chooser, branch picker, ignore confirm, delete
   confirm, manage branches, SMS permission explainer.

## 8. Build plan — phases with acceptance criteria

Work strictly in this order; each phase compiles and its tests pass
before the next begins.

### Phase 0 — Project setup
- `flutter create`, add packages, set minSdk 23+, folder skeleton,
  go_router with 4-tab NavigationBar shell, light theme.
- ✅ App runs showing 4 empty tabs.

### Phase 1 — Core parser (TDD)
- Implement `cbe_parser.dart` + fixtures + unit tests: amounts with
  commas, credited/debited, FT refs, dates, ParseException cases,
  LOW-confidence flags.
- ✅ `flutter test` green; parser has zero Flutter imports (pure Dart).

### Phase 2 — Database layer
- Drift tables per §3, DAOs: insertTransactionIfNew (reference-unique),
  balanceStream(branchId), dailySummary(branchId, date),
  unmatchedSmsForDay(date), link/ignore SMS ops.
- Unit tests with in-memory sqlite: duplicate rejection, balance math,
  opening/closing computation.
- ✅ Tests green.

### Phase 3 — Branches + Dashboard
- Onboarding to create branches; manage-branches sheet (archive rule).
- Dashboard with live balance streams; FAB + method chooser sheet.
- ✅ Create 3 branches, see cards with 0.00 balances.

### Phase 4 — Single add flow
- image_picker → ocr_service → parser → read-only confirm screen
  (branch chips, most-recent pre-selected) → save → balance updates.
- Duplicate and couldn't-read states. Manual-edit expansion.
- ✅ Real CBE screenshot end-to-end updates the right branch.

### Phase 5 — Bulk flow
- bulk_processor (sequential, Stream progress), review modal with three
  row states, atomic multi-save.
- ✅ 10 images incl. one duplicate and one unreadable → 8 saved, correct
  modal states, balance correct, dupes never double-count.

### Phase 6 — SMS + reconciliation (Android)
- Permission explainer, inbox sync, background listener,
  reconcile_service matching (reference → amount/type/day fallback,
  ambiguous stays unmatched), Reconcile tab UI with Add/Ignore.
- Dashboard warning banner wired.
- ✅ Send self a CBE-format SMS: appears in reconcile; screenshot of the
  same transaction auto-matches and removes it.

### Phase 7 — Branch detail + transaction detail
- Day-grouped list, thumbnails (cacheWidth), verification icons,
  detail page with full screenshot + OCR text, edit/delete with
  balance recompute.
- ✅ Delete a transaction → dashboard balance updates instantly.

### Phase 8 — Reports + PDF
- report_service daily aggregation, Reports tab cards with verified
  badges, pdf_service (per-branch + combined), share_plus, 6 PM
  reminder notification.
- ✅ Yesterday's PDF regenerates identically; totals match branch detail.

### Phase 9 — Polish & hardening
- Empty states everywhere, iOS graceful degradation, error toasts,
  DB export/backup (share the .sqlite + images zip), app icon,
  widget tests for confirm screen and review modal.
- ✅ Full manual test script passes on a physical Android device.

## 9. Test checklist (regression script)
- [ ] Same screenshot twice → blocked with date shown
- [ ] Blurry image → couldn't-read state, nothing saved
- [ ] Bulk with mixed states → exact count on save button, atomic commit
- [ ] SMS arrives while app closed → visible in reconcile on next open
- [ ] Ignore SMS → gone today AND absent from that day forever
- [ ] Fallback match with two same-amount candidates → stays unmatched
- [ ] Report for a past date == report generated on that date
- [ ] Balance always equals sum of visible transactions (audit)
- [ ] iOS build: no SMS UI, everything else functional
