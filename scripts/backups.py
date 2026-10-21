#!/usr/bin/env python3
"""Backups that are proven, not assumed.

    scripts/backups.py verify       [--app A] [--env E] [--report r.json] [--summary s.md] [--no-restore]
    scripts/backups.py sync-buckets [--app A] [--env E]

The inventory of each environment comes from its state
(terraform_data.backup_inventory in apps/<app>/<env>.tfstate): databases and
volumes that Dokploy backs up, buckets that sync-buckets copies.

verify, for each of them:
  - freshness: the newest object is younger than its schedule allows
    (26 h for a daily cron, 8 days otherwise);
  - database: the newest dump is restored into a throw-away container of the
    same image, then a query must return a number above 0 (default: the number
    of user tables; databases.<k>.verify.query in the manifest);
  - volume: the newest archive lists at least one entry;
  - bucket: the copy holds as many objects as the source, and was synced
    within 26 h.
Exit 1 when anything fails; --report writes the failures as JSON (the
workflow opens an issue from it), --summary a Markdown table.

sync-buckets copies each bucket into the backup bucket of its environment:
<backup>/buckets/<app>/<env>/<key>/current/, files replaced or deleted since
the last run kept under history/<date>/ for `keep` days (rclone). Each run
leaves an empty syncs/<date> marker: a new object every time, never an
overwrite, so a bucket lock on the backup bucket does not refuse it.

Environment:
  TF_STATE_BUCKET, AWS_ENDPOINT_URL_S3, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   the states
  R2_BACKUP_{PROD,STAGING}_{ACCESS_KEY_ID,SECRET_ACCESS_KEY}                       backup buckets
    (not needed when platform/ creates them: eu_backup_buckets)
  R2_BACKUP_BUCKET_PROD, R2_BACKUP_BUCKET_STAGING, R2_ENDPOINT                     fallback before
    platform/ exposes backup_targets
Tools: aws, docker (verify), rclone (sync-buckets).
"""
import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

NOW = dt.datetime.now(dt.timezone.utc)


# --- S3 ---------------------------------------------------------------------

def aws(args, creds=None, capture=True):
    env = dict(os.environ)
    if creds:
        env.update({"AWS_ENDPOINT_URL_S3": creds["endpoint"], "AWS_ACCESS_KEY_ID": creds["access_key"],
                    "AWS_SECRET_ACCESS_KEY": creds["secret_access_key"]})
    env.setdefault("AWS_DEFAULT_REGION", "auto")
    out = subprocess.run(["aws", *args], env=env, capture_output=capture, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"aws {' '.join(args[:3])}: {(out.stderr or '').strip()[:300]}")
    return out.stdout


def list_objects(bucket, creds, prefix=""):
    """[{Key, LastModified (datetime), Size}] of the bucket under prefix."""
    objs, token = [], None
    while True:
        args = ["s3api", "list-objects-v2", "--bucket", bucket, "--output", "json"]
        if prefix:
            args += ["--prefix", prefix]
        if token:
            args += ["--continuation-token", token]
        page = json.loads(aws(args, creds) or "{}")
        for o in page.get("Contents", []):
            o["LastModified"] = dt.datetime.fromisoformat(o["LastModified"].replace("Z", "+00:00"))
            objs.append(o)
        token = page.get("NextContinuationToken")
        if not token:
            return objs


