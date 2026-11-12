#!/usr/bin/env python3
"""Provisions the analytics of an app (add-on `analytics`): a Google Analytics 4
property per app with a web data stream per environment, and a Google Tag
Manager web container per app that loads GA4 through a Google tag.

The container is shared by the environments of the app: a lookup table on the
page hostname picks the measurement id of the environment, so staging traffic
never lands in the production stream. Every host of every environment of the
manifest is in that table.

Everything is found back by name, so a run only creates what is missing and
publishes the container only when what infra manages in it changed:
  GA4 property      displayName = <app>
  GA4 data stream   displayName = <environment>
  GTM container     name        = <app>
  in the container  the variable "GA4 measurement ID (infra)" and the tag
                    "Google tag (infra)"; anything else in the container is
                    left alone (other tags, consent, triggers made by hand).

CNIL settings, set at creation and put back when changed by hand: GA cookies
of 13 months not prolonged by new visits (Google's default: 2 years,
prolonged), data kept 14 months not reset by new activity (default: 2 months,
reset).

    scripts/ensure-analytics.py <manifest> <environment> [--dry-run] <out.json>

<out.json> receives the variables of the add-on for <environment>, a JSON
object (apps/env, var.analytics): GTM_CONTAINER_ID, GA_MEASUREMENT_ID; `{}`
when the manifest has no `analytics`. --dry-run (plan-only deploys) creates
nothing and writes "pending" for what does not exist yet.

Environment:
  GOOGLE_SERVICE_ACCOUNT_JSON  key of a service account, Editor on the GA
                               account and Administrator of the GTM
                               account (creating a container needs it)
  GA_ACCOUNT_ID                Google Analytics account (accounts/<id>)
  GTM_ACCOUNT_ID               Google Tag Manager account (accounts/<id>)
"""
import json
import os
import pathlib
import sys
import time

import yaml

GA = "https://analyticsadmin.googleapis.com/v1beta"
GTM = "https://tagmanager.googleapis.com/tagmanager/v2"
SCOPES = [
    "https://www.googleapis.com/auth/analytics.edit",
    "https://www.googleapis.com/auth/tagmanager.readonly",
    "https://www.googleapis.com/auth/tagmanager.edit.containers",
    "https://www.googleapis.com/auth/tagmanager.edit.containerversions",
    "https://www.googleapis.com/auth/tagmanager.publish",
]
VARIABLE = "GA4 measurement ID (infra)"
TAG = "Google tag (infra)"
WORKSPACE_PREFIX = "infra "
ALL_PAGES = "2147479553"  # built-in trigger of every web container
PENDING = "pending"

# CNIL: measurement cookies live 13 months at most, counted from the first
# visit (cookie_update false: a new visit does not push the date back), and
# the data no longer than 25 months — GA4 keeps 14 at most on a free property.
COOKIE_SETTINGS = {
    "cookie_expires": str(13 * 30 * 24 * 3600),  # 390 days
    "cookie_update": "false",
}
RETENTION = {
    "eventDataRetention": "FOURTEEN_MONTHS",
    "userDataRetention": "FOURTEEN_MONTHS",
    # True would restart the 14 months at every visit of a returning user.
    "resetUserDataOnNewActivity": False,
}


class Api:
    """Authorized JSON calls, retried on quota (429) and server errors."""

    def __init__(self, session):
        self.s = session

    def call(self, method, url, body=None, params=None):
        for attempt in range(6):
            r = self.s.request(method, url, json=body, params=params, timeout=60)
            if r.status_code == 429 or r.status_code >= 500:
                time.sleep(min(2 ** attempt * 5, 60))
                continue
            if r.status_code == 404 and method == "GET":
                return None
            if r.status_code >= 400:
                sys.exit(f"analytics: {method} {url} → {r.status_code}\n{r.text}")
            return r.json() if r.content else {}
        sys.exit(f"analytics: {method} {url} still refused after retries ({r.status_code})")

    def pages(self, url, key, params=None):
        params, items = dict(params or {}), []
        while True:
            page = self.call("GET", url, params=params) or {}
            items += page.get(key, [])
            if not page.get("nextPageToken"):
                return items
            params["pageToken"] = page["nextPageToken"]


