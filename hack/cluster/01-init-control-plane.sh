#!/usr/bin/env bash
#
# Шаг 1. Инициализация control-plane узла (kubeadm init).
# Запускается ТОЛЬКО на control-plane узле, ПОСЛЕ 00-prepare-node.sh.
#
#   sudo ./01-init-control-plane.sh
#
# Идемпотентен: если кластер уже инициализирован, скрипт сообщит об этом и выйдет.
#
# Переменные окружения:
#   ALLOW_SCHEDULE_ON_CONTROL_PLANE=true  — снять taint control-plane.
#     Нужно для однопузлового (single-node) кластера на одной VM.
#   POD_NETWORK_CIDR / SERVICE_SUBNET      — переопределить сети.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"
load_versions "${SCRIPT_DIR}/../../versions.env"

require_root
require_cmd kubeadm kubectl

POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-192.168.0.0/16}"
SERVICE_SUBNET="${SERVICE_SUBNET:-10.96.0.0/12}"
ALLOW_SCHEDULE_ON_CONTROL_PLANE="${ALLOW_SCHEDULE_ON_CONTROL_PLANE:-false}"

section "MTC Engineer Hack — kubeadm init (control-plane)"

# --- Идемпотентность ------------------------------------------------------------
if [[ -f /etc/kubernetes/admin.conf ]]; then
    ok "Кластер уже инициализирован (/etc/kubernetes/admin.conf существует). Пропускаем."
    section "Переходим к установке CNI и addon-компонентов:"
    log "sudo ${SCRIPT_DIR}/03-install-cni.sh"
    exit 0
fi

# --- Определяем адрес узла -------------------------------------------------------
NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[[ -n "${NODE_IP}" ]] || die "Не удалось определить IP-адрес узла."
ok "IP-адрес control-plane узла: ${NODE_IP}"

# --- Рендерим kubeadm-конфигурацию --------------------------------------------
# Конфигурация хранится в репозитории как шаблон — её видно на code review.
CONFIG_TEMPLATE="${SCRIPT_DIR}/kubeadm-config.yaml"
CONFIG_FILE="$(mktemp /tmp/kubeadm-config.XXXXXX.yaml)"
trap 'rm -f "${CONFIG_FILE}"' EXIT

log "Рендерим kubeadm-конфигурацию из ${CONFIG_TEMPLATE}"
sed \
    -e "s|__KUBERNETES_VERSION__|v${KUBERNETES_VERSION}|g" \
    -e "s|__POD_NETWORK_CIDR__|${POD_NETWORK_CIDR}|g" \
    -e "s|__SERVICE_SUBNET__|${SERVICE_SUBNET}|g" \
    -e "s|__ADVERTISE_ADDRESS__|${NODE_IP}|g" \
    "${CONFIG_TEMPLATE}" >"${CONFIG_FILE}"

# --- kubeadm init ----------------------------------------------------------------
section "kubeadm init --config"
log "ВНИМАНИЕ: init может занять 3-5 минут (скачивание образов control-plane)."
kubeadm init --config "${CONFIG_FILE}" --upload-certs \
    --v=5 2>&1 | tee /var/log/kubeadm-init.log

# --- kubeconfig ------------------------------------------------------------------
section "Настройка kubeconfig"
install -d -m 0700 /root/.kube
install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
ok "kubeconfig для root: /root/.kube/config"

# Делаем кластер доступным из под обычного пользователя (нужно для deploy.sh)
DEPLOY_USER="${DEPLOY_USER:-${SUDO_USER:-}}"
if [[ -n "${DEPLOY_USER}" ]]; then
    DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
    # Первичную группу берём из passwd, а не предполагаем одноимённую:
    # на части дистрибутивов у пользователя группа называется иначе (users,
    # staff), и install с -g "${DEPLOY_USER}" упал бы с "no such group".
    DEPLOY_GROUP="$(id -gn "${DEPLOY_USER}" 2>/dev/null || echo "${DEPLOY_USER}")"
    if [[ -n "${DEPLOY_HOME}" && -d "${DEPLOY_HOME}" ]]; then
        install -d -m 0700 -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" "${DEPLOY_HOME}/.kube"
        install -m 0600 -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" \
            /etc/kubernetes/admin.conf "${DEPLOY_HOME}/.kube/config"
        ok "kubeconfig скопирован для пользователя ${DEPLOY_USER} (~/.kube/config)."
        warn "Если deploy идёт не от root, перезайдите в сессию, чтобы подхватить group."
    fi
fi

# --- Single-node режим ----------------------------------------------------------
if [[ "${ALLOW_SCHEDULE_ON_CONTROL_PLANE}" == "true" ]]; then
    section "Single-node режим: снимаем taint с control-plane"
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    kubectl taint nodes --all node-role.kubernetes.io/master- || true
    ok "Control-plane готов к запуску рабочих нагрузок."
fi

section "Готово: control-plane инициализирован"
cat <<EOF
Следующий шаг — установка CNI (Calico) и Storage provisioner:

  sudo ${SCRIPT_DIR}/03-install-cni.sh

Затем добавьте worker-узлы:

  На control-plane:  kubeadm token create --print-join-command
  На worker:        sudo ${SCRIPT_DIR}/02-join-worker.sh
EOF
