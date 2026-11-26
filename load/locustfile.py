"""
Load test for Snippet Searcher with Locust.

Simulated users list snippets (most of the traffic), browse languages and rules, and now and then create a
snippet, read it, format it and delete it. Every request goes through nginx -> snippet-service, which calls
permission-service, the engine (through engine-proxy), Postgres and blob storage, so the load shows up in
New Relic in snippet-service-<env> and snippet-permission-service-<env>.

Authentication: the Auth0 machine-to-machine application of the synthetic check (client credentials).
One token is fetched when the test starts and shared by every simulated user.

    pip install locust
    export SYNTHETIC_CLIENT_ID=aAaDGagSXCz79gw25ZOJ5WPYPUmxw0Zv
    read -rs -p "Client secret: " SYNTHETIC_CLIENT_SECRET; echo; export SYNTHETIC_CLIENT_SECRET
    locust -f load/locustfile.py --host https://snippet-searcher-bry.duckdns.org
    # then open http://localhost:8089, or headless:
    locust -f load/locustfile.py --host https://snippet-searcher-bry.duckdns.org --headless -u 20 -r 2 -t 3m

The secret can also be put in load/client_secret (git-ignored) instead of the environment variable.
Snippets created by the test are named load-<n> and deleted right away; they belong to the M2M client,
so no real user sees them.
"""

import itertools
import os
import pathlib
import threading

import requests
from locust import HttpUser, between, events, task

AUTH0_DOMAIN = os.environ.get("AUTH0_DOMAIN", "snippet-searcher-bry.us.auth0.com")
AUDIENCE = os.environ.get("AUTH0_AUDIENCE", "https://snippet-searcher-api")
CLIENT_ID = os.environ.get("SYNTHETIC_CLIENT_ID", "aAaDGagSXCz79gw25ZOJ5WPYPUmxw0Zv")
SECRET_FILE = pathlib.Path(__file__).with_name("client_secret")

CODE = 'let greeting: string = "load test";\nprintln(greeting);'
UGLY_CODE = "let my_value:number=1;\nprintln(my_value);"

USER_AGENT = "snippet-searcher-locust"

_token = None
_token_lock = threading.Lock()
_counter = itertools.count()


def _client_secret() -> str:
    secret = os.environ.get("SYNTHETIC_CLIENT_SECRET", "").strip()
    if not secret and SECRET_FILE.exists():
        secret = "".join(SECRET_FILE.read_text().split())
    if not secret:
        raise SystemExit("Set SYNTHETIC_CLIENT_SECRET or create load/client_secret (see the docstring).")
    return secret


def _fetch_token() -> str:
    response = requests.post(
        f"https://{AUTH0_DOMAIN}/oauth/token",
        json={"grant_type": "client_credentials", "client_id": CLIENT_ID,
              "client_secret": _client_secret(), "audience": AUDIENCE},
        timeout=15,
    )
    if response.status_code != 200:
        raise SystemExit(f"Auth0 refused the client credentials: HTTP {response.status_code}")
    return response.json()["access_token"]


@events.test_start.add_listener
def _on_test_start(environment, **_kwargs):
    global _token
    with _token_lock:
        _token = _fetch_token()
    print("Got an Auth0 token for the load test.")


class SnippetUser(HttpUser):
    """A user browsing and editing snippets, thinking 1 to 3 seconds between actions."""

    wait_time = between(1, 3)

    def on_start(self):
        self.client.headers["Authorization"] = f"Bearer {_token}"
        # lets the New Relic dashboard tell load-test traffic from real users, Cypress and the synthetic check
        self.client.headers["User-Agent"] = USER_AGENT

    @task(6)
    def list_snippets(self):
        self.client.get("/api/snippets?page=0&size=20&sortBy=name&direction=asc&relationship=all",
                        name="GET /api/snippets")

    @task(2)
    def search_by_name(self):
        self.client.get("/api/snippets?page=0&size=20&name=load", name="GET /api/snippets?name=")

    @task(1)
    def languages_and_rules(self):
        self.client.get("/api/languages", name="GET /api/languages")
        self.client.get("/api/rules/lint", name="GET /api/rules/lint")
        self.client.get("/api/rules/format", name="GET /api/rules/format")

    @task(2)
    def create_read_format_delete(self):
        body = {"name": f"load-{next(_counter)}", "description": "created by locust", "language": "printscript",
                "languageVersion": "1.1", "content": UGLY_CODE}
        with self.client.post("/api/snippets", json=body, name="POST /api/snippets", catch_response=True) as r:
            if r.status_code != 201:
                r.failure(f"create returned {r.status_code}")
                return
            snippet_id = r.json()["id"]
        try:
            self.client.get(f"/api/snippets/{snippet_id}", name="GET /api/snippets/[id]")
            self.client.post(f"/api/snippets/{snippet_id}/format", json={"content": UGLY_CODE},
                             name="POST /api/snippets/[id]/format")
        finally:
            self.client.delete(f"/api/snippets/{snippet_id}", name="DELETE /api/snippets/[id]")

    @task(1)
    def invalid_snippet(self):
        body = {"name": f"load-bad-{next(_counter)}", "description": "does not parse", "language": "printscript",
                "languageVersion": "1.1", "content": "let x: number = ;"}
        with self.client.post("/api/snippets", json=body, name="POST /api/snippets (invalid)",
                              catch_response=True) as r:
            if r.status_code == 400:
                r.success()  # the parser's error is the expected answer
            else:
                r.failure(f"expected 400, got {r.status_code}")
