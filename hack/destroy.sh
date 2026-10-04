#!/usr/bin/env bash
#
# Полное удаление решения из кластера.
#
#   ./hack/destroy.sh              # удалить компоненты решения
#   ./hack/destroy.sh --all        # дополнительно снести сам кластер
#   ./hack/destroy.sh --keep-volumes
#
# Скрипт идемпотентен: удаление уже отсутствующих ресурсов не считается ошибкой.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_versions "${REPO_ROOT}/versions.env"

RESET_CLUSTER=false
KEEP_VOLUMES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)           RESET_CLUSTER=true ;;
        --keep-volumes)  KEEP_VOLUMES=true ;;
        -h|--help)       grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               die "Неизвестный аргумент: $1" ;;
    esac
    shift
done

require_cmd kubectl helm

# --- Удаление наших манифестов ---------------------------------------------------
section "1/4 Удаление манифестов решения"
if kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete -k "${REPO_ROOT}/deploy" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    ok "Манифесты решения удалены (kustomize)."
else
    ok "Namespace ${APP_NAMESPACE} не найден — пропускаем."
fi

# --- Удаление Helm-релизов -------------------------------------------------------
section "2/4 Удаление Helm-релизов"
for release_spec in "${KPS_RELEASE_NAME}:${MONITORING_NAMESPACE}" "${NGF_RELEASE_NAME}:${GATEWAY_NAMESPACE}"; do
    release="${release_spec%%:*}"
    namespace="${release_spec##*:}"
    if helm status "${release}" -n "${namespace}" >/dev/null 2>&1; then
        log "Удаляем Helm-релиз ${release} из namespace ${namespace}..."
        helm uninstall "${release}" -n "${namespace}" --wait --timeout 5m
        ok "Релиз ${release} удалён."
    else
        ok "Релиз ${release} не установлен — пропускаем."
    fi
done

# --- Очистка namespace и хранилищ -------------------------------------------------
section "3/4 Очистка namespace"
for ns in "${APP_NAMESPACE}" "${MONITORING_NAMESPACE}" "${GATEWAY_NAMESPACE}"; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        if [[ "${KEEP_VOLUMES}" == "true" ]]; then
            warn "Оставляем PVC в namespace ${ns} (--keep-volumes). Удалите вручную:"
            kubectl -n "${ns}" get pvc
        fi
        # Ожидаем удаления, но не блокируемся навечно из-за PVC.
        kubectl delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        ok "Namespace ${ns} помечен на удаление."
    fi
done

if [[ "${KEEP_VOLUMES}" != "true" ]]; then
    log "Ожидание фактического удаления namespace (до 120 секунд)..."
    for _ in $(seq 1 60); do
        local_remaining="$(kubectl get ns -o name 2>/dev/null \
            | grep -cE "(${APP_NAMESPACE}|${MONITORING_NAMESPACE}|${GATEWAY_NAMESPACE})$" || true)"
        [[ "${local_remaining}" -eq 0 ]] && break
        sleep 2
    done
    ok "Namespace удалены."
else
    warn "Namespace остаются в состоянии Terminating, пока не удалите PVC вручную."
fi

# --- Опционально: снести кластер --------------------------------------------------
if [[ "${RESET_CLUSTER}" == "true" ]]; then
    section "4/4 Сброс кластера (kubeadm reset)"
    warn "Будут удалены все pods и данные кластера."
    read -r -p "Введите 'yes' для подтверждения: " answer
    if [[ "${answer}" == "yes" ]]; then
        sudo kubeadm reset -f || die "kubeadm reset не выполнен"
        sudo "${REPO_ROOT}/hack/cluster/00-prepare-node.sh" || warn "Подготовка узла завершилась с ошибкой"
        ok "Кластер сброшен."
    else
        ok "Сброс кластера отменён пользователем."
    fi
else
    section "4/4 Готово"
fi

ok "Решение удалено из кластера. Файлы репозитория не затронуты."
log "Если нужен полный сброс кластера: ./hack/destroy.sh --all"
