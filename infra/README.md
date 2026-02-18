# Local Infrastructure Stack
**SQL Server → Kafka (CDC) → OpenSearch → FastAPI + Prometheus + Grafana**

---

## Quick Start

```bash
# 1. Fill in your passwords
cp .env.example .env
nano .env

# 2. Fix OpenSearch kernel requirement (Linux only — run once)
sudo sysctl -w vm.max_map_count=262144

# 3. Start everything
chmod +x setup.sh test.sh
./setup.sh start

# 4. Verify all services are healthy
./setup.sh status

# 5. Run tests
./test.sh
```

---

## Folder Structure

```
.
├── docker-compose.yml
├── .env.example              ← copy to .env, fill in passwords
├── .gitignore
├── setup.sh                  ← start / stop / debug tool
├── test.sh                   ← automated test suite
│
├── api/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── api.py                ← FastAPI: /health /search /metrics /docs
│
├── indexer/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── indexer.py            ← Kafka CDC consumer → OpenSearch
│
├── sql/
│   └── init/
│       └── V1__init_cdc.sql  ← auto-runs on first SQL Server start
│
├── opensearch/
│   ├── config/
│   │   └── opensearch.yml
│   └── mappings/
│       ├── profiles.json     ← auto-created on startup by opensearch-init
│       └── users.json
│
└── monitoring/
    ├── prometheus.yml         ← scrape targets
    ├── alerts.yml             ← alert rules
    └── grafana/
        └── provisioning/
            ├── datasources/
            │   └── datasources.yml   ← auto-wires Prometheus → Grafana
            └── dashboards/
                └── dashboards.yml    ← auto-loads dashboard JSON files
```

---

## Service URLs

| Service               | URL                            |
|-----------------------|--------------------------------|
| FastAPI               | http://localhost:8000          |
| FastAPI Swagger Docs  | http://localhost:8000/docs     |
| FastAPI Metrics       | http://localhost:8000/metrics  |
| OpenSearch            | http://localhost:9200          |
| OpenSearch Dashboards | http://localhost:5601          |
| Debezium REST API     | http://localhost:8083          |
| Kafka (host access)   | localhost:29092                |
| Prometheus            | http://localhost:9090          |
| Grafana               | http://localhost:3000          |
| Node Exporter         | http://localhost:9100/metrics  |
| Kafka Exporter        | http://localhost:9308/metrics  |

---

## Grafana Dashboard IDs (import via UI)

| Dashboard          | ID   |
|--------------------|------|
| Node Exporter Full | 1860 |
| Kafka Overview     | 7589 |
| OpenSearch         | 12297|

Go to Grafana → Dashboards → Import → paste ID → Load

---

## Useful Commands

```bash
# All-in-one diagnostic
./setup.sh debug

# Follow logs for any service
./setup.sh logs api
./setup.sh logs indexer
./setup.sh logs debezium

# Debezium connector + consumer lag
./setup.sh connector

# Run full end-to-end pipeline test
./test.sh pipeline

# OpenSearch cluster health
curl http://localhost:9200/_cluster/health?pretty

# Kafka consumer lag
docker exec kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --group opensearch-indexer

# Restart failed Debezium task
curl -X POST http://localhost:8083/connectors/sqlserver-cdc-connector/tasks/0/restart

# Hot-reload Prometheus config (no restart needed)
curl -X POST http://localhost:9090/-/reload

# Full reset (WARNING: deletes all data)
./setup.sh reset
```

---

## Troubleshooting

| Error | Fix |
|-------|-----|
| OpenSearch fails to start | `sudo sysctl -w vm.max_map_count=262144` |
| `SA_PASSWORD` blank warning | Edit `.env` before running `docker compose up` |
| Debezium task FAILED | CDC not enabled — check `docker compose logs debezium-init` |
| Kafka consumer lag growing | `docker compose logs indexer` |
| Grafana "No data" | Check http://localhost:9090/targets |
| Port 9092 refused from host | Use port `29092` from host machine |
