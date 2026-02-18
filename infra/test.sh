#!/usr/bin/env bash
# =============================================================================
# test.sh — End-to-end service validation
# Usage:
#   ./test.sh              all suites
#   ./test.sh sqlserver    SQL Server only
#   ./test.sh kafka        Kafka only
#   ./test.sh opensearch   OpenSearch only
#   ./test.sh debezium     Debezium only
#   ./test.sh api          FastAPI only
#   ./test.sh monitoring   Prometheus + Grafana only
#   ./test.sh pipeline     Full end-to-end CDC pipeline
#   ./test.sh --verbose    Show full response bodies
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SA_PASSWORD="${SA_PASSWORD:-YourStrong!Passw0rd}"
DB_NAME="${DB_NAME:-YourDatabase}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
VERBOSE=false
[[ "${*}" == *"--verbose"* ]] && VERBOSE=true

PASS=0; FAIL=0; WARN=0; FAILED_TESTS=()

log_section() { echo -e "\n${BOLD}${BLUE}╔══ $1 ══${NC}"; }
log_test()    { echo -e "\n${CYAN}  ▶ $1${NC}"; }
pass()  { echo -e "    ${GREEN}✔ PASS: $1${NC}"; ((PASS++)); }
fail()  { echo -e "    ${RED}✘ FAIL: $1${NC}"; ((FAIL++)); FAILED_TESTS+=("$1"); }
warn()  { echo -e "    ${YELLOW}⚠ WARN: $1${NC}"; ((WARN++)); }
info()  { echo -e "    ℹ $1"; }

http_get()      { curl -sf --max-time 10 "$1" 2>/dev/null; }
http_get_code() { curl -s  --max-time 10 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null; }
http_post()     { curl -sf --max-time 15 -X POST "$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null; }

# =============================================================================
test_sqlserver() {
  log_section "SQL SERVER"

  log_test "Port reachability :1433"
  nc -z -w5 localhost 1433 2>/dev/null && pass "Port 1433 open" || { fail "Port 1433 not reachable"; return; }

  log_test "SA login"
  R=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -No \
      -Q "SET NOCOUNT ON; SELECT @@VERSION" 2>/dev/null | head -2 | tail -1 || echo "")
  echo "$R" | grep -qi "microsoft sql server" && pass "SA login OK: $(echo "$R" | cut -c1-60)" || fail "SA login failed — check SA_PASSWORD in .env"

  log_test "Database '${DB_NAME}' exists"
  R=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -No \
      -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name='${DB_NAME}'" 2>/dev/null | grep -v "^$" | tail -1 || echo "")
  echo "$R" | grep -q "$DB_NAME" && pass "Database found" || fail "Database not found — run V1__init_cdc.sql"

  log_test "CDC enabled"
  R=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -No \
      -Q "SET NOCOUNT ON; SELECT is_cdc_enabled FROM sys.databases WHERE name='${DB_NAME}'" 2>/dev/null | grep -v "^$" | tail -1 | tr -d ' ' || echo "0")
  [ "$R" = "1" ] && pass "CDC enabled" || fail "CDC not enabled — run EXEC sys.sp_cdc_enable_db"

  log_test "CDC capture tables"
  R=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -No \
      -d "$DB_NAME" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cdc.change_tables" 2>/dev/null | grep -v "^$" | tail -1 | tr -d ' ' || echo "0")
  [ "${R:-0}" -gt 0 ] && pass "${R} CDC table(s) registered" || fail "No CDC tables — run sp_cdc_enable_table"
}

# =============================================================================
test_kafka() {
  log_section "KAFKA"

  log_test "Port reachability :29092"
  nc -z -w5 localhost 29092 2>/dev/null && pass "Port 29092 open" || { fail "Port 29092 not reachable"; return; }

  log_test "List topics"
  TOPICS=$(docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list 2>/dev/null || echo "")
  [ -n "$TOPICS" ] && pass "Topics listed ($(echo "$TOPICS" | wc -l) total)" || { fail "Cannot list topics"; return; }

  log_test "Debezium internal topics"
  MISSING=""
  for t in connect-configs connect-offsets connect-statuses; do
    echo "$TOPICS" | grep -q "^${t}$" || MISSING="$MISSING $t"
  done
  [ -z "$MISSING" ] && pass "All internal topics present" || fail "Missing:$MISSING — re-run: docker compose up kafka-init"

  log_test "Produce/consume round-trip"
  MSG="test-$(date +%s)"
  docker exec kafka kafka-topics --bootstrap-server localhost:9092 --create --if-not-exists \
    --topic infra-test --partitions 1 --replication-factor 1 2>/dev/null || true
  echo "$MSG" | docker exec -i kafka kafka-console-producer --broker-list localhost:9092 --topic infra-test 2>/dev/null
  OUT=$(docker exec kafka kafka-console-consumer --bootstrap-server localhost:9092 \
    --topic infra-test --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null | head -1 || echo "")
  echo "$OUT" | grep -q "test-" && pass "Round-trip OK" || fail "Produce/consume failed"

  log_test "Kafka Exporter metrics"
  http_get "http://localhost:9308/metrics" | grep -q "kafka_brokers" \
    && pass "Kafka Exporter serving metrics" || fail "Kafka Exporter not returning metrics"
}

