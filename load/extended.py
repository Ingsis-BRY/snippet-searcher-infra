"""
Extended load test: about 40 minutes in phases, to watch the system on the New Relic dashboard over time.

    locust -f load/extended.py --host https://snippet-searcher-bry.duckdns.org --headless \
        --csv load/results/extended --html load/results/extended.html

The user count comes from the phases below (-u / -r / -t are ignored). Same users and tasks as
locustfile.py, same credentials (SYNTHETIC_CLIENT_SECRET or load/client_secret).

Phases (minutes):
    0-5    warm-up        10 users   baseline: latency with light traffic
    5-20   steady         25 users   normal load held for 15 minutes: is latency stable? memory?
    20-25  peak           50 users   twice the normal load
    25-27  spike          80 users   a sudden burst: how far does p95 go, does anything fail?
    27-35  recovery       25 users   does latency come back to the steady-state level?
    35-40  cool-down      10 users   back to baseline, then stop

Safety: after the first minute, if more than 10% of requests fail the test stops by itself, so a
problem in dev doesn't get hammered for half an hour.
"""

from locust import LoadTestShape

from locustfile import SnippetUser  # noqa: F401  (the user class Locust runs)

# (end of the phase in seconds, users, spawn rate per second, name)
PHASES = [
    (5 * 60, 10, 2, "warm-up"),
    (20 * 60, 25, 2, "steady"),
    (25 * 60, 50, 5, "peak"),
    (27 * 60, 80, 10, "spike"),
    (35 * 60, 25, 5, "recovery"),
    (40 * 60, 10, 2, "cool-down"),
]
MAX_FAIL_RATIO = 0.10


class PhasedLoad(LoadTestShape):
    current = None

    def tick(self):
        run_time = self.get_run_time()
        stats = self.runner.stats.total
        if run_time > 60 and stats.num_requests > 100 and stats.fail_ratio > MAX_FAIL_RATIO:
            print(f"Stopping: {stats.fail_ratio:.0%} of requests failed (limit {MAX_FAIL_RATIO:.0%}).")
            return None
        for end, users, rate, name in PHASES:
            if run_time < end:
                if name != self.current:
                    self.current = name
                    print(f"[{int(run_time // 60):>2} min] phase '{name}': {users} users")
                return users, rate
        return None
