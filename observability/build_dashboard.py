"""
Builds the New Relic dashboard JSON for one environment, ready for Dashboards > Import dashboard.

    python observability/build_dashboard.py dev  8743599 > observability/dashboard-dev.json
    python observability/build_dashboard.py prod 8743599 > observability/dashboard-prod.json

On Windows set PYTHONIOENCODING=utf-8 first, or the accents in the titles get mangled.

Widgets have no SINCE clause (except the "last 5 minutes" counters), so the dashboard's time picker
controls them; with "Last 30 minutes" and auto-refresh it works as a live view.
"""

import json
import sys

env = sys.argv[1] if len(sys.argv) > 1 else "dev"
account = int(sys.argv[2]) if len(sys.argv) > 2 else 8743599

API = f"snippet-service-{env}"
WORKER = f"snippet-worker-{env}"
PERMISSIONS = f"snippet-permission-service-{env}"
ENGINE = f"snippet-engine-{env}"
APPS = f"'{API}', '{WORKER}', '{PERMISSIONS}', '{ENGINE}'"

# Who sent the request, from its User-Agent: the load test, Cypress (Electron), the synthetic check (curl)
# or a person's browser.
SOURCE = ("FACET CASES("
          "WHERE request.headers.userAgent LIKE '%snippet-searcher-locust%' AS 'Locust', "
          "WHERE request.headers.userAgent LIKE '%Cypress%' AS 'Cypress', "
          "WHERE request.headers.userAgent LIKE 'curl%' AS 'Synthetic check', "
          "WHERE request.headers.userAgent IS NOT NULL AS 'Usuarios')")


def widget(title, query, viz, column, row, width, height):
    return {
        "title": title,
        "layout": {"column": column, "row": row, "width": width, "height": height},
        "linkedEntityGuids": None,
        "visualization": {"id": viz},
        "rawConfiguration": {
            "facet": {"showOtherSeries": False},
            "legend": {"enabled": True},
            "nrqlQueries": [{"accountIds": [account], "query": query}],
            "platformOptions": {"ignoreTimeRange": False},
        },
    }


live = [
    # row 1: the numbers at a glance (last 5 minutes)
    widget("Requests por minuto (últimos 5 min)",
           f"SELECT rate(count(*), 1 minute) AS 'req/min' FROM Transaction WHERE appName = '{API}' SINCE 5 minutes ago",
           "viz.billboard", 1, 1, 3, 3),
    widget("Latencia p95 (últimos 5 min)",
           f"SELECT percentile(duration * 1000, 95) AS 'p95 ms' FROM Transaction WHERE appName = '{API}' SINCE 5 minutes ago",
           "viz.billboard", 4, 1, 3, 3),
    widget("Tasa de error (últimos 5 min)",
           f"SELECT percentage(count(*), WHERE error IS true) AS 'error %' FROM Transaction WHERE appName = '{API}' SINCE 5 minutes ago",
           "viz.billboard", 7, 1, 3, 3),
    widget("Synthetic check (último)",
           f"SELECT latest(snippet_searcher.synthetic.success) AS 'OK (1) / falla (0)' FROM Metric WHERE environment = '{env}' SINCE 5 minutes ago",
           "viz.billboard", 10, 1, 3, 3),
    # row 2: traffic over time, by source, and latency
    widget("Tráfico por origen (req/min)",
           f"SELECT rate(count(*), 1 minute) FROM Transaction WHERE appName = '{API}' {SOURCE} TIMESERIES",
           "viz.area", 1, 4, 6, 3),
    widget("Latencia p50 / p95 / p99 (ms)",
           f"SELECT percentile(duration * 1000, 50, 95, 99) FROM Transaction WHERE appName = '{API}' TIMESERIES",
           "viz.line", 7, 4, 6, 3),
    # row 3: per endpoint
    widget("Endpoints: llamadas y tiempos",
           f"SELECT count(*) AS 'llamadas', average(duration * 1000) AS 'prom ms', percentile(duration * 1000, 95) AS 'p95 ms', "
           f"percentage(count(*), WHERE error IS true) AS 'error %' FROM Transaction WHERE appName = '{API}' FACET name LIMIT 20",
           "viz.table", 1, 7, 6, 3),
    widget("Errores por endpoint",
           f"SELECT count(*) FROM Transaction WHERE appName = '{API}' AND error IS true FACET name TIMESERIES",
           "viz.line", 7, 7, 6, 3),
    # row 4: where the time goes
    widget("Dónde se va el tiempo (ms promedio por request)",
           f"SELECT average(databaseDuration * 1000) AS 'Postgres', average(externalDuration * 1000) AS 'Servicios externos (engine, permisos, Auth0)', "
           f"average(duration * 1000) AS 'Total' FROM Transaction WHERE appName = '{API}' TIMESERIES",
           "viz.line", 1, 10, 6, 3),
    widget("Llamadas a otros servicios (ms promedio)",
           f"SELECT average(duration.ms) FROM Span WHERE appName = '{API}' AND span.kind = 'client' FACET peer.hostname TIMESERIES",
           "viz.line", 7, 10, 6, 3),
    # row 5: synthetic check and the other services
    widget("Synthetic check: éxito y duración",
           f"SELECT latest(snippet_searcher.synthetic.success) AS 'éxito', average(snippet_searcher.synthetic.duration_ms) / 1000 AS 'duración (s)' "
           f"FROM Metric WHERE environment = '{env}' TIMESERIES 1 minute",
           "viz.line", 1, 13, 6, 3),
    widget("permission-service: req/min y p95 (ms)",
           f"SELECT rate(count(*), 1 minute) AS 'req/min', percentile(duration * 1000, 95) AS 'p95 ms' FROM Transaction WHERE appName = '{PERMISSIONS}' TIMESERIES",
           "viz.line", 7, 13, 6, 3),
    # row 6: logs and JVM
    widget("Logs por servicio y nivel",
           f"SELECT count(*) FROM Log WHERE entity.name IN ({APPS}) FACET entity.name, level TIMESERIES",
           "viz.area", 1, 16, 6, 3),
    widget("Memoria heap usada (MB)",
           f"SELECT average(apm.service.memory.heap.used) FROM Metric WHERE appName IN ({APPS}) FACET appName TIMESERIES",
           "viz.line", 7, 16, 6, 3),
]

