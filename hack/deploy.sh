#!/usr/bin/env bash
#
# Развёртывание всего решения в готовый Kubernetes-кластер.
#
#   ./hack/deploy.sh
#
# Скрипт идемпотентен: его можно запускать повторно, состояние кластера
# от этого не портится, а уже установленные компоненты обновляются на
# зафиксированные в versions.env версии.
#
# Опции:
#   --skip-monitoring   не разворачивать Prometheus/Grafana
#   --skip-logging      не разворачивать Elasticsearch и Filebeat
#   --skip-canary       не разворачивать canary-версию приложения
#   --skip-images       не проверять доступность образов заранее
#   --timeout <dur>     таймаут ожидания (по умолчанию 10m)
#   --dry-run           только показать, что будет сделано
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_versions "${REPO_ROOT}/versions.env"

# --- Аргументы ------------------------------------------------------------------
SKIP_MONITORING=false
SKIP_LOGGING=false
SKIP_CANARY=false
SKIP_IMAGES=false
DRY_RUN=false
TIMEOUT="${DEPLOY_TIMEOUT:-10m}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-monitoring) SKIP_MONITORING=true ;;
        --skip-logging)    SKIP_LOGGING=true ;;
        --skip-canary)     SKIP_CANARY=true ;;
        --skip-images)     SKIP_IMAGES=true ;;
        --dry-run)         DRY_RUN=true ;;
        --timeout)         TIMEOUT="$2"; shift ;;
        -h|--help)
            grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Неизвестный аргумент: $1 (см. --help)" ;;
    esac
    shift
done

run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '%s[DRY-RUN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"
    else
        "$@"
    fi
}

# --- Префлайт -------------------------------------------------------------------
section "0/6 Префлайт"

require_cmd kubectl helm curl jq
require_cluster

log "Версия Kubernetes сервера: $(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo 'неизвестно')"
log "Версия kubectl:           $(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo 'неизвестно')"
log "Версия helm:             $(helm version --short 2>/dev/null || echo 'неизвестно')"
log "Kubernetes API:          $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo 'неизвестно')"

# Проверяем, что в кластере есть Calico (иначе NetworkPolicy не будет применяться)
if kubectl get daemonset calico-node -n kube-system >/dev/null 2>&1; then
    ok "CNI Calico обнаружен — NetworkPolicy будут применяться."
else
    warn "Calico не обнаружена. NetworkPolicy не будут применяться."
    warn "Запустите: sudo hack/cluster/03-install-cni.sh"
fi

# --- Проверка образов -----------------------------------------------------------
# Зафиксированные в versions.env теги должны существовать. Проверяем заранее,
# чтобы ошибка была понятна сразу, а не в середине развёртывания.
preflight_images() {
    if [[ "${SKIP_IMAGES}" == "true" ]]; then
        log "Проверка образов пропущена (--skip-images)."
        return 0
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Проверка образов пропущена (--dry-run не должен менять состояние)."
        return 0
    fi
    local crictl_bin=""
    if command -v crictl >/dev/null 2>&1; then
        crictl_bin="crictl"
    elif [[ -x /usr/bin/crictl ]]; then
        crictl_bin="/usr/bin/crictl"
    else
        warn "crictl не найден — проверка образов пропущена."
        return 0
    fi

    local images=("${NGINX_IMAGE}" "${NGINX_EXPORTER_IMAGE}")
    if [[ "${SKIP_LOGGING}" != "true" ]]; then
        images+=("${FILEBEAT_IMAGE}" "${ELASTICSEARCH_IMAGE}")
    fi

    log "Проверяем доступность образов (изображения кэшируются в containerd)..."
    local img err_out
    for img in "${images[@]}"; do
        err_out="$(mktemp)"
        if ${crictl_bin} pull -q "${img}" >/dev/null 2>"${err_out}"; then
            ok "Образ доступен: ${img}"
        elif grep -qi "permission denied\|connect: permission" "${err_out}" 2>/dev/null; then
            rm -f "${err_out}"
            warn "Нет прав на socket containerd — проверка образов пропущена."
            return 0
        else
            err "Образ недоступен: ${img}"
            err "$(head -n3 "${err_out}")"
            rm -f "${err_out}"
            die "Проверьте тег образа в versions.env и доступность реестра."
        fi
        rm -f "${err_out}"
    done
}
preflight_images

# --- Gateway API ----------------------------------------------------------------
section "1/6 Gateway API ${GATEWAY_API_VERSION} (channel: ${GATEWAY_API_CHANNEL})"
GATEWAY_API_URL="${GATEWAY_API_RELEASE_BASE}/${GATEWAY_API_VERSION}/${GATEWAY_API_CHANNEL}-install.yaml"

