#!/usr/bin/env python3
"""
create-dashboard.py — Deploy "EKS Stock App — semea-eks-vicma" dashboard to Datadog.

Requires:
  pip install datadog-api-client
  export DD_API_KEY=<your-api-key>
  export DD_APP_KEY=<your-app-key>
"""

import os
from datadog_api_client import ApiClient, Configuration
from datadog_api_client.v1.api.dashboards_api import DashboardsApi
from datadog_api_client.v1.model.dashboard import Dashboard
from datadog_api_client.v1.model.dashboard_layout_type import DashboardLayoutType

# ── Widget helpers ────────────────────────────────────────────────────────────

def placed(widget, x, y, w, h):
    """Attach a layout position to a widget definition dict."""
    return {"definition": widget, "layout": {"x": x, "y": y, "width": w, "height": h}}


def group(title, widgets, x=0, y=0, w=12, h=4):
    """Wrap widgets in a group widget."""
    return placed({
        "type": "group",
        "title": title,
        "layout_type": "ordered",
        "widgets": widgets,
    }, x, y, w, h)


def qv_single(title, expr, aggr="last"):
    """Query-value widget — single metric expression."""
    return {
        "type": "query_value",
        "title": title,
        "title_size": "16",
        "title_align": "left",
        "precision": 0,
        "requests": [{
            "formulas": [{"formula": "query1"}],
            "queries": [{"name": "query1", "data_source": "metrics",
                         "query": expr, "aggregator": aggr}],
            "response_format": "scalar",
        }],
    }


def qv_formula(title, queries, formula_str, precision=1):
    """Query-value widget — derived formula (e.g. utilisation %)."""
    qs = [{"name": f"q{i}", "data_source": "metrics",
           "query": q, "aggregator": "avg"}
          for i, q in enumerate(queries)]
    return {
        "type": "query_value",
        "title": title,
        "title_size": "16",
        "title_align": "left",
        "precision": precision,
        "requests": [{
            "formulas": [{"formula": formula_str}],
            "queries": qs,
            "response_format": "scalar",
        }],
    }


def ts(title, requests, display="line"):
    """Timeseries widget."""
    return {
        "type": "timeseries",
        "title": title,
        "title_size": "16",
        "title_align": "left",
        "show_legend": True,
        "requests": requests,
    }


def ts_req(expr, label, color=None):
    """Single timeseries request entry."""
    req = {
        "formulas": [{"formula": "query1", "alias": label}],
        "queries": [{"name": "query1", "data_source": "metrics", "query": expr}],
        "response_format": "timeseries",
        "display_type": "line",
    }
    if color:
        req["style"] = {"palette": color}
    return req


# ── Widget definitions ────────────────────────────────────────────────────────

CLUSTER = "semea-eks-vicma"
NS = "stock-demo"
SCOPE = f"cluster_name:{CLUSTER}"
NS_SCOPE = f"cluster_name:{CLUSTER},kube_namespace:{NS}"

# Row 1 — EKS Node Management (Karpenter)
row1_widgets = [
    placed(qv_single("Total Nodes",
        f"sum:kubernetes_state.node.count{{{SCOPE}}}"), 0, 0, 3, 2),
    placed(qv_single("Spot Nodes",
        f"sum:kubernetes_state.node.count{{{SCOPE},label_karpenter_sh_capacity_type:spot}}"), 3, 0, 3, 2),
    placed(qv_single("On-Demand Nodes",
        f"sum:kubernetes_state.node.count{{{SCOPE},label_karpenter_sh_capacity_type:on-demand}}"), 6, 0, 3, 2),
    placed(ts("Node Count Over Time", [
        ts_req(f"sum:kubernetes_state.node.count{{{SCOPE},label_karpenter_sh_capacity_type:spot}}", "spot", "warm"),
        ts_req(f"sum:kubernetes_state.node.count{{{SCOPE},label_karpenter_sh_capacity_type:on-demand}}", "on-demand", "cool"),
    ]), 9, 0, 3, 2),
]

