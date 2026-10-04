#!/usr/bin/env bash
#
# Проверка идемпотентности: повторный запуск развёртывания не должен
# приводить систему в некорректное состояние (требование задания).
#
#   ./hack/test-idempotency.sh
#
# Скрипт снимает «отпечаток» состояния кластера, запускает deploy.sh заново
# и сравнивает отпечатки. Проверяется, что:
#   * количество реплик, образы, порты и IP-адреса не изменились;
#   * все Deployment'ы остались готовыми;
#   * Gateway остался в состоянии Programmed;
#   * Helm-релизы не были переустановлены «с нуля».
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_versions "${REPO_ROOT}/versions.env"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Стабильные к повторному apply поля: без UIDs, timestamps и resourceVersion.
fingerprint() {
    local out="$1"

    {
        echo "### nodes"
        kubectl get nodes -o json | jq -r '.items[]
            | "\(.metadata.name) \(.status.conditions[] | select(.type=="Ready") | .status) \(.status.nodeInfo.kubeletVersion)"' | sort

        echo "### deployments"
        kubectl -n "${APP_NAMESPACE}" get deployments -o json | jq -r '.items[]
            | "\(.metadata.name) replicas=\(.spec.replicas) ready=\(.status.readyReplicas // 0) images=\([.spec.template.spec.containers[].image] | sort | join(","))"' | sort

        echo "### services"
        kubectl -n "${APP_NAMESPACE}" get services -o json | jq -r '.items[]
            | "\(.metadata.name) type=\(.spec.type) ip=\(.spec.clusterIP) ports=\([.spec.ports[] | "\(.port):\(.targetPort)"] | sort | join(","))"' | sort

        echo "### gateway"
        kubectl -n "${GATEWAY_NAMESPACE}" get gateway web-gateway -o json | jq -r '
            "gatewayclass=\(.spec.gatewayClassName) " +
            ( .status.conditions[]? | "\(.type)=\(.status)" )' | sort
        kubectl -n "${APP_NAMESPACE}" get httproute -o json | jq -r '.items[]
            | "\(.metadata.name) " + ( .status.parents[0].conditions[]? | "\(.type)=\(.status)" )' | sort
        kubectl get gatewayclass -o json | jq -r '.items[]
            | "\(.metadata.name) " + ( .status.conditions[]? | "\(.type)=\(.status)" )' | sort

        echo "### helm-releases"
        helm list -A --no-headers 2>/dev/null | awk '{print $1, $2, $3}' | sort

        echo "### networkpolicy"
        kubectl -n "${APP_NAMESPACE}" get networkpolicy -o name | sort

        echo "### pdb"
        kubectl -n "${APP_NAMESPACE}" get pdb -o json | jq -r '.items[]
            | "\(.metadata.name) minAvailable=\(.spec.minAvailable // .spec.maxUnavailable)"' | sort
    } >"${out}" 2>&1
}

section "1/4 Снятие отпечатка состояния (до повторного развёртывания)"
fingerprint "${WORK_DIR}/before.txt"
cat "${WORK_DIR}/before.txt"

section "2/4 Повторный запуск ./hack/deploy.sh"
log "Запускаем развёртывание во второй раз — все операции должны быть безопасны."
if ! "${SCRIPT_DIR}/deploy.sh"; then
    die "Повторный запуск развёртывания завершился с ошибкой — идемпотентность нарушена."
fi

section "3/4 Ожидание стабилизации"
kubectl -n "${APP_NAMESPACE}" wait --for=condition=Available --timeout=300s \
    deployment --all 2>/dev/null || warn "Не все deployment'ы Available."
kubectl -n "${GATEWAY_NAMESPACE}" wait gateway/web-gateway --for=condition=Programmed --timeout=300s 2>/dev/null \
    || warn "Gateway не перешёл в Programmed."
sleep 10   # даём метрикам и логам время на обновление

section "4/4 Сравнение отпечатков"
fingerprint "${WORK_DIR}/after.txt"

if diff -u "${WORK_DIR}/before.txt" "${WORK_DIR}/after.txt" >"${WORK_DIR}/diff.txt" 2>&1; then
    ok "Состояние кластера идентично до и после повторного развёртывания."
    ok "Идемпотентность подтверждена."
    exit 0
fi

warn "Обнаружены различия:"
cat "${WORK_DIR}/diff.txt"
echo
warn "Если различия касаются только readyReplicas или адресов nodePort-сервиса,"
warn "это штатное поведение. Иначе развёртывание не идемпотентно — см. diff выше."
exit 1