load = [
    widget("Locust: req/min",
           f"SELECT rate(count(*), 1 minute) FROM Transaction WHERE appName = '{API}' AND request.headers.userAgent = 'snippet-searcher-locust' TIMESERIES",
           "viz.area", 1, 1, 6, 3),
    widget("Locust: latencia p50 / p95 (ms)",
           f"SELECT percentile(duration * 1000, 50, 95) FROM Transaction WHERE appName = '{API}' AND request.headers.userAgent = 'snippet-searcher-locust' TIMESERIES",
           "viz.line", 7, 1, 6, 3),
    widget("Locust: p95 por endpoint (ms)",
           f"SELECT percentile(duration * 1000, 95) FROM Transaction WHERE appName = '{API}' AND request.headers.userAgent = 'snippet-searcher-locust' FACET name TIMESERIES",
           "viz.line", 1, 4, 6, 3),
    widget("Locust: errores",
           f"SELECT count(*) FROM Transaction WHERE appName = '{API}' AND request.headers.userAgent = 'snippet-searcher-locust' AND error IS true FACET name TIMESERIES",
           "viz.line", 7, 4, 6, 3),
    widget("Usuarios reales mientras corre la carga: p95 (ms)",
           f"SELECT percentile(duration * 1000, 95) FROM Transaction WHERE appName = '{API}' AND request.headers.userAgent NOT LIKE '%locust%' TIMESERIES",
           "viz.line", 1, 7, 6, 3),
    widget("CPU de los servicios (%)",
           f"SELECT average(apm.service.cpu.usertime.utilization) * 100 FROM Metric WHERE appName IN ({APPS}) FACET appName TIMESERIES",
           "viz.line", 7, 7, 6, 3),
]

dashboard = {
    "name": f"Snippet Searcher ({env})",
    "description": f"Tráfico, latencia, errores, synthetic check y prueba de carga del entorno {env}.",
    "permissions": "PUBLIC_READ_WRITE",
    "pages": [
        {"name": "Tiempo real", "description": None, "widgets": live},
        {"name": "Prueba de carga", "description": None, "widgets": load},
    ],
    "variables": [],
}

json.dump(dashboard, sys.stdout, ensure_ascii=False, indent=2)
print()