def session_from_env():
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    info = json.loads(os.environ["GOOGLE_SERVICE_ACCOUNT_JSON"])
    creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPES)
    return AuthorizedSession(creds)


def account(var):
    v = os.environ.get(var, "").strip()
    if not v:
        sys.exit(f"analytics: {var} is required (infra repo variable, docs/reference/configuration.md)")
    return v if v.startswith("accounts/") else f"accounts/{v}"


def hosts_by_env(m):
    """{environment: its hosts, in manifest order} — the first one is the URL of its stream."""
    return {env: list(dict.fromkeys(h.lower() for h in spec.get("domains", {}).values()))
            for env, spec in m["environments"].items()}


# --- GA4 ---------------------------------------------------------------------

def ensure_property(api, ga_account, app, spec, dry_run):
    props = api.pages(f"{GA}/properties", "properties", {"filter": f"parent:{ga_account}", "pageSize": 200})
    found = [p for p in props if p.get("displayName") == app]
    if len(found) > 1:
        sys.exit(f"analytics: {len(found)} GA4 properties are named {app} in {ga_account} — rename the extra ones")
    if found:
        return found[0]["name"]
    print(f"analytics: GA4 property {app} {'would be created' if dry_run else 'created'}")
    if dry_run:
        return None
    return api.call("POST", f"{GA}/properties", {
        "parent": ga_account,
        "displayName": app,
        "timeZone": spec.get("timeZone", "Europe/Paris"),
        "currencyCode": spec.get("currency", "EUR"),
        "propertyType": "PROPERTY_TYPE_ORDINARY",
    })["name"]


def ensure_retention(api, prop, dry_run):
    """14 months of data, not prolonged by new activity (GA4 creates 2, prolonged)."""
    if not prop:
        print("analytics: GA4 data retention would be set to 14 months")
        return
    path = f"{GA}/{prop}/dataRetentionSettings"
    current = api.call("GET", path) or {}
    # The JSON of a protobuf leaves out a false boolean.
    if all(current.get(k, False if isinstance(v, bool) else None) == v for k, v in RETENTION.items()):
        return
    print(f"analytics: GA4 data retention {'would be set' if dry_run else 'set'} to 14 months, not reset by new activity")
    if not dry_run:
        api.call("PATCH", path, {**RETENTION, "name": f"{prop}/dataRetentionSettings"},
                 params={"updateMask": ",".join(RETENTION)})


def ensure_streams(api, prop, hosts, dry_run):
    """{environment: measurement id} — one web data stream per environment."""
    streams = api.pages(f"{GA}/{prop}/dataStreams", "dataStreams") if prop else []
    by_name = {s.get("displayName"): s for s in streams if s.get("type") == "WEB_DATA_STREAM"}
    ids = {}
    for env, env_hosts in hosts.items():
        if env in by_name:
            ids[env] = by_name[env]["webStreamData"]["measurementId"]
            continue
        if not env_hosts:
            continue  # nothing to measure: the env has no domain
        print(f"analytics: GA4 stream {env} (https://{env_hosts[0]}) {'would be created' if dry_run else 'created'}")
        if dry_run:
            ids[env] = PENDING
            continue
        s = api.call("POST", f"{GA}/{prop}/dataStreams", {
            "type": "WEB_DATA_STREAM",
            "displayName": env,
            "webStreamData": {"defaultUri": f"https://{env_hosts[0]}"},
        })
        ids[env] = s["webStreamData"]["measurementId"]
    return ids


# --- GTM ---------------------------------------------------------------------

