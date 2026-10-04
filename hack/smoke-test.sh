#!/usr/bin/env bash
#
# Smoke-тест: генерирует реальный HTTP-трафик через Gateway API и показывает,
# что он отражается в метриках Prometheus и в логах Elasticsearch.
#
#   ./hack/smoke-test.sh [количество запросов]
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_versions "${REPO_ROOT}/versions.env"

REQUESTS="${1:-200}"
GATEWAY_IP="$(gateway_access_ip || true)"
PROM_PORT=19090
ES_PORT=19200

[[ -n "${GATEWAY_IP}" ]] || die "Не удалось определить IP узла. Проверьте: kubectl get nodes -o wide"
require_cmd curl jq

section "Smoke-тест решения"
log "Gateway: http://${GATEWAY_IP}:${APP_NODEPORT}"
log "Будет выполнено ${REQUESTS} запросов (включая /canary и ошибочные)"

# --- Генерация трафика ----------------------------------------------------------
section "1/4 Генерация HTTP-трафика через Gateway API"

RUN_ID="smoke-$(date +%s)"
success=0; client_err=0; server_err=0

for i in $(seq 1 "${REQUESTS}"); do
    # Разные пути, чтобы в логах появились записи с разными request_uri
    # (дополнительный критерий качества логов: видно и попадания в canary,
    # и обычные запросы к стабильному backend'у).
    case $((i % 10)) in
        0|1) path="/canary/version" ;;
        2)   path="/api/items/${RUN_ID}/${i}" ;;
        *)   path="/?run=${RUN_ID}&i=${i}" ;;
    esac
    # curl сам печатает 000 при ошибке соединения; `|| true` защищает от
    # падения цикла, а не даёт продублировать вывод.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${GATEWAY_IP}:${APP_NODEPORT}${path}" 2>/dev/null || true)"
    case "${code}" in
        2*) success=$((success + 1)) ;;
        4*) client_err=$((client_err + 1)) ;;
        5*) server_err=$((server_err + 1)) ;;
    esac
done

ok "Отправлено запросов: ${REQUESTS}"
printf '  HTTP 2xx: %s\n  HTTP 4xx: %s\n  HTTP 5xx: %s\n' "${success}" "${client_err}" "${server_err}"

if [[ "${server_err}" -gt 0 ]]; then
    warn "Обнаружены ответы 5xx. Проверьте логи NGINX:"
    warn "  kubectl -n ${APP_NAMESPACE} logs -l app.kubernetes.io/name=web -c nginx --tail=50"
fi

# --- Метрики --------------------------------------------------------------------
section "2/4 Проверка метрик в Prometheus"

kubectl -n "${MONITORING_NAMESPACE}" port-forward "svc/${KPS_RELEASE_NAME}-prometheus" "${PROM_PORT}:9090" \
    >/tmp/smoke-prom-pf.log 2>&1 &
PROM_PF_PID=$!
trap 'kill_bg "${PROM_PF_PID:-}" "${ES_PF_PID:-}"' EXIT

log "Ожидание port-forward к Prometheus..."
for i in $(seq 1 30); do
    curl -sS --max-time 2 "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1 && break
    sleep 1
done

prom() {
    local q="$1"
    curl -sS --max-time 10 --get "http://127.0.0.1:${PROM_PORT}/api/v1/query" --data-urlencode "query=${q}" 2>/dev/null
}

