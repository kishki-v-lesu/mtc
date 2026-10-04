#!/usr/bin/env bash
#
# Шаг 0. Подготовка узла Ubuntu 24.04 для запуска Kubernetes-узла.
# Запускается на КАЖДОМ узле кластера (control-plane и worker) от root.
#
#   sudo ./00-prepare-node.sh
#
# Идемпотентен: повторный запуск безопасен, уже установленные пакеты не трогаются.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"
load_versions "${SCRIPT_DIR}/../../versions.env"

section "MTC Engineer Hack — подготовка узла"

require_root

# --- Проверка ОС ---------------------------------------------------------------
. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
    die "Поддерживается только Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}"
fi
log "Обнаружена ОС: ${PRETTY_NAME}"
case "${VERSION_ID}" in
    24.04) log "Версия Ubuntu соответствует требованию задания (24.04)." ;;
    *)     warn "Ожидалась Ubuntu 24.04, обнаружена ${VERSION_ID}. Решение продолжит работу, но в README указана 24.04." ;;
esac

# --- Системные требования ------------------------------------------------------
section "1/6 Обновление системы и базовые пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg jq \
    conntrack socat ethtool iptables ebtables ipset conntrack-tools \
    >/dev/null

# --- Swap ----------------------------------------------------------------------
section "2/6 Отключение swap"
if swapon --show --noheadings | grep -q .; then
    swapoff -a
    # Отключаем swap в fstab, иначе kubelet не запустится после ребута
    sed -i.bak '/\sswap\s/s/^/# disabled by MTC hackathon bootstrap: /' /etc/fstab
    ok "Swap отключён и удалён из /etc/fstab."
else
    ok "Swap уже отключён."
fi

# --- Kernel modules и sysctl ---------------------------------------------------
section "3/6 Kernel-модули и параметры sysctl"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Требование Elasticsearch (memory-mapped files). Применяется на всех узлах.
vm.max_map_count = 262144
EOF
sysctl --system >/dev/null
ok "Модули загружены, sysctl применены (включая vm.max_map_count=262144 для Elasticsearch)."

# --- containerd ----------------------------------------------------------------
section "4/6 Установка containerd"
if command -v containerd >/dev/null 2>&1 && [[ "$(systemctl is-active containerd 2>/dev/null || true)" == "active" ]]; then
    ok "containerd уже установлен и запущен: $(containerd --version)"
else
    log "Подключаем официальный apt-репозиторий Docker (источник containerd.io)..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq containerd.io >/dev/null
    ok "Установлен containerd: $(containerd --version)"
fi

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
# SystemdCgroup обязателен для корректной работы cgroups с kubelet
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd >/dev/null 2>&1
ok "containerd настроен (SystemdCgroup=true) и перезапущен."

# --- kubeadm / kubelet / kubectl -----------------------------------------------
section "5/6 Установка kubeadm, kubelet, kubectl ${KUBERNETES_VERSION}"

# Основной путь — apt-репозиторий pkgs.k8s.io (штатная инструкция Kubernetes).
# Fallback — официальные бинарники с dl.k8s.io с проверкой SHA-256.
# Причина fallback: у community-репозитория нет гарантии, что для нужной
# минорной версии опубликованы пакеты, а суффикс пакета ("-1.1") — деталь
# внутренней нумерации apt, которую нельзя надёжно предположить. Бинарники
# же привязаны ровно к той версии, которую мы фиксируем.
install_k8s_from_apt() {
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/Release.key" \
        | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/ /" \
        >/etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq
    apt-get install -y -qq \
        "kubelet=${KUBERNETES_VERSION}-1.1" \
        "kubeadm=${KUBERNETES_VERSION}-1.1" \
        "kubectl=${KUBERNETES_VERSION}-1.1"
}

