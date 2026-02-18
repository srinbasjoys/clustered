"""
indexer.py — Kafka CDC consumer → OpenSearch indexer

Reads Debezium CDC events from Kafka and keeps OpenSearch in sync.
  op c / u / r  →  index (upsert) document
  op d          →  delete document
"""
import json
import logging
import os
import signal
import sys
import time

from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable
from opensearchpy import OpenSearch, NotFoundError

# ── Config ────────────────────────────────────────────────────────────────────
KAFKA_BOOTSTRAP   = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
KAFKA_GROUP_ID    = os.getenv("KAFKA_GROUP_ID",          "opensearch-indexer")
KAFKA_TOPICS      = os.getenv("KAFKA_TOPICS",            "cdc.dbo.profiles").split(",")
KAFKA_AUTO_OFFSET = os.getenv("KAFKA_AUTO_OFFSET_RESET", "earliest")
OPENSEARCH_HOST   = os.getenv("OPENSEARCH_HOST",         "http://opensearch:9200")
LOG_LEVEL         = os.getenv("LOG_LEVEL",               "INFO").upper()

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("indexer")

# ── Graceful shutdown ─────────────────────────────────────────────────────────
RUNNING = True

def handle_signal(sig, _):
    global RUNNING
    log.info(f"Signal {sig} received — shutting down gracefully...")
    RUNNING = False

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT,  handle_signal)


def topic_to_index(topic: str) -> str:
    """cdc.dbo.profiles → profiles"""
    return topic.split(".")[-1].lower()


def transform(payload: dict):
    """Returns (operation, doc_id, body) — operation is 'index', 'delete', or 'skip'."""
    op     = payload.get("op", "")
    after  = payload.get("after")
    before = payload.get("before")

    if op in ("c", "u", "r") and after:
        doc_id = str(after.get("id", after.get("Id", "")))
        return "index", doc_id, after

    if op == "d" and before:
        doc_id = str(before.get("id", before.get("Id", "")))
        return "delete", doc_id, None

    return "skip", "", None


def make_os_client() -> OpenSearch:
    return OpenSearch(
        hosts=[OPENSEARCH_HOST],
        http_compress=True,
        timeout=30,
        max_retries=3,
        retry_on_timeout=True,
    )


def make_consumer(retries: int = 10, delay: int = 6) -> KafkaConsumer:
    for attempt in range(1, retries + 1):
        try:
            log.info(f"Connecting to Kafka ({KAFKA_BOOTSTRAP}) attempt {attempt}/{retries}...")
            consumer = KafkaConsumer(
                *KAFKA_TOPICS,
                bootstrap_servers=KAFKA_BOOTSTRAP.split(","),
                group_id=KAFKA_GROUP_ID,
                auto_offset_reset=KAFKA_AUTO_OFFSET,
                enable_auto_commit=False,       # manual commit = at-least-once delivery
                value_deserializer=lambda m: json.loads(m.decode("utf-8")) if m else None,
                consumer_timeout_ms=5000,       # unblocks loop so SIGTERM is handled
                session_timeout_ms=30000,
                heartbeat_interval_ms=10000,
                max_poll_records=500,
            )
            log.info(f"Connected to Kafka. Topics: {KAFKA_TOPICS}")
            return consumer
        except NoBrokersAvailable:
            if attempt == retries:
                raise
            log.warning(f"Kafka not ready — retrying in {delay}s...")
            time.sleep(delay)


def main():
    log.info("Indexer starting up")
    log.info(f"  Kafka        : {KAFKA_BOOTSTRAP}")
    log.info(f"  Topics       : {KAFKA_TOPICS}")
    log.info(f"  Group        : {KAFKA_GROUP_ID}")
    log.info(f"  OpenSearch   : {OPENSEARCH_HOST}")

    os_client = make_os_client()
    consumer  = make_consumer()

    indexed = deleted = errors = 0
    log.info("Indexer running — waiting for CDC events...")

    while RUNNING:
        try:
            for message in consumer:
                if not RUNNING:
                    break
                try:
                    value = message.value
                    if not value or "payload" not in value:
                        consumer.commit()
                        continue

                    index         = topic_to_index(message.topic)
                    op, doc_id, doc = transform(value["payload"])

                    if op == "skip" or not doc_id:
                        consumer.commit()
                        continue

                    if op == "index":
                        os_client.index(index=index, id=doc_id, body=doc)
                        indexed += 1
                        log.debug(f"Indexed  {index}/{doc_id}")

                    elif op == "delete":
                        try:
                            os_client.delete(index=index, id=doc_id)
                            deleted += 1
                            log.debug(f"Deleted  {index}/{doc_id}")
                        except NotFoundError:
                            pass

                    # Commit offset only AFTER successful processing
                    consumer.commit()

                    if (indexed + deleted) % 1000 == 0 and (indexed + deleted) > 0:
                        log.info(f"Stats — indexed:{indexed} deleted:{deleted} errors:{errors}")

                except Exception as e:
                    errors += 1
                    log.error(
                        f"Failed message topic={message.topic} "
                        f"partition={message.partition} offset={message.offset}: {e}"
                    )
                    # Do NOT commit — will retry on restart

        except Exception as e:
            if RUNNING:
                log.error(f"Consumer loop error: {e} — reconnecting in 5s...")
                time.sleep(5)

    log.info(f"Stopped — indexed:{indexed} deleted:{deleted} errors:{errors}")
    consumer.close()


if __name__ == "__main__":
    main()
