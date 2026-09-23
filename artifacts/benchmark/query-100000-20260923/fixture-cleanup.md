# Query fixture cleanup

After the 2026-09-23 query report and independent oracle both recorded PASS,
`query.sqlite` (1,965,375,488 bytes) was removed to reserve disk for the
formal full-chain benchmark. The JSON reports and run logs remain. Re-running
the oracle requires regenerating the fixed-seed query fixture in a new output
directory; the retained oracle is evidence of the completed verification, not
a live check against a currently present database.

The generated `apps/supplier_app/build/` directory (about 1.1 GiB) was also
removed after the logged Web release build had succeeded. It can be recreated
with `flutter build web`; no source or validation log was removed.
The app's generated `.dart_tool/` cache (about 363 MiB) was likewise removed;
`flutter pub get` regenerates it when app checks resume.
