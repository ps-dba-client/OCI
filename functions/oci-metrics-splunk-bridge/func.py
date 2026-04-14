"""
OCI Monitoring → Splunk Observability (metrics) + Splunk Cloud (logs via HEC).

Trace / log correlation
-----------------------
This function relies on Splunk OpenTelemetry *auto* instrumentation (opentelemetry-instrument +
Splunk distro) so that
outbound HTTP (requests) and the logging pipeline participate in the same trace as much as
possible without manual span creation.

Every log record includes trace_id and span_id (hex) when a valid span is active, so Splunk
searches can join:
  index=* trace_id=<id>        (logs)
  traces for the same trace_id (Splunk Observability / APM)

Do not log secrets or raw metric payloads at INFO in production (cardinality / data volume).
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import oci
import requests
from fdk import response
from oci.monitoring import MonitoringClient
from oci.monitoring.models import ListMetricsDetails, SummarizeMetricsDataDetails
from opentelemetry import trace


def _region_from_env() -> str:
    raw = os.environ.get("OCI_REGION_METADATA", "")
    if raw:
        try:
            meta = json.loads(raw)
            return meta.get("regionName") or meta.get("region") or ""
        except json.JSONDecodeError:
            pass
    return os.environ.get("REGION", "") or os.environ.get("OCI_REGION", "") or "us-ashburn-1"


class TraceContextFilter(logging.Filter):
    """Inject trace_id / span_id on each LogRecord for Splunk correlation."""

    def filter(self, record: logging.LogRecord) -> bool:
        span = trace.get_current_span()
        ctx = span.get_span_context() if span is not None else None
        if ctx is not None and ctx.is_valid:
            record.trace_id = format(ctx.trace_id, "032x")
            record.span_id = format(ctx.span_id, "016x")
        else:
            record.trace_id = ""
            record.span_id = ""
        return True


_log_configured = False


def setup_logging() -> logging.Logger:
    global _log_configured
    log = logging.getLogger("oci_metrics_bridge")
    if _log_configured:
        return log
    log.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    if not log.handlers:
        h = logging.StreamHandler(sys.stdout)
        h.setLevel(logging.DEBUG)
        h.addFilter(TraceContextFilter())
        fmt = logging.Formatter(
            "%(asctime)s %(levelname)s trace_id=%(trace_id)s span_id=%(span_id)s %(message)s"
        )
        h.setFormatter(fmt)
        log.addHandler(h)
    _log_configured = True
    return log


def _hec_verify() -> bool:
    return os.environ.get("SPLUNK_HEC_INSECURE_SKIP_VERIFY", "").lower() not in ("1", "true", "yes")


def send_hec_event(
    log: logging.Logger,
    message: str,
    level: str = "INFO",
    extra_fields: Optional[Dict[str, Any]] = None,
) -> None:
    """Send one structured event to Splunk Cloud HEC (Event collector)."""
    url = os.environ.get("SPLUNK_HEC_URL", "").strip()
    token = os.environ.get("SPLUNK_HEC_TOKEN", "").strip()
    if not url or not token:
        log.warning("HEC URL or token not set; skipping HEC log")
        return

    span = trace.get_current_span()
    ctx = span.get_span_context() if span is not None else None
    trace_id = format(ctx.trace_id, "032x") if ctx and ctx.is_valid else ""
    span_id = format(ctx.span_id, "016x") if ctx and ctx.is_valid else ""

    fields: Dict[str, Any] = {
        "level": level,
        "trace_id": trace_id,
        "span_id": span_id,
        "component": "oci-metrics-splunk-bridge",
    }
    if extra_fields:
        fields.update(extra_fields)

    body = {
        "time": int(time.time()),
        "host": "oci-fn-oci-metrics-splunk-bridge",
        "source": os.environ.get("SPLUNK_HEC_SOURCE", "oci:metrics-bridge"),
        "sourcetype": "oci:metrics-bridge:json",
        "index": os.environ.get("SPLUNK_HEC_INDEX", "main"),
        "event": message,
        "fields": fields,
    }

    try:
        r = requests.post(
            url,
            headers={"Authorization": f"Splunk {token}"},
            json=body,
            timeout=15,
            verify=_hec_verify(),
        )
        if r.status_code >= 300:
            log.error("HEC post failed status=%s body=%s", r.status_code, r.text[:500])
    except Exception:
        log.exception("HEC post raised")


def _build_query(metric_name: str, dimensions: Dict[str, str], window: str) -> str:
    if dimensions:
        dim_pairs = ",".join(f'{k}="{v}"' for k, v in dimensions.items())
        return f"{metric_name}[{window}]{{{dim_pairs}}}.mean()"
    return f"{metric_name}[{window}].mean()"


def _send_signalfx_gauges(
    log: logging.Logger,
    realm: str,
    token: str,
    gauges: List[Dict[str, Any]],
) -> None:
    if not gauges:
        return
    url = f"https://ingest.{realm}.signalfx.com/v2/datapoint"
    # requests is auto-instrumented when splunk-instrument wraps the process
    r = requests.post(
        url,
        headers={"X-SF-Token": token, "Content-Type": "application/json"},
        data=json.dumps({"gauge": gauges}),
        timeout=30,
    )
    if r.status_code >= 300:
        log.error("SignalFx ingest failed status=%s body=%s", r.status_code, r.text[:800])
        raise RuntimeError(f"SignalFx ingest HTTP {r.status_code}")


def collect_and_forward(log: logging.Logger) -> int:
    compartment = os.environ.get("METRICS_COMPARTMENT_OCID", "").strip()
    if not compartment:
        raise ValueError("METRICS_COMPARTMENT_OCID is not set")

    realm = os.environ.get("SPLUNK_REALM", "us1").strip()
    token = os.environ.get("SPLUNK_ACCESS_TOKEN", "").strip()
    if not token:
        raise ValueError("SPLUNK_ACCESS_TOKEN is not set")

    max_metrics = int(os.environ.get("MAX_METRICS_PER_INVOKE", "75"))
    window_min = int(os.environ.get("OCI_METRICS_WINDOW_MINUTES", "5"))
    window = f"{window_min}m"

    signer = oci.auth.signers.get_resource_principals_signer()
    region = getattr(signer, "region", None) or _region_from_env()
    client = MonitoringClient(config={"region": region}, signer=signer, timeout=(10, 60))

    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=window_min)
    start_s = start.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    end_s = end.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    log.info(
        "Starting OCI metrics collection compartment=%s region=%s window=%s max_metrics=%s",
        compartment,
        region,
        window,
        max_metrics,
    )
    send_hec_event(
        log,
        "metrics collection started",
        extra_fields={"compartment_id": compartment, "region": region},
    )

    details = ListMetricsDetails()
    metrics_seen = 0
    gauges: List[Dict[str, Any]] = []
    opc_next_page: Optional[str] = None
    in_subtree = os.environ.get("LIST_METRICS_IN_SUBTREE", "false").strip().lower() in (
        "1",
        "true",
        "yes",
    )

    while metrics_seen < max_metrics:
        kwargs: Dict[str, Any] = {
            "compartment_id": compartment,
            "list_metrics_details": details,
        }
        if in_subtree:
            kwargs["compartment_id_in_subtree"] = True
        if opc_next_page:
            kwargs["page"] = opc_next_page

        try:
            lm = client.list_metrics(**kwargs)
        except oci.exceptions.ServiceError as e:
            log.error("list_metrics ServiceError code=%s message=%s", e.code, e.message)
            send_hec_event(
                log,
                f"list_metrics failed: {e.message}",
                level="ERROR",
                extra_fields={"oci_code": e.code},
            )
            raise

        items = lm.data or []
        if not items:
            log.info("list_metrics returned no items on this page")
            break

        for item in items:
            if metrics_seen >= max_metrics:
                break
            metrics_seen += 1
            name = item.name
            ns = item.namespace
            dims = dict(item.dimensions or {})

            query = _build_query(name, dims, window)
            try:
                sm = client.summarize_metrics_data(
                    compartment_id=compartment,
                    summarize_metrics_data_details=SummarizeMetricsDataDetails(
                        namespace=ns,
                        query=query,
                        start_time=start_s,
                        end_time=end_s,
                    ),
                )
            except oci.exceptions.ServiceError as e:
                log.warning(
                    "summarize failed for metric=%s ns=%s code=%s msg=%s",
                    name,
                    ns,
                    e.code,
                    e.message,
                )
                continue
            except Exception:
                log.exception("summarize unexpected error metric=%s ns=%s", name, ns)
                continue

            for series in sm.data or []:
                for dp in series.aggregated_datapoints or []:
                    if getattr(dp, "timestamp", None):
                        ts = dp.timestamp
                        if isinstance(ts, datetime):
                            ts_ms = int(ts.timestamp() * 1000)
                        else:
                            ts_ms = int(time.time() * 1000)
                    else:
                        ts_ms = int(time.time() * 1000)
                    try:
                        val = float(dp.value)
                    except (TypeError, ValueError):
                        continue
                    metric_key = f"oci.{ns.replace('/', '.')}.{name}"
                    sf_dims = {
                        **{k: str(v) for k, v in dims.items()},
                        "oci_namespace": str(ns),
                        "metric_name": str(name),
                    }
                    gauges.append(
                        {
                            "metric": metric_key,
                            "dimensions": sf_dims,
                            "value": val,
                            "timestamp": ts_ms,
                        }
                    )

            # batch to limit request size
            if len(gauges) >= 100:
                _send_signalfx_gauges(log, realm, token, gauges)
                gauges.clear()

        opc_next_page = lm.next_page
        if not opc_next_page:
            break

    if gauges:
        _send_signalfx_gauges(log, realm, token, gauges)

    log.info("Finished metrics collection processed_definitions=%s", metrics_seen)
    send_hec_event(
        log,
        "metrics collection finished",
        extra_fields={"processed_metric_definitions": metrics_seen},
    )
    return metrics_seen


def handler(ctx, data=None):
    log = setup_logging()
    try:
        processed = collect_and_forward(log)
        body = {"status": "ok", "processed_metric_definitions": processed}
        return response.Response(
            ctx,
            response_data=json.dumps(body),
            headers={"Content-Type": "application/json"},
        )
    except Exception as e:
        log.exception("handler failure: %s", e)
        try:
            send_hec_event(
                log,
                f"handler failure: {e}",
                level="ERROR",
                extra_fields={"error_type": type(e).__name__},
            )
        except Exception:
            log.exception("secondary failure sending HEC error event")
        return response.Response(
            ctx,
            response_data=json.dumps({"status": "error", "message": str(e)}),
            headers={"Content-Type": "application/json"},
            status_code=500,
        )


