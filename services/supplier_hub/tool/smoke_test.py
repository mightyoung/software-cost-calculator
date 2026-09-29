"""Real-process A -> copied directory -> B test. Uses only disposable local data."""

import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def eventually(action, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = action()
            if result:
                return result
        except (OSError, urllib.error.URLError) as error:
            last = str(error)
        time.sleep(0.1)
    raise AssertionError(f"condition timed out: {last}")


def run(binary, quote_path):
    token = secrets.token_hex(32)
    env = {**os.environ, "HUB_API_TOKEN": token, "HUB_SYNC_KEY": secrets.token_hex(32)}
    source_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    target_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    payload = json.loads((Path(__file__).parent.parent / "examples/supplier.json").read_text())
    quote = json.loads(quote_path.read_text()) if quote_path else None
    processes = []
    logs = []
    # Use environment proxy settings for neither loopback endpoint.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(port, path, value=None):
        data = None if value is None else json.dumps(value, ensure_ascii=False).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with opener.open(req, timeout=3) as response:
            return json.load(response)

    with tempfile.TemporaryDirectory(prefix="supplier-hub-smoke-") as directory:
        root = Path(directory)
        (root / "inbox").mkdir()
        source_port, target_port = free_port(), free_port()

        def write_config(name, origin, port, role, enabled):
            path = root / f"{name}.toml"
            config = f'center_id = "{origin}"\nbind = "127.0.0.1:{port}"\ndatabase = "{name}.sqlite"\n[sync]\nenabled = {str(enabled).lower()}\nrole = "{role}"\ndirectory = "{"outbox" if role == "export" else "inbox"}"\ninterval_seconds = 1\nresend_seconds = 3600\nmax_files_per_tick = 50\n'
            if role == "import":
                config += f'trusted_origin = "{source_id}"\n'
            path.write_text(config)
            return path

        def start(config, port):
            log = open(root / f"process-{len(processes)}.log", "wb")
            logs.append(log)
            process = subprocess.Popen([str(binary), "serve", str(config)], env=env,
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            eventually(lambda: request(port, "/healthz"))
            return process

        def stop(process, abrupt=False):
            if process.poll() is None:
                process.kill() if abrupt else process.terminate()
                process.wait(timeout=10)

        def copy_packages():
            for item in (root / "outbox").glob("*.hubpkg"):
                shutil.copyfile(item, root / "inbox" / item.name)

        try:
            a_config = write_config("source", source_id, source_port, "export", False)
            b_config = write_config("target", target_id, target_port, "import", True)
            a = start(a_config, source_port)
            b = start(b_config, target_port)
            assert not request(source_port, "/v1/publications", payload)["duplicate"]
            assert request(source_port, "/v1/publications", payload)["duplicate"]
            request(target_port, "/v1/publications", payload)
            if quote:
                request(source_port, "/v1/publications", quote)
            assert not (root / "outbox").exists()

            # Commit survives an abrupt process exit; enabling exports the backlog.
            stop(a, abrupt=True)
            write_config("source", source_id, source_port, "export", True)
            a = start(a_config, source_port)
            source_count = 2 if quote else 1
            eventually(lambda: len(list((root / "outbox").glob("*.hubpkg"))) == source_count)
            first = next((root / "outbox").glob("*.hubpkg"))
            contents = first.read_bytes()
            (root / "inbox" / first.name).write_bytes(contents[:len(contents) // 2])
            eventually(lambda: '"failed":1' in request(target_port, "/v1/status")["store"]["tasks"].get("directory_exchange", ""))
            assert request(target_port, "/v1/status")["store"]["revision_count"] == 1
            copy_packages()
            expected = source_count + 1  # B's own publication is preserved.
            eventually(lambda: request(target_port, "/v1/status")["store"]["revision_count"] == expected)
            stop(b, abrupt=True)
            b = start(b_config, target_port)
            copy_packages()
            eventually(lambda: request(target_port, "/v1/status")["store"]["revision_count"] == expected)

            # Disabled generation accepts new published revisions; re-enable catches up.
            stop(a)
            write_config("source", source_id, source_port, "export", False)
            a = start(a_config, source_port)
            payload["revision"] = 2
            payload["records"][0]["data"]["name"] = "新版供应商"
            request(source_port, "/v1/publications", payload)
            assert len(list((root / "outbox").glob("*.hubpkg"))) == source_count
            stop(a)
            write_config("source", source_id, source_port, "export", True)
            a = start(a_config, source_port)
            eventually(lambda: len(list((root / "outbox").glob("*.hubpkg"))) == source_count + 1)
            copy_packages()
            path = f'/v1/publications/{source_id}/{payload["publication_id"]}'
            eventually(lambda: request(target_port, path)["revision"] == 2)
            assert request(target_port, f'/v1/publications/{target_id}/{payload["publication_id"]}')["revision"] == 1
            if quote:
                result = request(target_port, f'/v1/publications/{source_id}/{quote["publication_id"]}')
                row = next(r for r in result["records"] if r["entity_type"] == "quotation")
                assert row["data"]["price"] == "123456789012.123456"
                assert row["data"]["inquirer_name"] == "张三"
                assert len(result["records"]) == 4

            backup = root / "restore.sqlite"
            backup_env = {k: v for k, v in env.items() if k not in ("HUB_API_TOKEN", "HUB_SYNC_KEY")}
            subprocess.run([str(binary), "backup", str(a_config), str(backup)], env=backup_env,
                check=True, stdout=subprocess.DEVNULL, timeout=15)
            with sqlite3.connect(backup) as connection:
                assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            restored_port = free_port()
            restore_config = write_config("restore", source_id, restored_port, "export", False)
            restored = start(restore_config, restored_port)
            assert request(restored_port, path)["revision"] == 2
            stop(restored)
            print(json.dumps({"result": "passed", "two_process_directory_transfer": True,
                "partial_file_and_duplicate": True, "abrupt_restart": True,
                "disable_enable_backlog": True, "backup_restore": True,
                "dart_quote_contract": bool(quote)}, ensure_ascii=False))
        except Exception:
            # Process logs never include configured credentials or payload content.
            for log in logs:
                log.flush()
                print(Path(log.name).read_text(errors="replace")[-2000:])
            raise
        finally:
            for process in processes:
                stop(process)
            for log in logs:
                log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--quote-json", type=Path)
    args = parser.parse_args()
    run(args.binary.resolve(), args.quote_json)
