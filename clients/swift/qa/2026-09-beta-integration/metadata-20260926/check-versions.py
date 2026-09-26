"""Compare actual old/current metadata code using only disposable SQLite files."""
import hashlib
from contextlib import closing
import io
import json
import pathlib
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile

repo = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
output = pathlib.Path(__file__).resolve().parent
cache = pathlib.Path.home() / "Library/Caches/maiD-QA/2026-09-26"
cache.mkdir(parents=True, exist_ok=True)
work = pathlib.Path(tempfile.mkdtemp(prefix="metadata-", dir=cache))
versions = {"old": "88d7d7e72fb3ea459b32245f8d37e6fd278496a1", "current": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()}
results = {"work": str(work), "versions": versions, "steps": [], "limitations": []}
sha = lambda data: hashlib.sha256(data).hexdigest()


def run(version, operation, database, name):
    completed = subprocess.run([str(work / version / "store-check"), operation, str(database)], capture_output=True, text=True, check=True)
    value = json.loads(completed.stdout)
    (output / (name + ".json")).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    results["steps"].append({"name": name, "version": versions[version], "operation": operation, "database": str(database), "exitCode": completed.returncode})
    return value


def inspect(database):
    with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as connection:
        assert connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
        assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
        return {"columns": [row[1] for row in connection.execute("PRAGMA table_info(threads)")], "imports": connection.execute("SELECT * FROM provider_session_imports").fetchall()}


def backup_database(source, destination):
    # A main-file copy can omit WAL data even after the writer exits when a
    # reader remains connected. Use SQLite's supported consistent snapshot.
    with closing(sqlite3.connect(f"file:{source}?mode=ro", uri=True)) as reader, closing(sqlite3.connect(destination)) as writer:
        reader.backup(writer)


try:
    for name, revision in versions.items():
        source = work / name
        source.mkdir()
        archive = subprocess.check_output(["git", "archive", revision, "go.mod", "go.sum", "internal/provider", "internal/store"], cwd=repo)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(source, filter="data")
        command = source / "cmd/store-check"
        command.mkdir(parents=True)
        shutil.copyfile(output / "store-check.go.txt", command / "main.go")
        build = subprocess.run(["go", "build", "-o", "store-check", "./cmd/store-check"], cwd=source, text=True, capture_output=True)
        (output / (name + "-build.log")).write_text(build.stdout + build.stderr)
        build.check_returncode()
        results[name + "BinarySHA256"] = sha((source / "store-check").read_bytes())

    original = work / "original.db"
    seeded = run("old", "seed", original, "01-old-seed")
    old_schema = inspect(original)
    assert "additional_directories" not in old_schema["columns"]
    original_hash = sha(original.read_bytes())
    upgraded = work / "upgrade.db"
    backup_database(original, upgraded)
    migrated = run("current", "read", upgraded, "02-upgrade")
    migrated_schema = inspect(upgraded)
    assert "additional_directories" in migrated_schema["columns"]
    assert migrated_schema["imports"] == old_schema["imports"]
    assert migrated["threads"][0].pop("AdditionalDirectories") is None
    assert migrated == seeded, "Migration changed original metadata"
    enriched = run("current", "enrich", upgraded, "03-current-new-fields")
    extra = ["/disposable/extra α", "/disposable/extra β"]
    thread_id = enriched["threads"][0]["ThreadID"]
    assert enriched["threads"][0]["AdditionalDirectories"] == extra
    assert enriched["routes"][thread_id]["StartInput"]["additionalDirectories"] == extra
    reopened = run("current", "read", upgraded, "04-current-reopen")
    assert reopened == enriched
    backup = work / "pre-downgrade.db"
    backup_database(upgraded, backup)
    backup_hash = sha(backup.read_bytes())
    run("old", "read", upgraded, "05-old-open-new-db")
    run("old", "rewrite-old", upgraded, "06-old-write-new-db")
    returned = run("current", "read", upgraded, "07-current-after-old-write")
    assert returned["threads"][0]["Title"] == "Renamed by older version"
    assert returned["threads"][0]["AdditionalDirectories"] == extra, "Old upsert erased an unknown SQL column"
    assert returned["routes"][thread_id]["StartInput"].get("additionalDirectories") is None
    results["limitations"].append("The pre-beta version discards unknown additionalDirectories in the JSON launch route when saving it. Do not promise lossless downgrade of new features; restore the backup when returning to the current build.")
    # Apart from the requested rename and that known JSON-field loss, all
    # durable records must remain byte-for-value equivalent.
    returned["threads"][0]["Title"] = enriched["threads"][0]["Title"]
    returned["routes"][thread_id]["StartInput"]["additionalDirectories"] = extra
    assert returned == enriched
    inspect(upgraded)
    recovered = work / "recovered.db"
    backup_database(backup, recovered)
    restored = run("current", "read", recovered, "08-backup-recovery")
    assert restored == enriched, "Backup recovery changed metadata"
    assert inspect(recovered)["imports"] == old_schema["imports"]
    assert sha(backup.read_bytes()) == backup_hash
    assert sha(original.read_bytes()) == original_hash, "Original old database was changed"
    results["checks"] = {"upgradePreservesOriginalValues": True, "migrationIdempotent": True, "oldBinaryCanReadAndWriteNewSchema": True, "unknownSQLColumnSurvivesOldUpsert": True, "olderRouteRewriteLosesNewJSONField": True, "backupRecoveryExact": True, "sqliteIntegrityAndForeignKeys": True, "originalAndBackupUntouched": True}
    results["databaseSHA256"] = {path.name: sha(path.read_bytes()) for path in [original, backup, recovered]}
    results["passed"] = True
except BaseException as error:
    results["failure"] = repr(error)
    raise
finally:
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
