# 询价台账

A supplier inquiry and project cost tool. Each device runs on its own and stores its data locally; there is no server. It targets Windows (primary), Android and macOS.

- **Projects and cost budgets:** budgets are grouped into five cost categories (materials, outsourcing, labour, manufacturing overhead, other). The lowest valid quotation is filled in automatically, markup and margin are calculated, and the app warns when cost reaches the contract amount or a cheaper quotation appears.
- **Quotations:** record quotations one by one or import them from an Excel template. Quotations are compared by currency, tax mode and unit, and the reason is shown whenever a quotation doesn't count.
- **Excel:** exports a project quote sheet (for the customer), a cost budget sheet (internal) and an inquiry list (for suppliers). Amounts stay exact to 6 decimal places.
- **Exchange between devices:** exporting produces an exchange file (`.siq`); importing it merges data on another device. Merging keeps the newer version of each record, so the order of imports doesn't matter and importing the same file twice changes nothing. The same file also works as a backup.
- **AI (DeepSeek or any OpenAI-compatible service):**
  - **Build a project from a list:** matches the list against the local material catalogue; nothing is written until the user confirms.
  - **Ask your data:** answers questions using read-only queries.
  - The API key is kept only in the operating system's secure storage.

## Layout

| Path | Contents |
|---|---|
| `packages/supplier_core` | Pure Dart core: validation, storage (SQLite), exchange, budgets, Excel, AI |
| `apps/supplier_app` | Flutter app |
| `docs/reviews/` | Critical review and improvement plan (decision history) |
| `docs/design/` | UI spec and HTML prototype; design context in `.impeccable.md` |

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
