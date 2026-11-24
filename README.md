# MoneyMate

A polished, **offline-first** personal expense tracker built with Flutter.
Everything works without a connection: the app reads and writes a local
SQLite database, and transactions are synchronised with **Cloud Firestore**
(under the user's own Firebase account) whenever the device is online.

## Features

| Area | What it does |
| --- | --- |
| **Dashboard** | Total balance, monthly income/expenses, weekly & monthly spending summaries with change vs. the previous period, a daily bar chart for the week, weekly/monthly budget progress, a category donut chart and recent transactions. Everything refreshes automatically after any add/edit/delete. |
| **Transactions** | Add, edit and delete income or expenses (amount, category, date, notes, payment method). Validation, confirmation before deleting, undo, swipe-to-delete. History is grouped by day, newest first, with debounced search and filters by type, date range and category. |
| **Budget** | Independent **weekly** (Monday–Sunday by default) and **monthly** (calendar month) targets: spent, remaining, % used, progress bar, safe-to-spend per day and spending history. Category budgets (weekly or monthly), e.g. *Food AED 500 / month*. |
| **Alerts** | In-app alerts at **80 %**, **90 %** and **100 %** of a target. Each threshold fires once per period (the state is persisted, so it survives app restarts). |
| **Reports** | Daily, weekly and monthly expense charts, income vs. expense, category pie chart, highest-spending categories, total savings and savings rate, and a comparison with the previous month. Date range presets or a custom range. |
| **Households** | Partners each sign in with their own account, keep **private personal finances** and share a **household**: shared transactions (with who added them), shared weekly/monthly and category budgets, synced to every member's devices. Create a household, invite with a one-time code (optionally bound to an email, expires after 7 days), accept, remove members, transfer ownership, leave or delete. |
| **Personal / Shared / Combined** | One app-wide switch for the dashboard, transaction list and reports. Combined totals count every transaction exactly once. |
| **Cloud sync** | Two-way sync of transactions, budgets and categories with Firestore, automatic whenever connectivity is available, with a visible status (Synced, Syncing, Offline, Pending, Failed) and the last successful sync time. The device keeps the latest **90 days** of transactions; the cloud keeps the complete history, which history and reports load on request. |
| **Settings** | Currency, light/dark/system theme, first day of the week, notification toggles, custom categories, JSON backup/restore, CSV export and app information. |

## Tech stack

Flutter · Dart 3 (null safety) · **Provider** (`ChangeNotifier`, `MultiProvider`,
`ChangeNotifierProxyProvider`) · **sqflite** (plus `sqflite_common_ffi` on
Windows/Linux) · Firebase Auth · **Cloud Firestore** · **Cloud Functions**
(Node.js, household and invitation management) · connectivity_plus ·
SharedPreferences · fl_chart · intl · uuid · file_picker · share_plus ·
path_provider.

## Architecture

```
lib/
  app/                 Composition root: DI (AppDependencies), MultiProvider, HomeShell
  core/
    constants/         App constants, currencies, category icons/colours
    database/          AppDatabase: schema, indexes, versioned migrations, seeding
    services/          BudgetCalculator, TransactionCalculator (pure logic),
                       BackupService (JSON/CSV), FileService (save/share/pick)
    theme/             Light/dark themes and FinanceColors theme extension
    utils/             Money (minor-unit parsing/formatting), DateRange/PeriodUtils
  models/              Transaction, Category, Budget, report models
  repositories/        Abstract interfaces plus SQLite implementations
  providers/           Settings, Category, Transaction, Dashboard, Budget, Report
  features/<feature>/  screens/ and widgets/ for dashboard, transactions,
                       budget, reports and settings
  shared/widgets/      Reusable cards, charts, dialogs, tiles and state views
```

* **Data flow:** UI → Provider → Repository → SQLite. Widgets hold no business
  logic. Calculations live in pure, unit-tested calculator classes.
* **Automatic refresh:** `TransactionProvider.dataVersion` goes up on every
  write. The Dashboard, Budget and Report providers are proxy providers that
  reload only when that version, the categories or the first day of the week
  change. Stale async results are dropped with load tokens.
* **Money:** every amount is stored as an `INTEGER` in minor units (fils or
  cents). User input is parsed with exact string arithmetic, never doubles.
* **Budget history is never lost:** each target change inserts a version row
  (`effective_from` = start of the current period). A past period uses the
  version that applied to it, and an expense always counts toward both its
  own week and its own month, including past-dated entries.

### Database

| Table | Purpose |
| --- | --- |
| `transactions` | Amount (`CHECK > 0`), type, date, note, payment method. FK to `categories` (`ON DELETE RESTRICT`). Indexes on `date`, `(type, date)` and `(category_id, date)`. |
| `categories` | Built-in and custom categories, `UNIQUE(name, type)`. |
| `budgets` | Versioned weekly/monthly targets, `UNIQUE(period, effective_from)`. |
| `category_budgets` | FK to `categories` (`ON DELETE CASCADE`), `UNIQUE(category_id, period)`. |
| `app_settings` | Key/value data that belongs with the database (e.g. alert state, sync cursor). |
| `sync_tombstones` | Local deletions waiting to be marked deleted in the cloud. |

Schema v2 adds `sync_status` (`pending`/`synced`/`failed`), `cloud_updated_at`,
`synced_at` and `sync_error` to `transactions`. Existing rows start as
`pending`, so they are uploaded and verified before any clean-up.

Migrations are applied step by step from `AppDatabase._migrations`, so user data
survives app updates.

### Personal and shared data

Every synced record belongs to exactly one **data scope**: the user's personal
data or one household's shared data. Scopes never mix, locally or in the cloud.

```
users/{uid}/transactions/{id}            personal transactions (owner only)
users/{uid}/personalBudgets/{id}         personal budgets
users/{uid}/personalCategories/{id}      personal custom categories
users/{uid}/memberships/{householdId}    written by Cloud Functions only
households/{householdId}                 name, owner (Cloud Functions only)
households/{householdId}/members/{uid}   role + status (Cloud Functions only)
households/{householdId}/invitations/{id}  owner-readable, Cloud Functions only
households/{householdId}/transactions/{id} shared transactions (active members)
households/{householdId}/budgets/{id}    shared budgets (active members)
households/{householdId}/categories/{id} labels used by shared records
households/{householdId}/settings/{id}   members read, owner writes
invitationCodes/{code}                   server-only code lookup
```

Transaction documents carry `id`, `scope`, `ownerUid` (personal) or
`householdId` (shared), `createdBy`, `createdByName`, `updatedBy`,
`amountMinor` (integer minor units), `type`, `categoryId`, `date` (the
transaction date), `note`, `paymentMethod`, `createdAt`, `updatedAt`,
`deleted` / `deletedAt` and a server timestamp `serverUpdatedAt`. Field names
from the original release are kept so existing cloud history stays readable.

* **Security rules** (`firestore.rules`) check the member document on every
  household read and write, require `createdBy` to be the caller on create
  and unchanged on update, and give clients no write access to households,
  members, memberships or invitations. All membership changes go through the
  callable functions in `functions/` (create, rename, invite, preview,
  accept, revoke, remove member, leave, transfer ownership, delete).
* **Invitations** are random 10-character one-time codes, valid 1–30 days
  (7 by default), optionally bound to an email, accepted inside a Firestore
  transaction (so a code can never be used twice) and listed as pending,
  accepted, expired or revoked.
* **Access loss** (removed, left, household deleted) is acted on only after
  the server confirms it. The household's cached data is then removed from
  the device; shared records the user created that never reached the cloud
  are kept as personal ones. Personal data and the household's cloud history
  are never touched.
* **Existing data** is migrated as personal (schema v3); nothing is shared
  unless the user moves a transaction into the household explicitly.

### Cloud sync and 90-day local retention

SQLite stays the source of truth for the UI; Firestore holds the complete
history (see `firestore.rules`). Each scope is synchronised separately in one
cycle, with its own cursor, verification and clean-up.

| Piece | Role |
| --- | --- |
| `TransactionSyncService` | One cycle: push → verify → pull → clean-up. |
| `SqliteLocalSyncStore` | Sync state in SQLite; every row removal is guarded. |
| `FirestoreTransactionStore` | Server-only reads (Firestore's cache is off), batched writes. |
| `SyncConflictResolver` | Last-writer-wins by `updatedAt`; exact ties go to the cloud. |
| `SyncProvider` | Runs sync on sign-in, reconnect, local edits (debounced), resume and every 15 min. |
| `CloudHistoryLoader` | Loads cloud-only history for the Transactions screen, reports and budget history. |
| `SqliteSettingsSyncStore` | Budget and category sync: last writer wins, deletions as tombstones. |
| `HouseholdProvider` | Membership, members, invitations, offline cache, confirmed access loss. |

* **Stable IDs and timestamps:** transactions keep their UUID everywhere, and
  every edit, deletion or undo bumps `updatedAt`, which drives conflict
  resolution in both directions.
* **Deletions are soft in the cloud:** deleting in the app writes a local
  tombstone, then marks the cloud document `deleted: true`. The app never
  deletes cloud documents (the rules forbid it).
* **Verified before marked synced:** after each upload batch the documents are
  re-read from the server; only rows whose cloud copy matches exactly become
  `synced`, others become `failed` and are retried.
* **Retention clean-up** removes local transactions dated before *today − 90
  days* only when:
  1. no transaction or deletion of that scope (personal, or the household)
     is pending or failed, so every existing record has been migrated first;
  2. the row is `synced` and its `cloud_updated_at` equals `updated_at`;
  3. a fresh server read of that row matches it field by field; and
  4. the row is unchanged at the moment of deletion (conditional `DELETE`).
  Rows that fail check 3 are queued for upload again instead. Budgets,
  categories and settings are never touched, and no table is ever cleared.
  The amount and type of each removed row are kept in `archived_totals`, so
  all-time balances stay correct.
* **Historical reports:** report ranges and budget history that reach past
  the window add the cloud-only transactions (when online) without counting
  anything twice.
* **History without duplicates:** older transactions are read from Firestore
  on request (or automatically when a date filter reaches past the window)
  and shown next to local ones. IDs stored or deleted locally are excluded.
  Editing a cloud-only record stores the new version locally for upload.
* **Configurable retention:** the default is exactly 90 days
  (`AppConstants.defaultLocalRetentionDays`). The value can be overridden
  with the `sync.retention_days` app setting (minimum 30).
* **One account per device:** the first account to sync owns the local data;
  if another account signs in, sync pauses instead of mixing data.

### Backup and restore

* A backup is a versioned JSON document (`app`, `schemaVersion`, `data`).
* Before restoring, the file is fully validated: structure, version, types,
  positive amounts, category references and duplicate IDs. The user then sees
  what the file contains and must confirm.
* Before anything is replaced, a safety copy of the current data is written to
  the app's private documents folder. The restore runs in a **single SQLite
  transaction**, so a failure leaves existing data untouched.
* CSV export follows RFC 4180 quoting and guards against spreadsheet formula
  injection.

## Running

```bash
flutter pub get
flutter run                 # Android, iOS, macOS, Windows or Linux
flutter build apk --release
```

Households need the Cloud Functions and rules deployed (Blaze plan):

```bash
cd functions && npm install && cd ..
firebase deploy --only firestore:rules,functions
```

## Tests

```bash
flutter analyze
flutter test
cd functions && npm test   # Cloud Functions + security rules (Firestore emulator, Java 21+)
```

The Dart tests cover:

* `test/unit`: budget formulas, alert thresholds, target versioning, money
  parsing and formatting, week/month period maths, transaction aggregation.
* `test/database`: the real SQLite schema (in memory through FFI): constraints,
  filters and search, aggregation, past-dated entries, category deletion,
  budget versions, backup round trip and validation, CSV escaping.
* `test/providers`: BudgetProvider: independent targets, income excluded,
  historical targets, alerts firing once, category budgets. SyncProvider
  triggers and offline handling; merged cloud history in TransactionProvider.
* `test/sync`: the sync engine on real SQLite with an in-memory Firestore
  stand-in: 90-day boundary, verification failures, nothing removed while
  offline or with unsynced data, conflicts in both directions, soft deletes,
  undo, account isolation and cloud history paging.
* `test/database/migration_test.dart`: v1 → v2 and v2 → v3 upgrades keep
  every row; existing data becomes personal and is queued for the cloud.
* `test/sync/household_sync_test.dart`: personal/shared isolation, partner
  changes, soft deletes, moving a transaction into the household, refused
  access, releasing a household, 90-day retention per scope, shared budgets.
* `test/providers/household_provider_test.dart`: create/join/leave, cached
  membership, access loss only when confirmed, scope rules for transactions.
* `functions/test`: invitation code generation and validation, the household
  functions against the Firestore emulator (one-time and expiring codes,
  email binding, owner-only actions, duplicate membership, removal, transfer,
  deletion) and `firestore.rules` against the documents the app writes.
* `test/widget`: full app flows with in-memory repositories: dashboard,
  add-transaction validation, search and delete, setting a budget target,
  reports and settings.

> **Note for Windows:** `flutter test` (Flutter 3.35) fails to compile tests
> when the project path contains an apostrophe (for example `C:\Users\Arun's
> Desktop\…`). This is a Flutter tooling bug, not a project issue. You can map
> a drive letter and run the tests from it:
>
> ```powershell
> subst M: "C:\path\with'apostrophe\money_mate"
> cd M:\ ; flutter test
> subst M: /d
> ```