current_bundle="$(
    kubectl get crd gateways.gateway.networking.k8s.io \
        -o jsonpath='{.metadata.labels.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true
)"

if [[ "${current_bundle}" == "${GATEWAY_API_VERSION}" ]]; then
    ok "CRD Gateway API ${GATEWAY_API_VERSION} уже установлены. Пропускаем."
else
    if [[ -n "${current_bundle}" ]]; then
        log "Обнаружена другая версия CRD (${current_bundle}), обновляем на ${GATEWAY_API_VERSION}."
    fi
    TMP_GW="$(mktemp /tmp/gateway-api.XXXXXX.yaml)"
    trap 'rm -f "${TMP_GW:-}"' EXIT
    log "Загрузка: ${GATEWAY_API_URL}"
    curl -fsSL --retry 5 --retry-delay 3 -o "${TMP_GW}" "${GATEWAY_API_URL}"
    ok "SHA256 манифеста: $(sha256_of "${TMP_GW}")"
    run kubectl apply --server-side --force-conflicts -f "${TMP_GW}"
    if [[ "${DRY_RUN}" != "true" ]]; then
        kubectl wait --for=condition=Established --timeout=120s \
            crd/gateways.gateway.networking.k8s.io \
            crd/gatewayclasses.gateway.networking.k8s.io \
            crd/httproutes.gateway.networking.k8s.io
    fi
    ok "CRD Gateway API установлены."
fi

# --- NGINX Gateway Fabric -------------------------------------------------------
section "2/6 NGINX Gateway Fabric ${NGF_CHART_VERSION} (Gateway API implementation)"

# --wait несовместим с --dry-run, поэтому флаг ожидания добавляется только
# при реальном развёртывании. Массив вместо строки — чтобы аргументы с [] и {}
# не разбирались оболочкой.
helm_args=(
    upgrade --install "${NGF_RELEASE_NAME}"
    "${NGF_CHART_REPO}"
    --version "${NGF_CHART_VERSION}"
    --namespace "${GATEWAY_NAMESPACE}"
    --create-namespace
    --values "${REPO_ROOT}/helm-values/nginx-gateway-fabric.yaml"
    --timeout "${TIMEOUT}"
    # nodePorts передаём целиком (port + listenerPort): при передаче только
    # --set nginx.service.nodePorts[0].port=... Helm заменил бы весь список
    # и потерял listenerPort, а NGINX Gateway Fabric игнорирует NodePort,
    # не сопоставленный с портом listener'а.
    --set "nginx.service.nodePorts[0].port=${APP_NODEPORT}"
    --set "nginx.service.nodePorts[0].listenerPort=${NGF_LISTENER_PORT}"
)
[[ "${DRY_RUN}" == "true" ]] && helm_args+=(--dry-run=client) || helm_args+=(--wait)

helm "${helm_args[@]}"
ok "NGINX Gateway Fabric установлен в namespace ${GATEWAY_NAMESPACE}."

# ВНИМАНИЕ: сам Helm-чарт NGINX Gateway Fabric 2.x НЕ создаёт data plane.
# Чарт ставит только control plane (Deployment, NginxGateway, NginxProxy, Job
# с выпуском сертификатов). Deployment и Service с NGINX, который реально
# терминирует трафик, создаёт provisioner'ом динамически — сразу после того,
# как в кластере появляется Gateway, ссылающийся на наш GatewayClass.
# Поэтому проверять NodePort здесь (в шаге 2/6) бессмысленно: на чистом
# кластере Service ещё не существует. Проверка перенесена в шаг 5/6.

# --- Мониторинг -----------------------------------------------------------------
if [[ "${SKIP_MONITORING}" == "true" ]]; then
    section "3/6 Мониторинг — ПРОПУЩЕНО (--skip-monitoring)"