# Row 2 — Pod CPU & Memory Utilisation (% of requests/limits)
row2_widgets = [
    placed(qv_formula("CPU % of Requests",
        [f"avg:kubernetes.cpu.usage.total{{{NS_SCOPE}}} by {{pod_name}}",
         f"avg:kubernetes.cpu.requests{{{NS_SCOPE}}} by {{pod_name}}"],
        "(q0 / q1) * 100"), 0, 0, 3, 2),
    placed(qv_formula("Memory % of Requests",
        [f"avg:kubernetes.memory.working_set{{{NS_SCOPE}}}",
         f"avg:kubernetes.memory.requests{{{NS_SCOPE}}}"],
        "(q0 / q1) * 100"), 3, 0, 3, 2),
    placed(qv_formula("CPU % of Limits",
        [f"avg:kubernetes.cpu.usage.total{{{NS_SCOPE}}}",
         f"avg:kubernetes.cpu.limits{{{NS_SCOPE}}}"],
        "(q0 / q1) * 100"), 6, 0, 3, 2),
    placed(qv_formula("Memory % of Limits",
        [f"avg:kubernetes.memory.working_set{{{NS_SCOPE}}}",
         f"avg:kubernetes.memory.limits{{{NS_SCOPE}}}"],
        "(q0 / q1) * 100"), 9, 0, 3, 2),
]

# Row 3 — Observability Pipelines Worker throughput
row3_widgets = [
    placed(ts("OPW Events Processed (Flex Logs vs Standard)", [
        ts_req(f"sum:vector.processed_events_total{{{SCOPE},component_id:flex_logs_sink}}.as_rate()", "Flex Logs", "purple"),
        ts_req(f"sum:vector.processed_events_total{{{SCOPE},component_id:standard_index_sink}}.as_rate()", "Standard Index", "orange"),
    ]), 0, 0, 12, 3),
]

# Row 4 — stock-backend APM
row4_widgets = [
    placed(qv_single("Req Rate (rps)",
        f"sum:trace.http.request.hits{{{SCOPE},service:stock-backend}}.as_rate()"), 0, 0, 3, 2),
    placed(qv_formula("Error Rate %",
        [f"sum:trace.http.request.errors{{{SCOPE},service:stock-backend}}.as_rate()",
         f"sum:trace.http.request.hits{{{SCOPE},service:stock-backend}}.as_rate()"],
        "(q0 / q1) * 100"), 3, 0, 3, 2),
    placed(ts("Request Rate & Errors", [
        ts_req(f"sum:trace.http.request.hits{{{SCOPE},service:stock-backend}}.as_rate()", "hits", "blue"),
        ts_req(f"sum:trace.http.request.errors{{{SCOPE},service:stock-backend}}.as_rate()", "errors", "red"),
    ]), 6, 0, 6, 2),
]

WIDGETS = [
    group("EKS Nodes (Karpenter)", row1_widgets, x=0, y=0, w=12, h=4),
    group("Pod Resource Utilisation — stock-demo", row2_widgets, x=0, y=4, w=12, h=4),
    group("Observability Pipelines Worker", row3_widgets, x=0, y=8, w=12, h=5),
    group("stock-backend APM", row4_widgets, x=0, y=13, w=12, h=4),
]

# ── Create dashboard ──────────────────────────────────────────────────────────

configuration = Configuration()
configuration.api_key["apiKeyAuth"] = os.environ["DD_API_KEY"]
configuration.api_key["appKeyAuth"] = os.environ["DD_APP_KEY"]

body = Dashboard(
    title=f"EKS Stock App — {CLUSTER}",
    description="EKS node management, pod utilisation, OPW throughput, and APM for the stock-demo app.",
    layout_type=DashboardLayoutType("free"),
    tags=["team:semea", "cluster:semea-eks-vicma"],
    widgets=WIDGETS,
)

with ApiClient(configuration) as api_client:
    api_instance = DashboardsApi(api_client)
    result = api_instance.create_dashboard(body)
    print(f"Dashboard created: https://app.datadoghq.com/dashboard/{result.id}")
    print(f"Dashboard ID: {result.id}")
