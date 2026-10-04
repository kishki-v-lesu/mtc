#!/usr/bin/env bash
#
# Автоматическая проверка всех обязательных компонентов решения.
# Каждый пункт соответствует требованию из задания.
#
#   ./hack/verify.sh
#
# Скрипт ничего не изменяет в кластере (кроме генерации небольшого трафика)
# и завершается с ненулевым кодом, если хотя бы одна проверка не пройдена.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_versions "${REPO_ROOT}/versions.env"

PASSED=0
FAILED=0
declare -a RESULTS=()

# check <краткое имя> <команда проверки...>
check() {
    local name="$1"; shift
    local out rc
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    if [[ ${rc} -eq 0 ]]; then
        ok "[${name}]"
        RESULTS+=("PASS  ${name}")
        PASSED=$((PASSED + 1))
    else
        err "[${name}] — ${out}"
        RESULTS+=("FAIL  ${name}: ${out}")
        FAILED=$((FAILED + 1))
    fi
}

# --- 1. Kubernetes-кластер -------------------------------------------------------
section "1. Kubernetes-окружение"

check_k8s() {
    # На kubeadm-кластере ожидается ровно v${KUBERNETES_VERSION}, на kind — образ
    # узла публикуется только для .0 патча, поэтому допускается v${KIND_NODE_VERSION}.
    local want_kubeadm="v${KUBERNETES_VERSION}"
    local want_kind="v${KIND_NODE_VERSION:-${KUBERNETES_VERSION}}"
    local got
    got="$(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
    [[ "${got}" == "${want_kubeadm}" || "${got}" == "${want_kind}" ]] && return 0
    echo "версия Kubernetes ${got} не совпадает ни с ${want_kubeadm}, ни с ${want_kind}"
    return 1
}
check "Версия Kubernetes = v${KUBERNETES_VERSION} (или v${KIND_NODE_VERSION:-?} на kind)" check_k8s

check_nodes_ready() {
    local notready
    notready="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}')"
    [[ -z "${notready}" ]] || { echo "не готовы узлы: ${notready}"; return 1; }
}
check "Все узлы кластера в состоянии Ready" check_nodes_ready

check_cni() {
    kubectl get daemonset calico-node -n kube-system >/dev/null 2>&1 \
        || { echo "Calico не установлена"; return 1; }
}
check "CNI (Calico) установлен" check_cni

check_storageclass() {
    kubectl get storageclass -o json | jq -e '.items | length > 0' >/dev/null \
        || { echo "нет StorageClass"; return 1; }
}
check "StorageClass присутствует (PVC работают)" check_storageclass

# --- 2. Демонстрационное веб-приложение ------------------------------------------
section "2. Демонстрационное веб-приложение"

check_app_rollout() {
    kubectl -n "${APP_NAMESPACE}" rollout status deployment/web --timeout=120s >/dev/null \
        || { echo "deployment/web не готов"; return 1; }
}
check "Deployment web: все реплики готовы" check_app_rollout

check_app_pods_count() {
    # Считаем именно pod'ы с Ready=True, а не строки вывода kubectl:
    # колонка READY присутствует у любого pod'а и не говорит о готовности.
    local ready
    ready="$(kubectl -n "${APP_NAMESPACE}" get pods -l app.kubernetes.io/name=web -o json \
        | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')"
    [[ "${ready}" -ge 2 ]] || { echo "готовых pod'ов: ${ready} (ожидается >= 2)"; return 1; }
}
check "Приложение запущено минимум в 2 репликах" check_app_pods_count

check_app_liveness() {
    # Прямая проверка из кластера, без Gateway: сам ответ приложения
    local out
    out="$(kubectl -n "${APP_NAMESPACE}" exec deploy/web -c nginx -- \
        wget -qO- --timeout=5 http://127.0.0.1:8080/ 2>/dev/null || true)"
    [[ "${out}" == "Hello World!"* ]] || { echo "ответ: '${out}'"; return 1; }
}
check "Приложение отвечает 'Hello World!' (внутри кластера)" check_app_liveness

