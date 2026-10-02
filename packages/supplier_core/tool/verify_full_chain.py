#!/usr/bin/env python3
"""Independent streaming SQLite/hash oracle for full_chain_scale.dart.

This checks the report against persisted authority, receipts and volume bytes.
Production bundle self-verification additionally parses all XML and projections.
Neither check proves platform activation or performance acceptance.
"""
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import zipfile


def database_digest(path: Path) -> dict:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("PRAGMA cache_size=-8192")
        connection.execute("PRAGMA temp_store=FILE")
        if connection.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            raise ValueError("SQLite integrity failure")
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise ValueError("SQLite foreign key failure")
        digest = hashlib.sha256()
        count = 0
        for revision_id, canonical in connection.execute(
            "SELECT revision_id,canonical FROM revision ORDER BY revision_id"
        ):
            if hashlib.sha256(canonical.encode()).hexdigest() != revision_id:
                raise ValueError("Invalid canonical revision hash")
            digest.update(f"{revision_id}\t{canonical}\n".encode())
            count += 1
        quotations = connection.execute("SELECT COUNT(*) FROM quotation_projection").fetchone()[0]
        receipt = connection.execute(
            "SELECT result_count FROM commit_receipt WHERE event_id='scale-confirmation'"
        ).fetchone()
        actual_results = connection.execute(
            "SELECT COUNT(*) FROM receipt_result WHERE event_id='scale-confirmation'"
        ).fetchone()[0]
        if receipt != (count,) or actual_results != count:
            raise ValueError("Formal fixture receipt differs from authority")
        return {"revision_count": count, "quotation_count": quotations,
                "authority_sha256": digest.hexdigest()}
    finally:
        connection.close()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def assert_standalone_sqlite(path: Path) -> None:
    for suffix in ("-wal", "-journal", "-shm"):
        if Path(f"{path}{suffix}").exists():
            raise ValueError(f"SQLite input has an active or leftover sidecar: {path}{suffix}")


def verify(directory: Path) -> dict:
    report = json.loads((directory / "report.json").read_text())
    kind = report.get("kind")
    if report.get("status") != "PASS" or kind not in {
        "formal-full-chain", "formal-full-chain-resumed", "formal-import-only"
    }:
        raise ValueError("Expected a successful formal full-chain report")
    if report["source_sha256"] != report["source_sha256_at_finish"]:
        raise ValueError("Source changed during run")
    result = report["result"]
    source_path = directory / "source.sqlite"
    if kind == "formal-full-chain-resumed":
        if not report.get("separate_process") or not report.get("missing_original_phase_timings"):
            raise ValueError("Resumed report must disclose its timing gap")
        if report["input_file_sha256"] != report["input_file_sha256_at_finish"]:
            raise ValueError("Resumed input files changed during run")
        source_path = Path(report["original_source_path"])
        backup_path = Path(report["original_backup_path"])
        if not source_path.is_absolute() or not backup_path.is_absolute():
            raise ValueError("Resumed input paths must be absolute")
        if (file_sha256(source_path) != report["input_file_sha256"]["source"] or
                file_sha256(backup_path) != report["input_file_sha256"]["backup"]):
            raise ValueError("Resumed input file hash differs")
    assert_standalone_sqlite(source_path)
    source = database_digest(source_path)
    if kind == "formal-import-only":
        assert_standalone_sqlite(source_path)
        if source["revision_count"] != report["count"] * 5:
            raise ValueError("Formal import cardinality differs")
        if any(result["source_digest"][key] != value for key, value in source.items()):
            raise ValueError("Formal import report digest differs from SQLite")
        return {"status": "PASS", "kind": kind, **source,
                "sqlite_cache_kib": 8192, "retained_sqlite_rows": 1,
                "scope": "Independent authority/receipt/SQLite integrity for formal import only"}
    assert_standalone_sqlite(directory / "restored.sqlite")
    if kind == "formal-full-chain-resumed" and source["authority_sha256"] != report["expected_authority_sha256"]:
        raise ValueError("Resumed source authority digest differs")
    restored = database_digest(directory / "restored.sqlite")
    assert_standalone_sqlite(source_path)
    assert_standalone_sqlite(directory / "restored.sqlite")
    if source != restored or source["revision_count"] != report["count"] * 5:
        raise ValueError("Restored authority or count differs")
    for key, value in source.items():
        for phase in ("source_digest", "restored_digest", "reopen_digest"):
            if result[phase][key] != value:
                raise ValueError(f"Report {phase}/{key} differs from SQLite")
    with zipfile.ZipFile(directory / "export.bundle.zip") as archive:
        if archive.getinfo("manifest.json").file_size > 1024 * 1024:
            raise ValueError("Manifest exceeds bounded budget")
        manifest = json.loads(archive.read("manifest.json"))
        if manifest != json.loads((directory / "manifest.json").read_text()):
            raise ValueError("External manifest differs from bundle")
        names = {"manifest.json"}
        revisions = quotations = 0
        for volume in manifest["volumes"]:
            name = volume["path"]
            names.add(name)
            digest = hashlib.sha256()
            size = 0
            with archive.open(name) as stream:
                while chunk := stream.read(65536):
                    digest.update(chunk)
                    size += len(chunk)
            if digest.hexdigest() != volume["sha256"] or size != volume["compressed_bytes"]:
                raise ValueError(f"Volume digest/size mismatch: {name}")
            if volume["kind"] == "revisions":
                revisions += volume["row_count"]
            elif volume["kind"] == "quotations":
                quotations += volume["row_count"]
        if set(archive.namelist()) != names or len(archive.namelist()) != len(names):
            raise ValueError("Unexpected or duplicate ZIP entries")
        if revisions != source["revision_count"] or quotations != source["quotation_count"]:
            raise ValueError("Volume cardinality differs from SQLite")
        if (manifest["revisions_digest"] != result["source_digest"]["bundle_revisions_sha256"] or
                manifest["business_digest"] != result["source_digest"]["business_sha256"]):
            raise ValueError("Bundle digest differs from frozen source")
    return {"status": "PASS", "kind": kind, **source, "volume_count": len(manifest["volumes"]),
            "sqlite_cache_kib": 8192, "retained_sqlite_rows": 1,
            "zip_chunk_bytes": 65536,
            "scope": "Independent authority/receipt/ZIP integrity; production self-verifier owns XML/projection validation"}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_full_chain.py ARTIFACT_DIRECTORY")
    directory = Path(sys.argv[1])
    oracle = directory / "oracle.json"
    oracle.unlink(missing_ok=True)
    evidence = verify(directory)
    oracle.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))