install_k8s_from_binaries() {
    local arch tarball tmp
    case "$(dpkg --print-architecture)" in
        amd64) arch="amd64" ;;
        arm64) arch="arm64" ;;
        *) die "Неподдерживаемая архитектура для бинарной установки: $(dpkg --print-architecture)" ;;
    esac
    tmp="$(mktemp -d /tmp/k8s-bin.XXXXXX)"

    for binary in kubeadm kubelet kubectl; do
        local base="https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/${arch}"
        tarball="${tmp}/${binary}.tar.gz"
        log "Скачиваем ${binary} v${KUBERNETES_VERSION} (${arch})..."
        curl -fsSL --retry 5 --retry-delay 3 -o "${tarball}" "${base}/${binary}.tar.gz"

        # Сверяем контрольную сумму с опубликованной на dl.k8s.io: подменённый
        # бинарник kubeadm с правами root — худший возможный исход этого шага.
        curl -fsSL --retry 5 --retry-delay 3 -o "${tarball}.sha256" "${base}/${binary}.tar.gz.sha256"
        if [[ "$(sha256_of "${tarball}")" != "$(tr -d '[:space:]' <"${tarball}.sha256")" ]]; then
            rm -rf "${tmp}"
            die "Контрольная сумма ${binary} не совпала с dl.k8s.io. Прерываемся."
        fi

        tar -xzf "${tarball}" -C "${tmp}"
        install -m 0755 "${tmp}/kubernetes/bin/${binary}" "/usr/local/bin/${binary}"
    done
    rm -rf "${tmp}"
}

if install_k8s_from_apt 2>/dev/null; then
    ok "Установлено из apt-репозитория pkgs.k8s.io."
else
    warn "apt-репозиторий pkgs.k8s.io не дал пакеты версии ${KUBERNETES_VERSION}."
    warn "Переключаемся на официальные бинарники dl.k8s.io с проверкой SHA-256."
    install_k8s_from_binaries
    ok "Установлено из бинарников dl.k8s.io (SHA-256 проверен)."
fi

# Единая точка для всех пакетов: /usr/local/bin в PATH по умолчанию, поэтому
# путь одинаков для apt (/usr/bin) и для бинарников (/usr/local/bin).
KUBECTL_BIN="$(command -v kubectl)"
KUBEADM_BIN="$(command -v kubeadm)"
KUBELET_BIN="$(command -v kubelet || true)"

ok "kubectl:  $("${KUBECTL_BIN}" version --client 2>/dev/null | head -1 || echo "${KUBECTL_BIN}")"
ok "kubeadm:  $("${KUBEADM_BIN}" version -o short 2>/dev/null || echo "${KUBEADM_BIN}")"

# systemd-обвязка kubelet. В apt-варианте unit и drop-in приходят из пакета
# systemd — там лежит правильный ExecStart и путь /usr/bin/kubelet, поэтому
# ничего не трогаем. В бинарном варианте их нет, создаём сами с тем же
# содержимым, но подставляя фактический путь к kubelet.
if [[ ! -f /etc/systemd/system/kubelet.service ]]; then
    [[ -n "${KUBELET_BIN}" ]] || die "kubelet не найден в PATH после установки."
    log "Создаём unit-файл kubelet: ExecStart=${KUBELET_BIN}"
    cat >/etc/systemd/system/kubelet.service <<UNIT
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=${KUBELET_BIN}
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

    mkdir -p /etc/systemd/system/kubelet.service.d
    cat >/etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<DROPIN
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=${KUBELET_BIN} \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
DROPIN
else
    log "unit-файл kubelet уже предоставлен пакетом — оставляем как есть."
fi

systemctl daemon-reload
systemctl enable kubelet >/dev/null 2>&1 || true
apt-mark hold kubelet kubeadm kubectl >/dev/null 2>&1 || true
ok "kubelet настроен (systemd unit + drop-in kubeadm)."

# --- CNI prerequisites ---------------------------------------------------------
section "6/6 Подготовка сети для CNI"
mkdir -p /etc/cni/net.d
ok "Каталог /etc/cni/net.d создан."

# --- Безопасность SSH (опционально, включается переменной окружения) -----------
if [[ "${HARDEN_SSH:-false}" == "true" ]]; then
    log "HARDEN_SSH=true — включаем PasswordAuthentication=no..."
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl reload ssh || true
fi

section "Готово"
cat <<EOF
Узел подготовлен. Следующий шаг зависит от роли узла:

  control-plane:  sudo ${SCRIPT_DIR}/01-init-control-plane.sh
  worker:         sudo ${SCRIPT_DIR}/02-join-worker.sh
EOF