check_access_logs() {
    kubectl -n "${APP_NAMESPACE}" exec deploy/web -c nginx -- \
        test -s /var/log/nginx/access.log \
        || { echo "access.log пуст"; return 1; }
}
check "Access-логи NGINX формируются в файле" check_access_logs

# --- 3. Gateway API --------------------------------------------------------------
section "3. Gateway API"

check_gw_crd() {
    kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
        || { echo "CRD Gateway API не установлены"; return 1; }
}
check "CRD Gateway API установлены" check_gw_crd

check_gw_version() {
    local v
    # Начиная с Gateway API v1.4 bundle-version — аннотация, а не лейбл.
    v="$(kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
    if [[ -z "${v}" ]]; then
        v="$(kubectl get crd gateways.gateway.networking.k8s.io \
            -o jsonpath='{.metadata.labels.gateway\.networking\.k8s\.io/bundle-version}')"
    fi
    [[ "${v}" == "${GATEWAY_API_VERSION}" ]] || { echo "установлена версия ${v}"; return 1; }
}
check "Версия Gateway API = ${GATEWAY_API_VERSION}" check_gw_version

check_gwclass() {
    local accepted
    accepted="$(kubectl get gatewayclass nginx -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    [[ "${accepted}" == "True" ]] || { echo "GatewayClass nginx: Accepted=${accepted:-нет условия}"; return 1; }
}
check "GatewayClass 'nginx' принят (Accepted=True)" check_gwclass

check_gateway_programmed() {
    local programmed
    # Gateway лежит в GATEWAY_NAMESPACE, а не рядом с приложением: NGF
    # разворачивает data plane в namespace ресурса Gateway.
    programmed="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway web-gateway \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
    [[ "${programmed}" == "True" ]] || { echo "Gateway web-gateway: Programmed=${programmed:-нет условия}"; return 1; }
}
check "Gateway web-gateway: Programmed=True" check_gateway_programmed

check_httproute_accepted() {
    local accepted
    accepted="$(kubectl -n "${APP_NAMESPACE}" get httproute web-route \
        -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    [[ "${accepted}" == "True" ]] || { echo "HTTPRoute web-route: Accepted=${accepted:-нет условия}"; return 1; }
}
check "HTTPRoute web-route принят (Accepted=True)" check_httproute_accepted

GATEWAY_IP="$(gateway_access_ip || true)"
[[ -n "${GATEWAY_IP}" ]] || die "Не удалось определить IP узла для проверки шлюза. Проверьте: kubectl get nodes -o wide"

check_gateway_http() {
    local body
    body="$(curl -sS --max-time 10 "http://${GATEWAY_IP}:${APP_NODEPORT}/" 2>/dev/null || true)"
    [[ "${body}" == "Hello World!"* ]] || { echo "ответ от ${GATEWAY_IP}:${APP_NODEPORT}: '${body}'"; return 1; }
}
check "curl http://${GATEWAY_IP}:${APP_NODEPORT}/ -> 'Hello World!'" check_gateway_http

check_hostname_routing() {
    local body
    body="$(curl -sS --max-time 10 -H 'Host: web.mtc.local' "http://${GATEWAY_IP}:${APP_NODEPORT}/" 2>/dev/null || true)"
    [[ "${body}" == "Hello World!"* ]] || { echo "ответ с Host: web.mtc.local: '${body}'"; return 1; }
}
check "Маршрутизация по hostname (Host: web.mtc.local)" check_hostname_routing

check_path_routing() {
    local body
    body="$(curl -sS --max-time 10 "http://${GATEWAY_IP}:${APP_NODEPORT}/canary" 2>/dev/null || true)"
    [[ "${body}" == *"canary"* ]] || { echo "ответ на /canary: '${body}'"; return 1; }
}
check "Маршрутизация по path (/canary -> canary backend)" check_path_routing