else
    section "3/6 Prometheus + Grafana (kube-prometheus-stack ${KPS_CHART_VERSION})"

    # Пароль администратора Grafana: генерируется один раз и переиспользуется,
    # чтобы повторный запуск deploy.sh не ломал доступ (идемпотентность).
    SECRETS_DIR="${REPO_ROOT}/.secrets"
    GRAFANA_PW_FILE="${SECRETS_DIR}/grafana-admin-password"
    if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
        if [[ -f "${GRAFANA_PW_FILE}" ]]; then
            GRAFANA_ADMIN_PASSWORD="$(cat "${GRAFANA_PW_FILE}")"
            log "Используем ранее сгенерированный пароль Grafana из .secrets/."
        else
            GRAFANA_ADMIN_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
            mkdir -p "${SECRETS_DIR}"; chmod 0700 "${SECRETS_DIR}"
            printf '%s' "${GRAFANA_ADMIN_PASSWORD}" >"${GRAFANA_PW_FILE}"
            chmod 0600 "${GRAFANA_PW_FILE}"
            log "Сгенерирован новый пароль Grafana (сохранён в .secrets/, в git не попадает)."
        fi
    fi

    helm repo add prometheus-community "${KPS_CHART_REPO}" --force-update >/dev/null 2>&1 || true
    helm repo update prometheus-community >/dev/null 2>&1 || true

    kps_args=(
        upgrade --install "${KPS_RELEASE_NAME}" prometheus-community/kube-prometheus-stack
        --version "${KPS_CHART_VERSION}"
        --namespace "${MONITORING_NAMESPACE}"
        --create-namespace
        --values "${REPO_ROOT}/helm-values/kube-prometheus-stack.yaml"
        --timeout "${TIMEOUT}"
        --set-string "grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD}"
    )
    [[ "${DRY_RUN}" == "true" ]] && kps_args+=(--dry-run=client) || kps_args+=(--wait)

    helm "${kps_args[@]}"

    ok "Prometheus и Grafana установлены в namespace ${MONITORING_NAMESPACE}."
fi

# --- Манифесты решения ----------------------------------------------------------
section "4/6 Применение манифестов решения (kustomize)"
log "Каталог: ${REPO_ROOT}/deploy"
if [[ "${DRY_RUN}" != "true" ]]; then
    # Порядок важен: namespace -> приложение -> шлюз -> логирование -> мониторинг
    # Одиночный файл применяется через -f, каталоги с kustomization.yaml через -k
    k_apply "${REPO_ROOT}/deploy/00-namespace.yaml"
    k_apply_k "${REPO_ROOT}/deploy/app"
    [[ "${SKIP_CANARY}" != "true" ]] && k_apply_k "${REPO_ROOT}/deploy/canary"
    k_apply_k "${REPO_ROOT}/deploy/gateway"
    [[ "${SKIP_LOGGING}" == "true" ]] || k_apply_k "${REPO_ROOT}/deploy/logging"
    [[ "${SKIP_MONITORING}" == "true" ]] || k_apply_k "${REPO_ROOT}/deploy/monitoring"
    k_apply_k "${REPO_ROOT}/deploy/security"
else
    printf '%s[DRY-RUN]%s kubectl apply -k deploy/{app,canary,gateway,logging,monitoring,security}\n' \
        "${C_YELLOW}" "${C_RESET}"
fi
ok "Манифесты применены."

# --- Синхронизация контрольной суммы конфигурации --------------------------------
# Аннотация checksum/config на pod-шаблоне заставляет kubelet пересоздать поды,
# если ConfigMap изменился. Без этого изменение nginx.conf не применилось бы.
# Если сумма не изменилась, patch ничего не меняет и rollout не запускается —
# это и обеспечивает идемпотентность повторного развёртывания.
sync_config_checksum() {
    local deployment="$1" dir="$2" want current
    [[ -d "${dir}" ]] || return 0

    want="$(cat "${dir}"/*.yaml | sha256_of -)"
    current="$(kubectl -n "${APP_NAMESPACE}" get deployment "${deployment}" \
        -o jsonpath='{.spec.template.metadata.annotations.checksum/config}' 2>/dev/null || true)"

    if [[ "${want}" == "${current}" ]]; then
        log "checksum/config для ${deployment} не изменился (${want:0:12}...), rollout не требуется."
        return 0
    fi

    kubectl -n "${APP_NAMESPACE}" patch deployment "${deployment}" --type=merge \
        -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"${want}\"}}}}}" \
        >/dev/null
    ok "checksum/config для ${deployment}: ${current:-<был пуст>} -> ${want:0:12}..., поды перезапустятся."
}

if [[ "${DRY_RUN}" != "true" ]]; then
    sync_config_checksum web "${REPO_ROOT}/deploy/app"
    [[ "${SKIP_CANARY}" != "true" ]] && sync_config_checksum web-canary "${REPO_ROOT}/deploy/canary"
fi

