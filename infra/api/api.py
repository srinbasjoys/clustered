"""
api.py — FastAPI search service
  GET /         -> API info
  GET /health   -> service + OpenSearch health check
  GET /search   -> full-text search against OpenSearch
  GET /metrics  -> Prometheus metrics (scraped every 10s)
  GET /docs     -> Swagger UI
"""
import os
import time
import logging
import sys

from fastapi import FastAPI, HTTPException, Query
from opensearchpy import OpenSearch, ConnectionError as OSConnectionError
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

# ── Config ────────────────────────────────────────────────────────────────────
OPENSEARCH_HOST = os.getenv("OPENSEARCH_HOST", "http://opensearch:9200")
LOG_LEVEL       = os.getenv("LOG_LEVEL", "INFO").upper()
APP_ENV         = os.getenv("APP_ENV", "production")

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("api")

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Search API",
    version="1.0.0",
    description="OpenSearch-backed search API with Prometheus metrics",
    docs_url="/docs",
    redoc_url="/redoc",
)

# ── OpenSearch client ─────────────────────────────────────────────────────────
os_client = OpenSearch(
    hosts=[OPENSEARCH_HOST],
    http_compress=True,
    timeout=30,
    max_retries=3,
    retry_on_timeout=True,
)

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "search_requests_total",
    "Total search requests",
    ["status"],
)
REQUEST_LATENCY = Histogram(
    "search_latency_seconds",
    "Search latency in seconds",
    ["index"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)
ERROR_COUNT = Counter(
    "search_errors_total",
    "Search errors by type",
    ["error_type"],
)

# ── Request logging middleware ────────────────────────────────────────────────
class LoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start    = time.time()
        response = await call_next(request)
        log.info(
            f"{request.method} {request.url.path} "
            f"status={response.status_code} "
            f"duration={(time.time()-start)*1000:.1f}ms"
        )
        return response

app.add_middleware(LoggingMiddleware)

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
def root():
    return {
        "service": "Search API",
        "version": "1.0.0",
        "docs":    "/docs",
        "health":  "/health",
        "metrics": "/metrics",
    }


@app.get("/health", summary="Health check")
def health():
    """Returns service status and OpenSearch cluster info."""
    try:
        info    = os_client.info()
        cluster = os_client.cluster.health()
        return {
            "status":         "ok",
            "env":            APP_ENV,
            "opensearch":     info["version"]["number"],
            "cluster_status": cluster["status"],
            "cluster_name":   cluster["cluster_name"],
        }
    except OSConnectionError as e:
        log.error(f"OpenSearch unreachable: {e}")
        raise HTTPException(status_code=503, detail="OpenSearch is unreachable")
    except Exception as e:
        log.error(f"Health check failed: {e}")
        raise HTTPException(status_code=503, detail=str(e))


@app.get("/search", summary="Full-text search")
def search(
    q:     str = Query(...,    description="Search query string"),
    index: str = Query("profiles", description="OpenSearch index name"),
    size:  int = Query(10,     ge=1, le=100, description="Results per page"),
    from_: int = Query(0,      ge=0,         description="Pagination offset", alias="from"),
):
    """Full-text search with fuzzy matching, highlighting, and pagination."""
    start = time.time()
    try:
        result = os_client.search(
            index=index,
            body={
                "from": from_,
                "size": size,
                "query": {
                    "multi_match": {
                        "query":     q,
                        "fields":    ["name^2", "bio", "email", "tags"],
                        "fuzziness": "AUTO",
                    }
                },
                "highlight": {
                    "fields": {"name": {}, "bio": {}}
                },
            },
        )
        duration = time.time() - start
        REQUEST_COUNT.labels(status="success").inc()
        REQUEST_LATENCY.labels(index=index).observe(duration)
        return {
            "total": result["hits"]["total"]["value"],
            "from":  from_,
            "size":  size,
            "query": q,
            "hits":  result["hits"]["hits"],
        }
    except Exception as e:
        REQUEST_COUNT.labels(status="error").inc()
        ERROR_COUNT.labels(error_type=type(e).__name__).inc()
        log.error(f"Search failed q={q!r} index={index} error={e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/metrics", summary="Prometheus metrics")
def metrics():
    """Prometheus-format metrics endpoint — scraped by Prometheus every 15s."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