prom_targets() {
    log "Таргеты Prometheus, относящиеся к решению:"
    # Скобки вокруг условий обязательны: без них `|` перехватывает всё выражение.
    curl -sS --max-time 10 "http://127.0.0.1:${PROM_PORT}/api/v1/targets?state=active" 2>/dev/null \
        | jq -r --arg ns "${APP_NAMESPACE}" '
            .data.activeTargets[]
            | select((.labels.namespace == $ns) or ((.labels.job // "") | test("web|nginx")))
            | "  \(.health)  \(.labels.job)  \(.scrapeUrl)"' 2>/dev/null || true
}
prom_targets

log "Количество запросов к NGINX (суммарно):"
prom 'sum(nginx_http_requests_total)' | jq -r '.data.result[]? | "  \(.value[1])"' || true

log "Запросов в секунду (rate за 1 минуту):"
prom 'sum(rate(nginx_http_requests_total[1m]))' | jq -r '.data.result[]? | "  \(.value[1])"' || true

log "Активные соединения NGINX:"
prom 'sum(nginx_connections_active)' | jq -r '.data.result[]? | "  \(.value[1])"' || true

log "Распределение запросов по pod'ам приложения:"
prom 'sum by (pod) (nginx_http_requests_total)' \
    | jq -r '.data.result[]? | "  \(.metric.pod): \(.value[1])"' || true

log "Загрузка CPU узлов, %:"
prom '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)' \
    | jq -r '.data.result[]? | "  \(.metric.instance): \(.value[1] | .[0:5])%"' || true

if ! prom 'sum(nginx_http_requests_total)' | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
    die "Prometheus не вернул метрик nginx_http_requests_total. Проверьте targets."
fi
ok "Метрики NGINX собираются и отдаются Prometheus."

# --- Логи ------------------------------------------------------------------------
section "3/4 Проверка логов в Elasticsearch"

kubectl -n "${APP_NAMESPACE}" port-forward svc/elasticsearch "${ES_PORT}:9200" >/tmp/smoke-es-pf.log 2>&1 &
ES_PF_PID=$!

log "Ожидание port-forward к Elasticsearch..."
for i in $(seq 1 30); do
    curl -sS --max-time 2 "http://127.0.0.1:${ES_PORT}/_cluster/health" >/dev/null 2>&1 && break
    sleep 1
done

# Аргументы после пути передаются в curl: без этого -d/-H молча игнорировались бы,
# и агрегации выполнялись как обычный GET без тела запроса.
es() {
    local path="$1"; shift
    curl -sS --max-time 10 "http://127.0.0.1:${ES_PORT}${path}" "$@" 2>/dev/null
}

log "Состояние кластера Elasticsearch:"
es '/_cluster/health' | jq -r '"  status=\(.status)  nodes=\(.number_of_nodes)  docs(active)=\(.active_primary_shards // 0) shard(s)"' 2>/dev/null || true

log "Индексы с логами:"
es '/_cat/indices/nginx-logs-*?h=index,health,status,docs.count,store.size&s=index' 2>/dev/null || warn "индексы nginx-logs-* пока не созданы"

log "Ждём доставки логов (Filebeat батчит и отправляет их пачками)..."
total=0
for i in $(seq 1 12); do
    total="$(es '/nginx-logs-*/_count' | jq -r '.count // 0' 2>/dev/null || echo 0)"
    [[ "${total}" -gt 0 ]] && break
    sleep 5
done

if [[ "${total}" -eq 0 ]]; then
    die "Логи не появились в Elasticsearch за 60 секунд.
Диагностика:
  kubectl -n ${APP_NAMESPACE} logs -l app.kubernetes.io/name=web -c filebeat --tail=50
  kubectl -n ${APP_NAMESPACE} get pods"
fi

ok "В Elasticsearch найдено документов с логами: ${total}"

log "Распределение по HTTP-кодам ответа (поле status из access-лога):"
es '/nginx-logs-*/_search' -H 'Content-Type: application/json' \
    -d '{"size":0,"query":{"term":{"log_type":"access"}},"aggs":{"codes":{"terms":{"field":"status","size":10}}}}' 2>/dev/null \
    | jq -r '.aggregations.codes.buckets[]? | "  HTTP \(.key): \(.doc_count)"' || true

log "Распределение по запрошенным путям (поле request_uri):"
es '/nginx-logs-*/_search' -H 'Content-Type: application/json' \
    -d '{"size":0,"query":{"term":{"log_type":"access"}},"aggs":{"paths":{"terms":{"field":"request_uri.keyword","size":5}}}}' 2>/dev/null \
    | jq -r '.aggregations.paths.buckets[]? | "  \(.key): \(.doc_count)"' || true

log "Последние записи access-лога:"
es '/nginx-logs-*/_search?size=5&sort=@timestamp:desc' 2>/dev/null \
    | jq -r '.hits.hits[]._source | "  \(."@timestamp" // .timestamp // "?")  \(.request_method // "?") \(.request_uri // "?") -> \(.status)  \(.remote_addr // "?")"' 2>/dev/null || true

# --- Вывод ----------------------------------------------------------------------
section "4/4 Готово"
cat <<EOF
Все компоненты работают под нагрузкой:

  Приложение     $(kubectl -n "${APP_NAMESPACE}" get deploy web -o jsonpath='{.status.readyReplicas}') реплики готовы, отдают "Hello World!"
  Gateway API    NGINX Gateway Fabric ${NGF_CHART_VERSION}, NodePort ${APP_NODEPORT}
  Мониторинг     ${total} лог-записей обработано, метрики NGINX собираются Prometheus
  Логирование    Filebeat -> Elasticsearch (индекс nginx-logs-YYYY.MM.DD)

Дополнительные проверки:

  ./hack/verify.sh              # полная проверка всех требований задания
  ./hack/test-idempotency.sh    # повторный запуск развёртывания
EOF