# --- Ожидание готовности --------------------------------------------------------
if [[ "${DRY_RUN}" != "true" ]]; then
    section "5/6 Ожидание готовности компонентов"

    log "Deployment'ы namespace ${APP_NAMESPACE}:"
    kubectl -n "${APP_NAMESPACE}" wait --for=condition=Available --timeout="${TIMEOUT}" \
        deployment --all 2>/dev/null \
        || warn "Не все deployment'ы в ${APP_NAMESPACE} стали Available. Подробности: kubectl -n ${APP_NAMESPACE} get pods"

    log "Gateway становится Programmed, когда data plane NGINX готов..."
    if kubectl -n "${GATEWAY_NAMESPACE}" wait gateway/web-gateway \
            --for=condition=Programmed --timeout="${TIMEOUT}" 2>/dev/null; then
        ok "Gateway web-gateway: Programmed."
    else
        warn "Gateway web-gateway не перешёл в Programmed."
        warn "Диагностика: kubectl -n ${GATEWAY_NAMESPACE} describe gateway web-gateway"
        warn "             kubectl -n ${GATEWAY_NAMESPACE} get pods"
    fi

    # NodePort data plane. К этому моменту Gateway уже применён, provisioner
    # NGINX Gateway Fabric должен был создать Service с NGINX.
    #
    # Service ищем НЕ по лейблам (их набор меняется между версиями NGF), а по
    # типу: это единственный Service типа NodePort в namespace шлюза.
    # Namespace совпадает с GATEWAY_NAMESPACE потому, что NGF создаёт data
    # plane в namespace ресурса Gateway (в NginxProxy нет поля namespace).
    data_plane_nodeport() {
        kubectl -n "${GATEWAY_NAMESPACE}" get svc \
            -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{range .spec.ports[*]}{.nodePort}{"\n"}{end}{end}' \
            2>/dev/null | head -n1
    }

    log "Проверка NodePort data plane..."
    if retry_until 120 5 "появления NodePort Service data plane" data_plane_nodeport; then
        actual_np="$(data_plane_nodeport)"
        if [[ "${actual_np}" == "${APP_NODEPORT}" ]]; then
            ok "NodePort data plane: ${actual_np} (совпадает с versions.env)."
        else
            # Не «предупреждение», а ошибка: от этого значения зависят
            # curl-команды в README и все проверки verify.sh. Расхождение
            # означало бы, что документированная точка входа не работает.
            die "NodePort data plane: ${actual_np}, а в versions.env указано ${APP_NODEPORT}.
Инструкция в README и проверки verify.sh используют порт ${APP_NODEPORT}.
Исправьте APP_NODEPORT в versions.env (или освободите порт ${APP_NODEPORT} в кластере)
и запустите ./hack/deploy.sh повторно."
        fi
    else
        warn "NodePort Service data plane не появился. Проверьте:"
        warn "  kubectl -n ${GATEWAY_NAMESPACE} get svc,pods"
        warn "  kubectl -n ${GATEWAY_NAMESPACE} describe gateway web-gateway"
    fi

    if [[ "${SKIP_MONITORING}" != "true" ]]; then
        log "Prometheus становится Ready..."
        kubectl -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready pod \
            -l app.kubernetes.io/name=prometheus --timeout="${TIMEOUT}" 2>/dev/null \
            || warn "Prometheus не сообщил Ready. Проверьте: kubectl -n ${MONITORING_NAMESPACE} get pods"
    fi
fi

# --- Итог -----------------------------------------------------------------------
section "6/6 Готово"
GATEWAY_IP="$(gateway_access_ip || true)"

cat <<EOF
$(ok "Решение развёрнуто.")

  Kubernetes:    ${KUBERNETES_VERSION}
  Gateway API:   ${GATEWAY_API_VERSION}
  Реализация:    NGINX Gateway Fabric ${NGF_CHART_VERSION}
  Приложение:    3 реплики NGINX + exporter + Filebeat
  Логи:          Filebeat -> Elasticsearch (индекс nginx-logs-*)
  Мониторинг:    Prometheus + Grafana (namespace ${MONITORING_NAMESPACE})

Проверка доступности приложения через Gateway API:

  curl http://${GATEWAY_IP:-<NODE_IP>}:${APP_NODEPORT}/
  # ожидается: Hello World!

Полная автоматическая проверка всех обязательных компонентов:

  ./hack/verify.sh

Генерация нагрузки и проверка метрик и логов:

  ./hack/smoke-test.sh

Получить доступ к Grafana и Prometheus (port-forward, два терминала):

  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/${KPS_RELEASE_NAME}-grafana 3000:80
  kubectl -n ${MONITORING_NAMESPACE} port-forward svc/${KPS_RELEASE_NAME}-prometheus 9090:9090

Пароль Grafana:

  kubectl -n ${MONITORING_NAMESPACE} get secret ${KPS_RELEASE_NAME}-grafana \
    -o jsonpath='{.data.admin-password}' | base64 -d; echo
EOF
