#!/usr/bin/env bash
# =============================================================================
# setup.sh — Start / stop / debug the infrastructure stack
# Usage:
#   ./setup.sh start           Start all services
#   ./setup.sh stop            Stop all services
#   ./setup.sh reset           Destroy volumes and restart from scratch
#   ./setup.sh status          Show health of every container
#   ./setup.sh logs <service>  Follow logs (e.g. ./setup.sh logs api)
#   ./setup.sh debug           Full diagnostic report
#   ./setup.sh connector       Debezium connector status + consumer lag
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()  { echo -e "${GREEN}  ✔  $*${NC}"; }
warn(){ echo -e "${YELLOW}  ⚠  $*${NC}"; }
err() { echo -e "${RED}  ✘  $*${NC}"; }
hdr() { echo -e "\n${BOLD}${BLUE}══  $*${NC}"; }

CMD="${1:-status}"

check_prerequisites() {
  hdr "Prerequisites"
  command -v docker &>/dev/null && ok "docker found" || { err "docker not found"; exit 1; }

  if [ ! -f .env ]; then
    warn ".env not found — copying from .env.example"
    cp .env.example .env
    warn "Edit .env with your passwords before starting!"
  else
    ok ".env found"
  fi

  if [ -f /proc/sys/vm/max_map_count ]; then
    MAP=$(cat /proc/sys/vm/max_map_count)
    if [ "$MAP" -lt 262144 ]; then
      warn "vm.max_map_count=$MAP — fixing (requires sudo)..."
      sudo sysctl -w vm.max_map_count=262144
      ok "vm.max_map_count set to 262144"
    else
      ok "vm.max_map_count=$MAP"
    fi
  fi
}

show_status() {
  hdr "Container Status"
  printf "  %-28s %-12s %s\n" "SERVICE" "STATE" "HEALTH"
  printf "  %-28s %-12s %s\n" "────────────────────────────" "──────────" "────────────"
  SERVICES=(sqlserver zookeeper kafka kafka-init debezium opensearch opensearch-dashboards indexer api prometheus grafana node-exporter kafka-exporter)
  for svc in "${SERVICES[@]}"; do
    STATE=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$svc" 2>/dev/null || echo "—")
    if [ "$STATE" = "running" ] && [[ "$HEALTH" == "healthy" || "$HEALTH" == "—" ]]; then
      printf "  ${GREEN}%-28s %-12s %s${NC}\n" "$svc" "$STATE" "$HEALTH"
    elif [[ "$STATE" == "exited" || "$STATE" == "not found" ]]; then
      printf "  ${RED}%-28s %-12s %s${NC}\n" "$svc" "$STATE" "$HEALTH"
    else
      printf "  ${YELLOW}%-28s %-12s %s${NC}\n" "$svc" "$STATE" "$HEALTH"
    fi
  done
}

start_stack() {
  hdr "Starting Stack"
  check_prerequisites
  docker compose up --build -d
  echo ""
  echo "  Waiting for services to become healthy (~90s)..."
  sleep 15
  show_status
  hdr "Access URLs"
  echo "  FastAPI        → http://localhost:8000"
  echo "  FastAPI Docs   → http://localhost:8000/docs"
  echo "  OpenSearch     → http://localhost:9200"
  echo "  OS Dashboards  → http://localhost:5601"
  echo "  Debezium       → http://localhost:8083"
  echo "  Prometheus     → http://localhost:9090"
  echo "  Grafana        → http://localhost:3000"
  echo "  Kafka (host)   → localhost:29092"
}

run_debug() {
  hdr "FULL DIAGNOSTIC REPORT"
  show_status

  hdr "OpenSearch Cluster Health"
  curl -sf http://localhost:9200/_cluster/health?pretty 2>/dev/null || err "OpenSearch not reachable"

  hdr "OpenSearch Indices"
  curl -sf http://localhost:9200/_cat/indices?v 2>/dev/null || err "OpenSearch not reachable"

  hdr "Kafka Topics"
  docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null || err "Kafka not reachable"

  hdr "Debezium Connectors"
  curl -sf http://localhost:8083/connectors?expand=status 2>/dev/null | python3 -m json.tool || err "Debezium not reachable"

  hdr "Prometheus Targets"
  curl -sf http://localhost:9090/api/v1/targets 2>/dev/null | python3 -c "
import sys, json
for t in json.load(sys.stdin).get('data',{}).get('activeTargets',[]):
    mark = '✔' if t['health'] == 'up' else '✘'
    print(f'  {mark} [{t[\"health\"]:4s}] {t.get(\"labels\",{}).get(\"job\",\"?\"):20s} {t[\"scrapeUrl\"]}')
" 2>/dev/null || err "Prometheus not reachable"

  hdr "Container Resource Usage"
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null
}

check_connector() {
  hdr "Debezium Connector"
  curl -sf http://localhost:8083/connectors/sqlserver-cdc-connector/status \
    | python3 -m json.tool 2>/dev/null || warn "Connector not reachable"

  hdr "Kafka Consumer Lag"
  docker exec kafka kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --describe --group opensearch-indexer 2>/dev/null || warn "Cannot check consumer groups"
}

case "$CMD" in
  start)     start_stack ;;
  stop)      hdr "Stopping"; docker compose down ;;
  reset)     hdr "Resetting (deleting all volumes)"; docker compose down -v; start_stack ;;
  status)    show_status ;;
  logs)      docker compose logs -f --tail=100 "${2:-api}" ;;
  debug)     run_debug ;;
  connector) check_connector ;;
  *)
    echo "Usage: $0 {start|stop|reset|status|logs <svc>|debug|connector}"
    exit 1
    ;;
esac