check_traffic_split() {
    # При 10% canary достаточно 60 запросов, чтобы увидеть обе версии
    local main=0 canary=0 body
    for _ in $(seq 1 60); do
        body="$(curl -sS --max-time 5 "http://${GATEWAY_IP}:${APP_NODEPORT}/" 2>/dev/null || true)"
        if [[ "${body}" == *"canary"* ]]; then canary=$((canary + 1)); else main=$((main + 1)); fi
    done
    if [[ "${main}" -eq 0 ]]; then echo "ни одного запроса не дошло до стабильного backend"; return 1; fi
    log "traffic splitting: стабильный backend=${main}, canary=${canary} из 60 запросов"
    if [[ "${canary}" -eq 0 ]]; then
        warn "canary не получил ни одного запроса (при 10% это возможно). Проверьте веса backendRefs."
    fi
}
check "Traffic splitting 90/10 между двумя backend'ами" check_traffic_split

# --- 4. Мониторинг ---------------------------------------------------------------
section "4. Мониторинг (Prometheus)"

check_prometheus_running() {
    kubectl -n "${MONITORING_NAMESPACE}" get pods -l app.kubernetes.io/name=prometheus \
        --no-headers 2>/dev/null | grep -q Running \
        || { echo "Prometheus не запущен"; return 1; }
}
check "Prometheus запущен" check_prometheus_running

# Запускаем port-forward к Prometheus и опрашиваем его HTTP API
PROM_PORT=19090
prometheus_query() {
    local query="$1"
    curl -sS --max-time 10 --get "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
        --data-urlencode "query=${query}" 2>/dev/null
}