# =============================================================================
test_opensearch() {
  log_section "OPENSEARCH"

  log_test "HTTP reachability :9200"
  R=$(http_get "http://localhost:9200" || echo "")
  echo "$R" | grep -q "cluster_name" && pass "OpenSearch responding" || { fail "Not reachable"; return; }

  log_test "Cluster health"
  STATUS=$(http_get "http://localhost:9200/_cluster/health" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")
  case "$STATUS" in
    green)  pass "Cluster: GREEN" ;;
    yellow) warn "Cluster: YELLOW (normal on single-node)" ;;
    red)    fail "Cluster: RED — check /_cluster/allocation/explain" ;;
    *)      fail "Cannot determine health" ;;
  esac

  log_test "Index 'profiles' exists"
  CODE=$(http_get_code "http://localhost:9200/profiles")
  if [ "$CODE" = "200" ]; then
    COUNT=$(http_get "http://localhost:9200/profiles/_count" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "?")
    pass "Index exists (docs: $COUNT)"
  else
    fail "Index not found (HTTP $CODE) — check opensearch-init logs"
  fi

  log_test "Index/search round-trip"
  http_post "http://localhost:9200/profiles/_doc/test-roundtrip" \
    '{"id":"test-roundtrip","name":"Infra Test","email":"infra@test.local","status":"active","created_at":"2024-01-01T00:00:00Z"}' > /dev/null
  sleep 2
  HITS=$(http_get "http://localhost:9200/profiles/_search?q=Infra+Test&size=1" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "0")
  [ "${HITS:-0}" -gt 0 ] && pass "Index/search round-trip OK ($HITS hit(s))" || fail "Search returned 0 hits"
  curl -sf -X DELETE "http://localhost:9200/profiles/_doc/test-roundtrip" > /dev/null 2>&1 || true

  log_test "Performance Analyzer :9600"
  CODE=$(http_get_code "http://localhost:9600/_plugins/_performanceanalyzer/metrics")
  [ "$CODE" = "200" ] && pass "Performance Analyzer active" || warn "PA returned HTTP $CODE"

  log_test "OpenSearch Dashboards :5601"
  CODE=$(http_get_code "http://localhost:5601/api/status")
  [ "$CODE" = "200" ] && pass "Dashboards reachable" || warn "Dashboards returned HTTP $CODE"
}

