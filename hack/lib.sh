#!/usr/bin/env bash
# Общие функции для всех скриптов репозитория.
# shellcheck disable=SC2034

set -Eeuo pipefail

MTC_LIB_LOADED=1

# --- Вывод ---------------------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

log()      { printf '%s[ *]%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()       { printf '%s[+]%s %s\n'    "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()     { printf '%s[!]%s %s\n'    "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()      { printf '%s[ERROR]%s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; }
section()  { printf '\n%s%s== %s ==%s\n' "${C_BOLD}" "${C_BLUE}" "$*" "${C_RESET}"; }
die()      { err "$*"; exit 1; }

# --- Загрузка версий -----------------------------------------------------------

load_versions() {
    local versions_file="${1:-}"
    if [[ -z "${versions_file}" ]]; then
        # идём вверх от текущего скрипта до корня репозитория
        local dir
        dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        versions_file="${dir}/versions.env"
    fi
    [[ -f "${versions_file}" ]] || die "Файл с версиями не найден: ${versions_file}"
    set -a
    # shellcheck source=/dev/null
    source "${versions_file}"
    set +a
    MTC_VERSIONS_FILE="${versions_file}"
}

# --- Проверки окружения --------------------------------------------------------

require_cmd() {
    local missing=0
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || { err "Не найдена обязательная команда: ${cmd}"; missing=1; }
    done
    [[ ${missing} -eq 0 ]] || die "Установите недостающие зависимости и повторите."
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Скрипт должен быть запущен от root (используйте sudo)."
}

# Проверка, что мы действительно talking к живому кластеру
require_cluster() {
    kubectl cluster-info >/dev/null 2>&1 \
        || die "Kubernetes-кластер недоступен. Проверьте kubectl и подключение (KUBECONFIG)."
}

# --- Kubernetes helpers --------------------------------------------------------

# kubectl apply с server-side apply для файла или списка файлов:
# идемпотентно и без конфликтов полей.
k_apply() {
    kubectl apply --server-side --force-conflicts -f "$@"
}

# То же, но для каталога с kustomization.yaml.
# Важно: `kubectl apply -f <каталог>` не обрабатывает kustomization.yaml,
# поэтому каталоги всегда применяются через -k.
k_apply_k() {
    kubectl apply --server-side --force-conflicts -k "$@"
}

# Ожидание готовности всех ресурсов в namespace
wait_rollout() {
    local ns="$1" timeout="${2:-300s}"
    log "Ожидание завершения rollout в namespace ${ns} (timeout ${timeout})..."
    kubectl -n "${ns}" rollout status --timeout="${timeout}" \
        deployment --selector='app.kubernetes.io/part-of=mtc-hack' || true
    kubectl -n "${ns}" wait --for=condition=Available --timeout="${timeout}" \
        deployment --all 2>/dev/null || true
}

# Получить IP первого control-plane узла.
# Учитываем и новый label, и legacy-вариант node-role=master.
control_plane_ip() {
    local ip
    ip="$(kubectl get nodes -o jsonpath='{range .items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane)]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
    if [[ -z "${ip}" ]]; then
        ip="$(kubectl get nodes -o jsonpath='{range .items[?(@.metadata.labels.node-role=="master")]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
    fi
    printf '%s' "${ip}"
}

# Получить IP любого worker-узла (или control-plane, если worker-ов нет)
gateway_access_ip() {
    local ip
    ip="$(control_plane_ip)"
    if [[ -n "${ip}" ]]; then
        printf '%s\n' "${ip}"
        return 0
    fi
    kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | head -n1 || true
    return 0
}

# Остановить фоновые процессы (port-forward и т.п.) безопасно:
# пустой или нулевой PID пропускаем, иначе `kill 0` убил бы всю группу процесса.
kill_bg() {
    local pid
    for pid in "$@"; do
        [[ -n "${pid}" && "${pid}" != "0" ]] || continue
        kill "${pid}" 2>/dev/null || true
    done
}

# --- Прочее --------------------------------------------------------------------

# Детерминированный sha256 файла (или stdin, если аргумент "-")
sha256_of() {
    local src="${1:-}"
    if command -v sha256sum >/dev/null 2>&1; then
        if [[ "${src}" == "-" ]]; then
            sha256sum | awk '{print $1}'
        else
            sha256sum "${src}" | awk '{print $1}'
        fi
    else
        if [[ "${src}" == "-" ]]; then
            shasum -a 256 | awk '{print $1}'
        else
            shasum -a 256 "${src}" | awk '{print $1}'
        fi
    fi
}

# Ожидание произвольного условия (функция проверки), с таймаутом
retry_until() {
    local timeout="$1" interval="${2:-3}" desc="$3"; shift 3
    local deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        if "$@"; then return 0; fi
        sleep "${interval}"
    done
    warn "Таймаут ${timeout}s при ожидании: ${desc}"
    return 1
}
