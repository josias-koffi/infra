"""Calls to Google's REST APIs with the service account of the platform
(GOOGLE_SERVICE_ACCOUNT_JSON), shared by scripts/ensure-analytics.py and
scripts/ensure-search-console.py."""
import json
import os
import sys
import time


class Api:
    """Authorized JSON calls, retried on quota (429) and server errors.

    A GET answered 404 returns None: "not there" is an answer, not a failure.
    Any other refusal stops the script with Google's message.
    """

    def __init__(self, session, label="google"):
        self.s = session
        self.label = label

    def call(self, method, url, body=None, params=None):
        for attempt in range(6):
            r = self.s.request(method, url, json=body, params=params, timeout=60)
            if r.status_code == 429 or r.status_code >= 500:
                time.sleep(min(2 ** attempt * 5, 60))
                continue
            if r.status_code == 404 and method == "GET":
                return None
            if r.status_code >= 400:
                sys.exit(f"{self.label}: {method} {url} → {r.status_code}\n{r.text}")
            return r.json() if r.content else {}
        sys.exit(f"{self.label}: {method} {url} still refused after retries ({r.status_code})")

    def pages(self, url, key, params=None):
        params, items = dict(params or {}), []
        while True:
            page = self.call("GET", url, params=params) or {}
            items += page.get(key, [])
            if not page.get("nextPageToken"):
                return items
            params["pageToken"] = page["nextPageToken"]


def session_from_env(scopes, label):
    """A session signed with GOOGLE_SERVICE_ACCOUNT_JSON (a repo secret of infra)."""
    if not os.environ.get("GOOGLE_SERVICE_ACCOUNT_JSON"):
        sys.exit(f"{label}: GOOGLE_SERVICE_ACCOUNT_JSON is required (infra repo secret, docs/reference/configuration.md)")
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    info = json.loads(os.environ["GOOGLE_SERVICE_ACCOUNT_JSON"])
    creds = service_account.Credentials.from_service_account_info(info, scopes=scopes)
    return AuthorizedSession(creds)