# =============================================================================
test_debezium() {
  log_section "DEBEZIUM"

  log_test "REST API :8083"
  R=$(http_get "http://localhost:8083/" || echo "")
  echo "$R" | grep -q "version" && pass "Debezium reachable ($(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null))" || { fail "Not reachable"; return; }

  log_test "Connector registered"
  CONNECTORS=$(http_get "http://localhost:8083/connectors" || echo "[]")
  echo "$CONNECTORS" | grep -q "sqlserver-cdc-connector" && pass "Connector registered" || fail "Not registered — check: docker compose logs debezium-init"

  log_test "Connector state"
  STATUS=$(http_get "http://localhost:8083/connectors/sqlserver-cdc-connector/status" || echo "")
  CONN=$(echo "$STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null || echo "UNKNOWN")
  TASK=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tasks'][0]['state'] if d.get('tasks') else 'NO_TASKS')" 2>/dev/null || echo "UNKNOWN")
  if [ "$CONN" = "RUNNING" ] && [ "$TASK" = "RUNNING" ]; then
    pass "Connector: RUNNING | Task: RUNNING"
  elif [ "$TASK" = "FAILED" ]; then
    fail "Task FAILED — restart: curl -X POST http://localhost:8083/connectors/sqlserver-cdc-connector/tasks/0/restart"
  else
    warn "Connector: $CONN | Task: $TASK"
  fi
}

# =============================================================================
test_api() {
  log_section "FASTAPI"

  log_test "Health endpoint"
  R=$(http_get "http://localhost:8000/health" || echo "")
  echo "$R" | grep -q '"ok"' && pass "Health OK (OS: $(echo "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('opensearch','?'))" 2>/dev/null))" || { fail "Health failed — docker compose logs api"; return; }

  log_test "Prometheus metrics endpoint"
  M=$(http_get "http://localhost:8000/metrics" || echo "")
  for metric in search_requests_total search_latency_seconds; do
    echo "$M" | grep -q "$metric" && info "  ✔ $metric" || { fail "Metric $metric missing"; }
  done
  echo "$M" | grep -q "search_requests_total" && pass "Metrics endpoint OK" || true

  log_test "Search endpoint"
  CODE=$(http_get_code "http://localhost:8000/search?q=test")
  R=$(http_get "http://localhost:8000/search?q=test" || echo "")
  [ "$CODE" = "200" ] && echo "$R" | grep -q '"total"' && pass "Search returns HTTP 200 with total field" || fail "Search failed (HTTP $CODE)"

  log_test "Latency — 5 requests under 500ms"
  OVER=0
  for i in $(seq 1 5); do
    MS=$(curl -sf --max-time 2 -o /dev/null -w "%{time_total}" "http://localhost:8000/search?q=latency_test" 2>/dev/null || echo "2")
    MS_INT=$(echo "$MS * 1000" | bc 2>/dev/null | cut -d. -f1 || echo "2000")
    [ "${MS_INT:-2000}" -gt 500 ] && ((OVER++))
  done
  [ "$OVER" -eq 0 ] && pass "All 5 requests under 500ms" || warn "$OVER/5 requests exceeded 500ms"
}

# =============================================================================
test_monitoring() {
  log_section "MONITORING"

  log_test "Prometheus health"
  http_get "http://localhost:9090/-/healthy" | grep -qi "healthy" && pass "Prometheus healthy" || { fail "Prometheus not healthy"; return; }

  log_test "All scrape targets UP"
  TARGETS=$(http_get "http://localhost:9090/api/v1/targets" || echo "")
  UP=$(echo "$TARGETS"   | python3 -c "import sys,json; print(sum(1 for t in json.load(sys.stdin)['data']['activeTargets'] if t['health']=='up'))" 2>/dev/null || echo "0")
  DOWN=$(echo "$TARGETS" | python3 -c "import sys,json; print(sum(1 for t in json.load(sys.stdin)['data']['activeTargets'] if t['health']!='up'))" 2>/dev/null || echo "?")
  TOTAL=$(echo "$TARGETS"| python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['activeTargets']))" 2>/dev/null || echo "?")
  [ "${DOWN}" = "0" ] && pass "All ${TOTAL} targets UP" || fail "${DOWN}/${TOTAL} targets DOWN — check http://localhost:9090/targets"

  log_test "Alert rules loaded"
  RULES=$(http_get "http://localhost:9090/api/v1/rules" || echo "")
  COUNT=$(echo "$RULES" | python3 -c "import sys,json; print(sum(len(g['rules']) for g in json.load(sys.stdin).get('data',{}).get('groups',[])))" 2>/dev/null || echo "0")
  [ "${COUNT:-0}" -gt 0 ] && pass "${COUNT} alert rules loaded" || warn "No alert rules — check alerts.yml mount"

  log_test "Grafana health"
  http_get "http://localhost:3000/api/health" | grep -q '"ok"' && pass "Grafana healthy" || { fail "Grafana not healthy"; return; }

  log_test "Grafana Prometheus datasource"
  DS=$(curl -sf --max-time 10 -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "http://localhost:3000/api/datasources" 2>/dev/null || echo "[]")
  echo "$DS" | grep -qi "prometheus" && pass "Prometheus datasource configured" || fail "No Prometheus datasource — check datasources.yml"

  log_test "Node Exporter metrics"
  http_get "http://localhost:9100/metrics" | grep -q "node_cpu_seconds_total" && pass "Node Exporter OK" || fail "Node Exporter not serving metrics"
}

