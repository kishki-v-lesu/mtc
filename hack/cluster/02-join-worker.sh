#!/usr/bin/env bash
#
# Шаг 2. Присоединение worker-узла к кластеру.
# Запускается ТОЛЬКО на worker-узле, ПОСЛЕ 00-prepare-node.sh.
#
#   На control-plane:  kubeadm token create --print-join-command
#   На worker:        sudo JOIN_COMMAND="kubeadm join ..." ./02-join-worker.sh
#
# Если JOIN_COMMAND не передан, скрипт попытается выполнить его удалённо через
# SSH на узел, указанный в переменной WORKER_HOST (опционально).
#
# Идемпотентен: если узел уже в кластере (kubelet активен и узел виден) — выход.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"
load_versions "${SCRIPT_DIR}/../../versions.env"

require_root
require_cmd kubeadm

section "MTC Engineer Hack — присоединение worker-узла"

# --- Идемпотентность ------------------------------------------------------------
NODE_NAME="$(hostname)"
if systemctl is-active --quiet kubelet \
    && [[ -f /etc/kubernetes/kubelet.conf ]] \
    && grep -qE "server: https://" /etc/kubernetes/kubelet.conf 2>/dev/null; then
    ok "Узел уже присоединён к кластеру (kubelet активен). Пропускаем."
    exit 0
fi

# --- Получаем join-команду ------------------------------------------------------
JOIN_COMMAND="${JOIN_COMMAND:-}"
WORKER_HOST="${WORKER_HOST:-}"

if [[ -z "${JOIN_COMMAND}" ]]; then
    [[ -n "${WORKER_HOST}" ]] \
        || die "Не передана переменная JOIN_COMMAND. Выполните на control-plane
  kubeadm token create --print-join-command
и передайте результат, например:
  sudo JOIN_COMMAND='kubeadm join 10.0.0.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>' ./02-join-worker.sh

Альтернатива: указать WORKER_HOST=<ip worker'а> и выполнить на control-plane."

    log "JOIN_COMMAND не передан, пытаемся получить его с control-plane по SSH (${WORKER_HOST})..."
    JOIN_COMMAND="$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${WORKER_HOST}" \
        'sudo kubeadm token create --print-join-command' 2>/dev/null | tail -n1)"
    [[ -n "${JOIN_COMMAND}" ]] || die "Не удалось получить join-команду по SSH с ${WORKER_HOST}."
fi

# Приводим команду к аккуратному виду: переносим кавычки наружу
JOIN_COMMAND="${JOIN_COMMAND#kubeadm join }"
JOIN_COMMAND="${JOIN_COMMAND%\"}"

# --- Собираем конфигурацию kubeadm join из шаблона ------------------------------
JOIN_TEMPLATE="${SCRIPT_DIR}/kubeadm-join-config.yaml"
JOIN_FILE="$(mktemp /tmp/kubeadm-join.XXXXXX.yaml)"
trap 'rm -f "${JOIN_FILE}"' EXIT

NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
NODE_IP="${NODE_IP:-127.0.0.1}"

# Endpoint берём вместе с портом из join-команды и в шаблон подставляем как есть:
# в kubeadm-join-config.yaml порт уже не добавляется, иначе получилось бы
# "10.0.0.10:6443:6443".
API_SERVER_ENDPOINT="$(echo "${JOIN_COMMAND}" \
    | grep -oE '[0-9a-zA-Z.:\[\]-]+:6443' | head -n1)"
JOIN_TOKEN="$(echo "${JOIN_COMMAND}" | grep -oE '(--token=|--discovery-token )[^ ]+' | head -n1 | sed -E 's/^(--token=|--discovery-token )//')"
CA_HASH="$(echo "${JOIN_COMMAND}" | grep -oE 'sha256:[a-f0-9]+' | head -n1)"

[[ -n "${API_SERVER_ENDPOINT}" ]] || die "Не удалось распознать endpoint API-сервера из: ${JOIN_COMMAND}"
[[ -n "${JOIN_TOKEN}" ]]          || die "Не удалось распознать токен из: ${JOIN_COMMAND}"
[[ -n "${CA_HASH}" ]]             || die "Не удалось распознать ca-cert-hash из: ${JOIN_COMMAND}"

log "API server: ${API_SERVER_ENDPOINT}, IP узла: ${NODE_IP}"

sed \
    -e "s|__API_SERVER_ENDPOINT__|${API_SERVER_ENDPOINT}|g" \
    -e "s|__JOIN_TOKEN__|${JOIN_TOKEN}|g" \
    -e "s|__CA_CERT_HASH__|${CA_HASH}|g" \
    -e "s|__NODE_IP__|${NODE_IP}|g" \
    -e "s|__NODE_NAME__|${NODE_NAME}|g" \
    "${JOIN_TEMPLATE}" >"${JOIN_FILE}"

# --- Присоединяем ----------------------------------------------------------------
section "kubeadm join --config"
kubeadm join --config "${JOIN_FILE}" --v=5 2>&1 | tee /var/log/kubeadm-join.log

systemctl enable kubelet >/dev/null 2>&1

section "Готово: worker-узел ${NODE_NAME} присоединён"
log "Проверить состояние можно на control-plane: kubectl get nodes -o wide"