def lookup_variable(table):
    """The GTM lookup table (type smm): {{Page Hostname}} → measurement id."""
    return {
        "name": VARIABLE,
        "type": "smm",
        "notes": "Managed by infra (scripts/ensure-analytics.py): edits are overwritten.",
        "parameter": [
            {"type": "boolean", "key": "setDefaultValue", "value": "false"},
            {"type": "template", "key": "input", "value": "{{Page Hostname}}"},
            {"type": "list", "key": "map", "list": [
                {"type": "map", "map": [
                    {"type": "template", "key": "key", "value": host},
                    {"type": "template", "key": "value", "value": mid},
                ]} for host, mid in sorted(table.items())
            ]},
        ],
    }


def google_tag():
    return {
        "name": TAG,
        "type": "googtag",
        "notes": "Managed by infra (scripts/ensure-analytics.py): edits are overwritten.",
        "parameter": [
            {"type": "template", "key": "tagId", "value": "{{%s}}" % VARIABLE},
            {"type": "list", "key": "configSettingsTable", "list": [
                {"type": "map", "map": [
                    {"type": "template", "key": "parameter", "value": name},
                    {"type": "template", "key": "parameterValue", "value": value},
                ]} for name, value in sorted(COOKIE_SETTINGS.items())
            ]},
        ],
        "firingTriggerId": [ALL_PAGES],
    }


def table_of(variable):
    """The host → id map of a lookup table variable, as GTM returns it."""
    for p in (variable or {}).get("parameter", []):
        if p.get("key") == "map":
            return {
                {e["key"]: e.get("value") for e in row.get("map", [])}.get("key", "").lower():
                {e["key"]: e.get("value") for e in row.get("map", [])}.get("value")
                for row in p.get("list", [])
            }
    return None


def config_settings_of(tag):
    """The "Configuration settings" of a Google tag, as {parameter: value}."""
    for p in tag.get("parameter", []):
        if p.get("key") == "configSettingsTable":
            rows = [{e["key"]: e.get("value") for e in row.get("map", [])} for row in p.get("list", [])]
            return {r.get("parameter"): r.get("parameterValue") for r in rows}
    return {}


def tag_matches(tag):
    if not tag or tag.get("type") != "googtag":
        return False
    tag_id = next((p.get("value") for p in tag.get("parameter", []) if p.get("key") == "tagId"), None)
    return (tag_id == "{{%s}}" % VARIABLE and ALL_PAGES in tag.get("firingTriggerId", [])
            and not tag.get("paused") and config_settings_of(tag) == COOKIE_SETTINGS)


def ensure_container(api, gtm_account, app, dry_run):
    containers = api.pages(f"{GTM}/{gtm_account}/containers", "container")
    found = [c for c in containers if c.get("name") == app]
    if len(found) > 1:
        sys.exit(f"analytics: {len(found)} GTM containers are named {app} in {gtm_account} — rename the extra ones")
    if found:
        return found[0]
    print(f"analytics: GTM container {app} {'would be created' if dry_run else 'created'}")
    if dry_run:
        return None
    return api.call("POST", f"{GTM}/{gtm_account}/containers", {"name": app, "usageContext": ["web"]})


def upsert(api, ws, kind, body):
    """Creates or replaces, by name, a variable or tag of the workspace."""
    existing = api.pages(f"{GTM}/{ws}/{kind}", kind[:-1])
    same = next((e for e in existing if e.get("name") == body["name"]), None)
    if same:
        return api.call("PUT", f"{GTM}/{same['path']}", body)
    return api.call("POST", f"{GTM}/{ws}/{kind}", body)