# =============================================================================
test_pipeline() {
  log_section "END-TO-END PIPELINE: SQL → CDC → Kafka → OpenSearch → API"

  ID="e2e-$(date +%s)"
  EMAIL="${ID}@pipeline.test"
  NAME="Pipeline Test ${ID}"

  log_test "STEP 1 — INSERT into SQL Server"
  R=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -No -d "$DB_NAME" \
      -Q "SET NOCOUNT ON; INSERT INTO dbo.profiles (name,email,bio,status) VALUES ('${NAME}','${EMAIL}','e2e test','active'); SELECT @@ROWCOUNT" \
      2>/dev/null | grep -v "^$" | tail -1 | tr -d ' ' || echo "0")
  [ "$R" = "1" ] && pass "Row inserted" || { fail "INSERT failed"; return; }

  log_test "STEP 2 — CDC captures the INSERT"
  for i in $(seq 1 6); do
    C=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -No -d "$DB_NAME" \
        -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cdc.dbo_profiles_CT WHERE email='${EMAIL}'" \
        2>/dev/null | grep -v "^$" | tail -1 | tr -d ' ' || echo "0")
    [ "${C:-0}" -gt 0 ] && break
    sleep 2
  done
  [ "${C:-0}" -gt 0 ] && pass "CDC captured INSERT" || fail "CDC did not capture — check SQL Agent"

  log_test "STEP 3 — Kafka receives CDC event"
  MSG=$(docker exec kafka kafka-console-consumer --bootstrap-server localhost:9092 \
        --topic cdc.dbo.profiles --from-beginning --max-messages 100 --timeout-ms 15000 \
        2>/dev/null | grep "$EMAIL" | head -1 || echo "")
  [ -n "$MSG" ] && pass "Event found in Kafka topic" || fail "Event not in Kafka — check Debezium connector"

  log_test "STEP 4 — OpenSearch indexes the document"
  for i in $(seq 1 10); do
    HITS=$(http_get "http://localhost:9200/profiles/_search?q=${EMAIL}&size=1" | \
           python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "0")
    [ "${HITS:-0}" -gt 0 ] && break
    sleep 3
  done
  [ "${HITS:-0}" -gt 0 ] && pass "Document in OpenSearch" || fail "Not indexed — check: docker compose logs indexer"

  log_test "STEP 5 — API /search returns the document"
  TOTAL=$(http_get "http://localhost:8000/search?q=$(echo "$NAME" | sed 's/ /+/g')" | \
          python3 -c "import sys,json; print(json.load(sys.stdin)['total'])" 2>/dev/null || echo "0")
  if [ "${TOTAL:-0}" -gt 0 ]; then
    pass "API returned $TOTAL hit(s)"
    echo ""
    echo -e "  ${GREEN}${BOLD}✅  ALL 5 PIPELINE STEPS PASSED${NC}"
    echo -e "  ${GREEN}SQL Server → CDC → Kafka → OpenSearch → API ✔${NC}"
  else
    fail "API returned 0 hits"
  fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║          TEST SUMMARY                ║${NC}"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  ${GREEN}PASSED : ${PASS}${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  ${RED}FAILED : ${FAIL}${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  ${YELLOW}WARNED : ${WARN}${NC}"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════╣${NC}"
  if [ "$FAIL" -eq 0 ]; then
    echo -e "${BOLD}${BLUE}║${NC}  ${GREEN}${BOLD}RESULT : ALL TESTS PASSED ✅${NC}"
  else
    echo -e "${BOLD}${BLUE}║${NC}  ${RED}${BOLD}RESULT : ${FAIL} FAILED ❌${NC}"
    echo ""
    echo -e "  ${RED}Failed:${NC}"
    for t in "${FAILED_TESTS[@]}"; do echo -e "    ${RED}✘ $t${NC}"; done
    echo ""
    echo -e "  ${CYAN}Debug: ./setup.sh debug${NC}"
  fi
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════╝${NC}"
  echo ""
}

FILTER="${1:-all}"
[[ "$FILTER" == "--verbose" ]] && FILTER="all"

echo -e "\n${BOLD}${BLUE}  Infrastructure Test Suite — $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

case "$FILTER" in
  sqlserver)  test_sqlserver ;;
  kafka)      test_kafka ;;
  opensearch) test_opensearch ;;
  debezium)   test_debezium ;;
  api)        test_api ;;
  monitoring) test_monitoring ;;
  pipeline)   test_pipeline ;;
  all)
    test_sqlserver
    test_kafka
    test_opensearch
    test_debezium
    test_api
    test_monitoring
    test_pipeline
    ;;
  *) echo "Usage: $0 [sqlserver|kafka|opensearch|debezium|api|monitoring|pipeline|all]"; exit 1 ;;
esac

print_summary
[ "$FAIL" -eq 0 ]
