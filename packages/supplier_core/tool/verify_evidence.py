#!/usr/bin/env python3
"""Independent bounded SQLite oracle; never fetchall or load all revisions."""
import hashlib
import json
from pathlib import Path
import sqlite3
import sys


def verify(directory: Path) -> dict:
    report = json.loads((directory / "report.json").read_text())
    if report.get("status") != "PASS" or report.get("mode") != "query":
        raise ValueError("Expected successful query report")
    result = report["result"]
    connection = sqlite3.connect((directory / "query.sqlite").resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("PRAGMA temp_store=FILE")
        connection.execute("PRAGMA cache_size=-8192")
        count = 0
        digest = hashlib.sha256()
        for revision_id, canonical in connection.execute(
            "SELECT revision_id,canonical FROM revision ORDER BY revision_id"
        ):
            if hashlib.sha256(canonical.encode()).hexdigest() != revision_id:
                raise ValueError(f"Bad envelope hash at revision {count}")
            digest.update(f"{revision_id}\t{canonical}\n".encode())
            count += 1
        if count != result["revision_count"] or digest.hexdigest() != result["revision_sha256"]:
            raise ValueError("Revision count/digest mismatch")
        quotation_count = 0
        ids = hashlib.sha256()
        # Numeric canonical decimals are ordered using integer millionths, not
        # the production price_key expression. SQLite owns the external sort.
        for (entity_id,) in connection.execute("""
            SELECT entity_id FROM quotation_projection
            ORDER BY CAST(json_extract(payload,'$.price') AS INTEGER)*1000000 +
              CAST(substr(CASE WHEN instr(json_extract(payload,'$.price'),'.')=0
                THEN '' ELSE substr(json_extract(payload,'$.price'),
                instr(json_extract(payload,'$.price'),'.')+1) END || '000000',1,6) AS INTEGER),
              entity_id
        """):
            ids.update(f"{entity_id}\n".encode())
            quotation_count += 1
        if quotation_count != result["quotation_count"] or ids.hexdigest() != result["price_order_ids_sha256"]:
            raise ValueError("Independent exact-decimal ordering/count mismatch")
        expected_revisions = quotation_count * 5
        if count != expected_revisions:
            raise ValueError("Fixture distribution differs")
        failed_targets = [name for name, item in result["queries"].items() if not item["meets_target"]]
        return {"status": "PASS", "revision_count": count, "quotation_count": quotation_count,
                "revision_sha256": digest.hexdigest(), "price_order_ids_sha256": ids.hexdigest(),
                "oracle_retained_rows": 1, "sqlite_cache_kib": 8192,
                "query_targets_failed": failed_targets,
                "scope": "structural fixture integrity/order only; not import or target-platform acceptance"}
    finally:
        connection.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_evidence.py ARTIFACT_DIRECTORY")
    directory = Path(sys.argv[1])
    evidence = verify(directory)
    (directory / "oracle.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))
    if evidence["query_targets_failed"]:
        raise SystemExit(2)