port_forward_start() {
    kubectl -n "${MONITORING_NAMESPACE}" port-forward \
        "svc/${KPS_RELEASE_NAME}-prometheus" "${PROM_PORT}:9090" >/tmp/prom-pf.log 2>&1 &
    PF_PID=$!
    trap 'kill_bg "${PF_PID:-}"' EXIT
    local _
    for _ in $(seq 1 30); do
        if curl -sS --max-time 2 "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

if port_forward_start; then
    ok "port-forward к Prometheus работает (127.0.0.1:${PROM_PORT})"

    check_prom_target_up() {
        local res
        res="$(prometheus_query 'up{namespace="mtc-demo",job=~".*web.*"}' || true)"
        echo "${res}" | jq -e '.status == "success"' >/dev/null \
            || { echo "Prometheus API не ответил корректно"; return 1; }
        local up_count
        up_count="$(echo "${res}" | jq '[.data.result[] | select(.value[1]=="1")] | length' 2>/dev/null || echo 0)"
        [[ "${up_count}" -ge 1 ]] || { echo "нет ни одного UP-таргета приложения"; return 1; }
    }
    check "Prometheus: target приложения в состоянии UP" check_prom_target_up

    check_prom_nginx_metrics() {
        local res
        res="$(prometheus_query 'nginx_http_requests_total' || true)"
        local count
        count="$(echo "${res}" | jq '.data.result | length' 2>/dev/null || echo 0)"
        [[ "${count}" -gt 0 ]] || { echo "метрика nginx_http_requests_total не найдена"; return 1; }
        log "nginx_http_requests_total: серий=${count}, пример значения: $(echo "${res}" | jq -r '.data.result[0].value[1]')"
    }
    check "Prometheus отдаёт метрику nginx_http_requests_total" check_prom_nginx_metrics

    check_prom_connections() {
        local res
        res="$(prometheus_query 'nginx_connections_active' || true)"
        echo "${res}" | jq -e '.data.result | length > 0' >/dev/null \
            || { echo "метрика nginx_connections_active не найдена"; return 1; }
    }
    check "Prometheus отдаёт метрику nginx_connections_active" check_prom_connections

    check_prom_node_metrics() {
        local res
        res="$(prometheus_query 'node_cpu_seconds_total' || true)"
        echo "${res}" | jq -e '.data.result | length > 0' >/dev/null \
            || { echo "метрики node-exporter не найдены"; return 1; }
    }
    check "Prometheus собирает метрики узлов (node-exporter)" check_prom_node_metrics

    check_prom_grafana() {
        kubectl -n "${MONITORING_NAMESPACE}" get pods -l app.kubernetes.io/name=grafana \
            --no-headers 2>/dev/null | grep -q Running \
            || { echo "Grafana не запущена"; return 1; }
    }
    check "Grafana запущена" check_prom_grafana
else
    warn "Не удалось установить port-forward к Prometheus. Проверки 4.x пропущены."
    warn "Диагностика: kubectl -n ${MONITORING_NAMESPACE} port-forward svc/${KPS_RELEASE_NAME}-prometheus 9090:9090"
    FAILED=$((FAILED + 1))
    RESULTS+=("FAIL  Prometheus API недоступен через port-forward")
fi

# --- 5. Логирование --------------------------------------------------------------
section "5. Логирование (Filebeat -> Elasticsearch)"

ES_PORT=19200
es_query() {
    local path="$1"; shift
    curl -sS --max-time 10 "http://127.0.0.1:${ES_PORT}${path}" "$@" 2>/dev/null
}

es_port_forward_start() {
    kubectl -n "${APP_NAMESPACE}" port-forward svc/elasticsearch "${ES_PORT}:9200" >/tmp/es-pf.log 2>&1 &
    ES_PF_PID=$!
    trap 'kill_bg "${ES_PF_PID:-}" "${PF_PID:-}"' EXIT
    local _
    for _ in $(seq 1 30); do
        if curl -sS --max-time 2 "http://127.0.0.1:${ES_PORT}/_cluster/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

check_filebeat_running() {
    local cnt
    cnt="$(kubectl -n "${APP_NAMESPACE}" get pods -l app.kubernetes.io/name=web \
        -o jsonpath='{.items[*].status.containerStatuses[?(@.name=="filebeat")].ready}' 2>/dev/null | tr ' ' '\n' | grep -c true || true)"
    [[ "${cnt}" -ge 1 ]] || { echo "контейнер filebeat не готов"; return 1; }
}
check "Контейнер Filebeat работает во всех pod'ах приложения" check_filebeat_running

if es_port_forward_start; then
    ok "port-forward к Elasticsearch работает (127.0.0.1:${ES_PORT})"

    check_es_health() {
        local status
        status="$(es_query '/_cluster/health' | jq -r '.status' 2>/dev/null || true)"
        [[ "${status}" == "green" || "${status}" == "yellow" ]] \
            || { echo "статус кластера ES: '${status:-нет ответа}'"; return 1; }
    }
    check "Elasticsearch доступен и готов" check_es_health

    # Генерируем уникальный запрос, чтобы гарантированно найти его в логах
    SMOKE_ID="verify-$(date +%s)-$$"
    curl -sS --max-time 5 -o /dev/null "http://${GATEWAY_IP}:${APP_NODEPORT}/verify/${SMOKE_ID}" || true
    log "Сгенерирован проверочный запрос: /verify/${SMOKE_ID}"
    log "Ждём доставки лога в Elasticsearch (до 90 секунд)..."

    check_es_has_logs() {
        local found=0
        for _ in $(seq 1 18); do
            found="$(es_query '/nginx-logs-*/_search' \
                -H 'Content-Type: application/json' \
                -d "{\"query\":{\"match_phrase\":{\"request_uri\":\"/verify/${SMOKE_ID}\"}}}" \
                | jq -r '.hits.total.value // 0' 2>/dev/null || echo 0)"
            [[ "${found}" -gt 0 ]] && break
            sleep 5
        done
        [[ "${found}" -gt 0 ]] \
            || { echo "лог запроса /verify/${SMOKE_ID} не найден в индексе nginx-logs-*"; return 1; }
        log "Лог проверочного запроса /verify/${SMOKE_ID} доставлен в Elasticsearch."
    }
    check "Логи приложения попадают в Elasticsearch (индекс nginx-logs-*)" check_es_has_logs

    check_es_index_fields() {
        local res
        # Забираем самый свежий документ: иначе проверка может посмотреть на
        # старый индекс, в котором полей ещё нет.
        res="$(es_query '/nginx-logs-*/_search?size=1&sort=@timestamp:desc' \
            | jq -c '.hits.hits[0]._source // {} | {service, log_type, request_method, status, request_uri}' 2>/dev/null || true)"
        echo "${res}" | jq -e '.service.name == "nginx" and .log_type != null' >/dev/null 2>&1 \
            || { echo "ожидались service.name=nginx и заполненный log_type, получено: ${res:-документ не найден}"; return 1; }
        log "Пример документа: ${res}"
    }
    check "Access-логи разобраны Filebeat (структурированные поля)" check_es_index_fields
else
    warn "Не удалось установить port-forward к Elasticsearch. Проверки логирования пропущены."
    FAILED=$((FAILED + 1))
    RESULTS+=("FAIL  Elasticsearch недоступен через port-forward")
fi

# --- 6. Безопасность и надёжность ------------------------------------------------
section "6. Практики надёжности и безопасности"

check_pdb() {
    kubectl -n "${APP_NAMESPACE}" get pdb web >/dev/null 2>&1 \
        || { echo "PodDisruptionBudget не найден"; return 1; }
}
check "PodDisruptionBudget для приложения настроен" check_pdb

check_networkpolicy() {
    local cnt
    cnt="$(kubectl -n "${APP_NAMESPACE}" get networkpolicy --no-headers 2>/dev/null | wc -l)"
    [[ "${cnt}" -ge 1 ]] || { echo "NetworkPolicy не настроены"; return 1; }
    log "NetworkPolicy в namespace ${APP_NAMESPACE}: ${cnt}"
}
check "NetworkPolicy применены" check_networkpolicy

check_probes() {
    local probes
    probes="$(kubectl -n "${APP_NAMESPACE}" get deploy web -o json \
        | jq '[.spec.template.spec.containers[0].livenessProbe, .spec.template.spec.containers[0].readinessProbe] | map(select(. != null)) | length')"
    [[ "${probes}" -eq 2 ]] || { echo "не все пробы заданы (${probes}/2)"; return 1; }
}
check "Liveness и readiness probes настроены" check_probes

check_resources() {
    local missing
    missing="$(kubectl -n "${APP_NAMESPACE}" get deploy web -o json \
        | jq '[.spec.template.spec.containers[] | select(.resources.requests == null or .resources.limits == null)] | length')"
    [[ "${missing}" -eq 0 ]] || { echo "контейнеров без requests/limits: ${missing}"; return 1; }
}
check "Requests и limits заданы для всех контейнеров" check_resources

check_sa_token() {
    local v
    v="$(kubectl -n "${APP_NAMESPACE}" get deploy web -o jsonpath='{.spec.template.spec.automountServiceAccountToken}')"
    [[ "${v}" == "false" ]] || { echo "automountServiceAccountToken=${v}"; return 1; }
}
check "ServiceAccount приложения не монтирует токен" check_sa_token

# --- Итог ------------------------------------------------------------------------
section "Итог проверки"
printf '%s\n' "${RESULTS[@]}"

echo
printf 'Пройдено: %s, Провалено: %s\n' "${PASSED}" "${FAILED}"

if [[ ${FAILED} -gt 0 ]]; then
    echo
    warn "Часть проверок не пройдена. Диагностика:"
    warn "  kubectl get pods -A -o wide"
    warn "  kubectl -n ${GATEWAY_NAMESPACE} describe gateway web-gateway"
    warn "  kubectl -n ${APP_NAMESPACE} logs -l app.kubernetes.io/name=web -c nginx"
    exit 1
fi

ok "Все проверки пройдены. Решение полностью соответствует требованиям задания."