def read_state(key):
    out = subprocess.run(["aws", "s3", "cp", f"s3://{os.environ['TF_STATE_BUCKET']}/{key}", "-"],
                         capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else None


# --- Inventory ----------------------------------------------------------------

def resource(state, rtype, name):
    for r in state.get("resources", []):
        if r["mode"] == "managed" and r["type"] == rtype and r["name"] == name and "module" not in r:
            return r["instances"]
    return []


def inventories(app=None, env=None):
    """(app, env, inventory, state) of every deployed environment."""
    keys = [l.split()[-1] for l in aws(["s3", "ls", f"s3://{os.environ['TF_STATE_BUCKET']}/apps/", "--recursive"]).splitlines()]
    for key in sorted(keys):
        m = re.fullmatch(r"apps/([^/]+)/([^/]+)\.tfstate", key)
        if not m or m.group(2) == "project" or (app and m.group(1) != app) or (env and m.group(2) != env):
            continue
        state = read_state(key)
        inst = resource(state or {}, "terraform_data", "backup_inventory")
        if not inst:
            yield m.group(1), m.group(2), None, state
            continue
        inp = inst[0]["attributes"]["input"]
        yield m.group(1), m.group(2), inp.get("value", inp) if isinstance(inp, dict) else inp, state


def backup_targets():
    """{production|staging: {bucket, endpoint, access_key, secret_access_key}}."""
    platform = read_state("platform/dokploy.tfstate") or {}
    outs = platform.get("outputs", {})
    targets = (outs.get("backup_targets") or {}).get("value") or {
        "production": {"bucket": os.environ.get("R2_BACKUP_BUCKET_PROD"), "endpoint": os.environ.get("R2_ENDPOINT")},
        "staging": {"bucket": os.environ.get("R2_BACKUP_BUCKET_STAGING"), "endpoint": os.environ.get("R2_ENDPOINT")},
    }
    managed = (outs.get("backup_credentials") or {}).get("value")
    for env, t in targets.items():
        if managed:
            t.update(managed[env])
        else:
            short = "PROD" if env == "production" else "STAGING"
            t["access_key"] = os.environ.get(f"R2_BACKUP_{short}_ACCESS_KEY_ID", "")
            t["secret_access_key"] = os.environ.get(f"R2_BACKUP_{short}_SECRET_ACCESS_KEY", "")
    return targets


def max_age(cron):
    """26 h for a daily schedule (fixed minute and hour, every day), 8 days otherwise."""
    f = (cron or "0 3 * * *").split()
    daily = len(f) == 5 and f[2] == "*" and f[3] == "*" and f[4] == "*"
    return dt.timedelta(hours=26) if daily else dt.timedelta(days=8)


def newest(objs, prefix, suffixes):
    """Dokploy writes <appName>/<prefix><file>: match the prefix anywhere after a /."""
    hits = [o for o in objs if (o["Key"].startswith(prefix) or f"/{prefix}" in o["Key"])
            and o["Key"].endswith(suffixes) and o["Size"] > 0]
    return max(hits, key=lambda o: o["LastModified"]) if hits else None


# --- Restore tests --------------------------------------------------------------

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def restore_database(db, dump_path):
    """Restores the dump into a throw-away container; returns (ok, detail)."""
    kind, image = db["type"], db["image"]
    name = f"verify-{uuid.uuid4().hex[:8]}"
    if kind == "mongo":
        # Integrity only: the archive must decompress to the end.
        try:
            with gzip.open(dump_path, "rb") as f:
                while f.read(1 << 20):
                    pass
            return True, "archive readable (mongo: restore not exercised)"
        except OSError as e:
            return False, f"corrupt archive: {e}"
    env = ["-e", "POSTGRES_PASSWORD=verify"] if kind == "postgres" else ["-e", "MYSQL_ROOT_PASSWORD=verify", "-e", "MARIADB_ROOT_PASSWORD=verify"]
    up = sh(["docker", "run", "-d", "--rm", "--name", name, *env, image])
    if up.returncode != 0:
        return False, f"docker run {image}: {up.stderr.strip()[:200]}"
    try:
        ready = ["pg_isready", "-U", "postgres"] if kind == "postgres" else (
            ["mysqladmin", "ping", "-uroot", "-pverify"] if kind == "mysql" else ["mariadb-admin", "ping", "-uroot", "-pverify"])
        for _ in range(90):
            if sh(["docker", "exec", name, *ready]).returncode == 0:
                break
            time.sleep(2)
        else:
            return False, f"{image} never became ready"
        time.sleep(3)  # the official images restart once after their init
        with gzip.open(dump_path, "rb") as f:
            custom = f.read(5) == b"PGDMP"
        if kind == "postgres":
            sh(["docker", "exec", name, "createdb", "-U", "postgres", "verify"])
            tool = ["pg_restore", "-U", "postgres", "-d", "verify", "--no-owner", "--no-acl"] if custom else [
                "psql", "-q", "-U", "postgres", "-d", "verify"]
            query = db.get("verify_query") or (
                "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")
            check = ["psql", "-tA", "-U", "postgres", "-d", "verify", "-c", query]
        else:
            client = "mysql" if kind == "mysql" else "mariadb"
            sh(["docker", "exec", name, client, "-uroot", "-pverify", "-e", "create database verify"])
            tool = [client, "-uroot", "-pverify", "verify"]
            query = db.get("verify_query") or (
                "select count(*) from information_schema.tables where table_schema = 'verify'")
            check = [client, "-N", "-uroot", "-pverify", "verify", "-e", query]
        with gzip.open(dump_path, "rb") as f:
            p = subprocess.Popen(["docker", "exec", "-i", name, *tool], stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            while chunk := f.read(1 << 20):
                p.stdin.write(chunk)
            p.stdin.close()
            err = p.stderr.read().decode(errors="replace")
            p.wait()
        out = sh(["docker", "exec", name, *check])
        value = (out.stdout or "").strip().splitlines()[-1:] or [""]
        try:
            n = float(value[0])
        except ValueError:
            return False, f"check query failed: {(out.stderr or value[0]).strip()[:200]}"
        if n <= 0:
            return False, f"check query returned {value[0]} ({query})"
        warn = f", restore warnings: {err.strip().splitlines()[-1][:120]}" if p.returncode and err.strip() else ""
        return True, f"restored, check = {value[0]}{warn}"
    finally:
        sh(["docker", "rm", "-f", name])


def check_volume(path):
    try:
        with tarfile.open(path) as t:
            n = sum(1 for _ in t)
        return (n > 0), f"{n} entries"
    except (tarfile.TarError, OSError) as e:
        return False, f"unreadable archive: {e}"


# --- Commands -------------------------------------------------------------------

def verify(args):
    targets = backup_targets()
    listings, results = {}, []

    def add(app, env, kind, name, ok, detail):
        results.append({"app": app, "env": env, "kind": kind, "name": name, "ok": ok, "detail": detail})
        print(f"  {'✓' if ok else '✗'} {kind} {name}: {detail}")

    for app, env, inv, state in inventories(args.app, args.env):
        print(f"{app}/{env}")
        if inv is None:
            add(app, env, "inventory", "-", True, "no backup inventory yet (deployed before it existed: deploy once)")
            continue
        target = targets[inv["environment"]]
        creds = {k: target[k] for k in ("endpoint", "access_key", "secret_access_key")}
        if target["bucket"] not in listings:
            listings[target["bucket"]] = list_objects(target["bucket"], creds)
        objs = listings[target["bucket"]]

        for k, db in (inv.get("databases") or {}).items():
            o = newest(objs, db["prefix"], (".gz", ".dump", ".sql"))
            if not o:
                add(app, env, "database", k, False, f"no dump under {db['prefix']}")
                continue
            age = NOW - o["LastModified"]
            if age > max_age(db.get("cron")):
                add(app, env, "database", k, False, f"newest dump is {age.days} d {age.seconds // 3600} h old ({o['Key']})")
                continue
            if args.no_restore:
                add(app, env, "database", k, True, f"fresh ({o['Key']}), restore skipped")
                continue
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "dump.gz"
                aws(["s3", "cp", f"s3://{target['bucket']}/{o['Key']}", str(path), "--only-show-errors"], creds)
                ok, detail = restore_database(db, path)
            add(app, env, "database", k, ok, f"{detail} ({o['Key']})")

        for k, vol in (inv.get("volumes") or {}).items():
            o = newest(objs, vol["prefix"], (".tar", ".tar.gz", ".tgz"))
            if not o:
                add(app, env, "volume", k, False, f"no archive under {vol['prefix']}")
                continue
            age = NOW - o["LastModified"]
            if age > max_age(vol.get("cron")):
                add(app, env, "volume", k, False, f"newest archive is {age.days} d {age.seconds // 3600} h old")
                continue
            if args.no_restore:
                add(app, env, "volume", k, True, f"fresh ({o['Key']}), archive not opened")
                continue
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "volume.tar"
                aws(["s3", "cp", f"s3://{target['bucket']}/{o['Key']}", str(path), "--only-show-errors"], creds)
                ok, detail = check_volume(path)
            add(app, env, "volume", k, ok, f"{detail} ({o['Key']})")

        for k, b in (inv.get("buckets") or {}).items():
            copy = [o for o in objs if o["Key"].startswith(b["prefix"] + "current/")]
            marker = max((o for o in objs if o["Key"].startswith(b["prefix"] + "syncs/")),
                         key=lambda o: o["LastModified"], default=None)
            if not marker:
                add(app, env, "bucket", k, False, "never synced (bucket-backup.yml)")
                continue
            age = NOW - marker["LastModified"]
            if age > dt.timedelta(hours=26):
                add(app, env, "bucket", k, False, f"last sync {age.days} d {age.seconds // 3600} h ago")
                continue
            try:
                src = bucket_source(state, k, b)
                n_src = len(list_objects(b["name"], src))
            except RuntimeError as e:
                add(app, env, "bucket", k, False, f"source unreadable: {e}")
                continue
            add(app, env, "bucket", k, len(copy) >= n_src,
                f"{len(copy)} objects copied, {n_src} in the source")

    failed = [r for r in results if not r["ok"]]
    if args.report:
        pathlib.Path(args.report).write_text(json.dumps(failed, indent=2))
    if args.summary:
        lines = ["| | App | Env | Kind | Name | Detail |", "|---|---|---|---|---|---|"]
        lines += [f"| {'✅' if r['ok'] else '❌'} | {r['app']} | {r['env']} | {r['kind']} | {r['name']} | {r['detail']} |" for r in results]
        with open(args.summary, "a") as f:
            f.write("## Backup verification\n\n" + "\n".join(lines) + "\n")
    print(f"\n{len(results) - len(failed)} ok, {len(failed)} failed")
    return 1 if failed else 0


def bucket_source(state, key, b):
    """Credentials of the bucket's own token, from the env state (apps/env/addons.tf)."""
    for i in resource(state, "cloudflare_account_token", "bucket"):
        if i.get("index_key") == key:
            a = i["attributes"]
            return {"endpoint": b["endpoint"], "access_key": a["id"],
                    "secret_access_key": hashlib.sha256(a["value"].encode()).hexdigest()}
    raise RuntimeError(f"no token for bucket {key} in the state")


def sync_buckets(args):
    targets, failed = backup_targets(), 0
    day = NOW.strftime("%Y-%m-%dT%H%M%SZ")
    for app, env, inv, state in inventories(args.app, args.env):
        for k, b in ((inv or {}).get("buckets") or {}).items():
            target = targets[inv["environment"]]
            src = bucket_source(state, k, b)
            remote = {
                "SRC": src, "DST": {k2: target[k2] for k2 in ("endpoint", "access_key", "secret_access_key")},
            }
            env_vars = dict(os.environ)
            for alias, c in remote.items():
                env_vars.update({
                    f"RCLONE_CONFIG_{alias}_TYPE": "s3", f"RCLONE_CONFIG_{alias}_PROVIDER": "Cloudflare",
                    f"RCLONE_CONFIG_{alias}_ACCESS_KEY_ID": c["access_key"],
                    f"RCLONE_CONFIG_{alias}_SECRET_ACCESS_KEY": c["secret_access_key"],
                    f"RCLONE_CONFIG_{alias}_ENDPOINT": c["endpoint"],
                    # Bucket-scoped tokens cannot list or create buckets.
                    f"RCLONE_CONFIG_{alias}_NO_CHECK_BUCKET": "true",
                })
            base = f"DST:{target['bucket']}/{b['prefix']}"
            steps = [
                ["rclone", "sync", f"SRC:{b['name']}", base + "current", "--backup-dir", f"{base}history/{day}", "--fast-list"],
                ["rclone", "delete", base + "history", "--min-age", f"{inv.get('keep', 7)}d"],
                ["rclone", "rmdirs", base + "history", "--leave-root"],
                ["rclone", "delete", base + "syncs", "--min-age", f"{inv.get('keep', 7)}d"],
            ]
            print(f"{app}/{env} bucket {k}: {b['name']} → {target['bucket']}/{b['prefix']}current")
            ok = all(subprocess.run(s, env=env_vars).returncode == 0 for s in steps)
            if ok:
                try:
                    aws(["s3api", "put-object", "--bucket", target["bucket"], "--key", f"{b['prefix']}syncs/{day}"],
                        remote["DST"])
                except RuntimeError as e:
                    print(f"  {e}")
                    ok = False
            print("  ✓ synced" if ok else "  ✗ sync failed")
            failed += not ok
    return 1 if failed else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["verify", "sync-buckets"])
    p.add_argument("--app")
    p.add_argument("--env")
    p.add_argument("--report")
    p.add_argument("--summary")
    p.add_argument("--no-restore", action="store_true", help="verify: freshness only, download nothing")
    args = p.parse_args()
    return verify(args) if args.command == "verify" else sync_buckets(args)


if __name__ == "__main__":
    sys.exit(main())
