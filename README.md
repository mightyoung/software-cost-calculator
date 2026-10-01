# Folio

Named for a collection of document pages, Folio carries the app's folded-page identity.

A supplier inquiry and project cost tool. Each device runs on its own and stores its data locally; there is no server. It targets Windows (primary), Android and macOS.

- **Projects and cost budgets:** budgets are grouped into five cost categories (materials, outsourcing, labour, manufacturing overhead, other). The lowest valid quotation is filled in automatically, markup and margin are calculated, and the app warns when cost reaches the contract amount or a cheaper quotation appears.
- **Quotations:** record quotations one by one or import them from an Excel template. Comparison converts tax mode when a rate is known and converts units using each product's configured factors; the original quotation remains unchanged. It explains when a quotation cannot be compared. The quotation page highlights offers expiring within 30 days and materials without a new quotation for over 90 days.
- **Excel:** exports a project quote sheet (for the customer), a cost budget sheet (internal) and an inquiry list (for suppliers). Amounts stay exact to 6 decimal places.
- **Exchange between devices:** exporting produces an exchange file (`.siq`); importing it merges data on another device. Changes are merged field by field, and conflicting edits are shown for review. Re-importing the same file changes nothing. For a full rollback, the separate restore action replaces the local library after two confirmations and saves a recovery copy first.
- **Upgrades:** an older local database gets a checked `.pre-vN-migration.siq` snapshot beside the database before its schema is changed.
- **AI (DeepSeek or any OpenAI-compatible service):**
  - **Build a project from a list:** matches the list against the local material catalogue; nothing is written until the user confirms.
  - **Smart quote import:** paste supplier information (chat, email, a quote sheet or an Excel file) and the app pulls out suppliers, contacts, products (brand, model, technical specs) and prices. It matches them to existing suppliers and materials, then after review writes them into an existing or new project in one go, optionally adding them to the budget. Only the pasted text is sent to the AI.
  - **Assistant:** queries local data and optionally researches public product and price sources. New answers display host-verified tool facts; unsupported fields stay unknown. Source-bound candidates are reviewed before catalogue import, and web prices remain reference prices. Existing-project price checks require matching identity and commercial terms; alternative products require a new formal quote and review in the budget workflow. Other app record changes require confirmation; read-only mode and outbound web-request review are available.
  - The API key is kept only in the operating system's secure storage.

## Layout

| Path | Contents |
|---|---|
| `packages/supplier_core` | Pure Dart core: validation, storage (SQLite), exchange, budgets, Excel, AI |
| `apps/supplier_app` | Flutter app |
| `docs/reviews/` | Critical review and improvement plan (decision history) |
| `docs/design/` | UI spec and HTML prototype; design context in `.impeccable.md` |

The [device validation checklist](docs/reviews/v2-device-validation-checklist.md) covers installation, Excel/WPS, exchange, restart and full restore.

## Exchange security

LAN sending now requires a shared exchange passphrase. Configure the same passphrase on the receiving device. Discovery names and addresses remain unverified; the passphrase protects the payload but does not identify individual devices. Manual file import still accepts legacy plaintext snapshots. When folder sync has a passphrase, it refuses plaintext files instead of silently downgrading protection. Secure-storage failures stop outbound operations; manual encrypted recovery can use a password entered for that operation.

Memory-based file picking is limited to 20 MiB and exchange-file copying to 2 GiB. Encrypted exchange files have a separate 128 MiB envelope limit because SIQE1 encryption uses whole-message buffers; larger libraries need smaller selected exports. This also limits importing existing encrypted backups above 128 MiB. XLSX input additionally allows at most 2,048 ZIP members, 100 MiB expanded content, 200,000 logical rows and 2,000,000 materialized cells across sheets. Unusually sparse spreadsheets may need to be split or have distant unused rows removed. LAN transport retains its 300 MiB file limit, with bounded concurrent uploads and a 15-minute absolute deadline; encrypted GUI sends also obey the 128 MiB limit.

The [security retrofit record](docs/reviews/2026-09-29-security-retrofit.md) records findings, compatibility changes, tests and remaining validation boundaries.

## Development

```bash
cd packages/supplier_core && dart test
cd apps/supplier_app && flutter test
```

On macOS, `flutter test test/screenshot_test.dart --update-goldens` renders key screens with a real CJK font into `apps/supplier_app/test/screens/` for visual checks.

## Builds

GitHub Actions (`.github/workflows/build.yml`) runs the tests first, then builds:
- a Windows zip;
- an Android APK;
- a macOS app.

Download them from the Artifacts section of the run page. The packages are not code-signed, so the system will warn the first time you open one.

The old revision-graph implementation is archived on the `codex/supplier-implementation` branch.
