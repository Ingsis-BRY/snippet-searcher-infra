"""
Short load test for the live demo: 4 minutes with a visible ramp, a peak and a drop, so the
New Relic dashboard shows a clear shape while you talk.

    locust -f load/demo.py --host https://snippet-searcher-bry.duckdns.org --autostart

Then open http://localhost:8089 (Locust's live charts) next to the New Relic dashboard.
Same users, tasks and credentials as locustfile.py (SYNTHETIC_CLIENT_SECRET or load/client_secret).

    0:00-1:00   ramp     5 -> 15 users   traffic appears as "Locust" in the dashboard
    1:00-2:30   peak     40 users        requests per minute and p95 go up
    2:30-4:00   back     10 users        latency comes back down
    4:00        stop
"""

from locust import LoadTestShape

from locustfile import SnippetUser  # noqa: F401  (the user class Locust runs)

# (end of the step in seconds, users, spawn rate per second)
STEPS = [
    (30, 5, 1),
    (60, 15, 2),
    (150, 40, 4),
    (240, 10, 4),
]


class DemoShape(LoadTestShape):
    def tick(self):
        run_time = self.get_run_time()
        for end, users, rate in STEPS:
            if run_time < end:
                return users, rate
        return None