def publish(api, container, table, app):
    path = container["path"]
    # A run that failed half-way leaves its workspace: GTM caps workspaces
    # (3 on a free account), so the leftovers of infra go first.
    for w in api.pages(f"{GTM}/{path}/workspaces", "workspace"):
        if w.get("name", "").startswith(WORKSPACE_PREFIX):
            api.call("DELETE", f"{GTM}/{w['path']}")
    ws = api.call("POST", f"{GTM}/{path}/workspaces", {
        # GTM refuses ":" in a workspace name.
        "name": f"{WORKSPACE_PREFIX}{time.strftime('%Y-%m-%d %Hh%Mm%Ss UTC', time.gmtime())}",
        "description": "Opened by scripts/ensure-analytics.py, consumed by its version.",
    })["path"]
    try:
        enabled = api.call("GET", f"{GTM}/{ws}/built_in_variables") or {}
        if not any(b.get("type") == "pageHostname" for b in enabled.get("builtInVariable", [])):
            api.call("POST", f"{GTM}/{ws}/built_in_variables", params={"type": "pageHostname"})
        upsert(api, ws, "variables", lookup_variable(table))
        upsert(api, ws, "tags", google_tag())
        # Making the version consumes the workspace.
        v = api.call("POST", f"{GTM}/{ws}:create_version", {
            "name": f"infra {app}",
            "notes": "GA4 hosts: " + ", ".join(f"{h} → {m}" for h, m in sorted(table.items())),
        })
    except SystemExit:
        api.call("DELETE", f"{GTM}/{ws}")
        raise
    if v.get("compilerError") or "containerVersion" not in v:
        sys.exit(f"analytics: GTM refused the version of {app}: {json.dumps(v)}")
    api.call("POST", f"{GTM}/{v['containerVersion']['path']}:publish")
    print(f"analytics: GTM container {container['publicId']} published")


def ensure_published(api, container, table, app, dry_run):
    live = api.call("GET", f"{GTM}/{container['path']}/versions:live") if container else None
    live = live or {}
    variable = next((x for x in live.get("variable", []) if x.get("name") == VARIABLE), None)
    tag = next((x for x in live.get("tag", []) if x.get("name") == TAG), None)
    if table_of(variable) == table and tag_matches(tag):
        return
    print(f"analytics: GTM container {app} {'would be published' if dry_run else 'publishing'} "
          f"({', '.join(f'{h} → {m}' for h, m in sorted(table.items()))})")
    if not dry_run:
        publish(api, container, table, app)


# -----------------------------------------------------------------------------

def run(api, m, environment, dry_run, ga_account, gtm_account):
    spec, app = m["analytics"] or {}, m["name"]
    hosts = hosts_by_env(m)
    prop = ensure_property(api, ga_account, app, spec, dry_run)
    ensure_retention(api, prop, dry_run)
    ids = ensure_streams(api, prop, hosts, dry_run)
    table = {h: ids[env] for env, hs in hosts.items() if env in ids for h in hs}
    container = ensure_container(api, gtm_account, app, dry_run)
    if PENDING not in ids.values():
        ensure_published(api, container, table, app, dry_run)
    else:
        print(f"analytics: GTM container {app} would be published once its streams exist")
    return {
        "GTM_CONTAINER_ID": container["publicId"] if container else PENDING,
        "GA_MEASUREMENT_ID": ids.get(environment, PENDING),
    }


def main(manifest_path, environment, dry_run, out):
    m = yaml.safe_load(open(manifest_path))
    pathlib.Path(out).write_text("{}")
    if m.get("analytics") is None:
        return 0
    if not hosts_by_env(m).get(environment):
        sys.exit(f"analytics: environments.{environment} has no domain to measure")
    if not os.environ.get("GOOGLE_SERVICE_ACCOUNT_JSON"):
        sys.exit("analytics: GOOGLE_SERVICE_ACCOUNT_JSON is required (infra repo secret, docs/reference/configuration.md)")
    values = run(Api(session_from_env()), m, environment, dry_run,
                 account("GA_ACCOUNT_ID"), account("GTM_ACCOUNT_ID"))
    pathlib.Path(out).write_text(json.dumps(values))
    print(f"analytics: {environment} → {values['GTM_CONTAINER_ID']}, {values['GA_MEASUREMENT_ID']}")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    if len(args) != 3:
        sys.exit(__doc__)
    sys.exit(main(args[0], args[1], "--dry-run" in sys.argv[1:], args[2]))
