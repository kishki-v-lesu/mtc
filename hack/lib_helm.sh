#!/usr/bin/env bash
set -uo pipefail

# Вспомогательная функция для вычисления хэша параметров релиза
# Параметры: release_name, namespace, chart_version, values_file, set_args...
compute_release_hash() {
    local name="$1"
    local ns="$2"
    local ver="$3"
    local val_file="$4"
    shift 4
    
    # Собираем все входные данные: версия чарта, содержимое файла values и все --set аргументы
    {
        echo "${ver}"
        if [[ -f "${val_file}" ]]; then cat "${val_file}"; fi
        printf '%s\n' "$@"
    } | sha256sum | awk '{print $1}'
}

# Функция безопасного обновления Helm-релиза с проверкой изменений
# Аргументы: release_name, namespace, chart_repo, chart_version, values_file, [set_args...]
helm_upgrade_idempotent() {
    local name="$1"
    local ns="$2"
    local repo="$3"
    local ver="$4"
    local val_file="$5"
    shift 5
    
    local current_hash
    current_hash=$(compute_release_hash "${name}" "${ns}" "${ver}" "${val_file}" "$@")
    
    # Храним хэш в ConfigMap в пространстве имен релиза
    local hash_cm="helm-hash-${name}"
    local stored_hash
    stored_hash=$(kubectl -n "${ns}" get configmap "${hash_cm}" -o jsonpath='{.data.hash}' 2>/dev/null || true)
    
    if [[ "${current_hash}" == "${stored_hash}" ]]; then
        # Проверяем, существует ли вообще релиз
        if helm list -n "${ns}" --filter "^${name}$" | grep -q "${name}"; then
            ok "Релиз ${name} уже в актуальном состоянии (хэш совпадает), пропускаем обновление."
            return 0
        fi
    fi
    
    # Если хэш отличается или релиза нет — обновляем
    local helm_args=(
        upgrade --install "${name}"
        "${repo}"
        --version "${ver}"
        --namespace "${ns}"
        --create-namespace
        --values "${val_file}"
        --timeout "${TIMEOUT}"
    )
    
    # Добавляем --set аргументы
    for arg in "$@"; do
        helm_args+=("${arg}")
    done
    
    [[ "${DRY_RUN}" == "true" ]] && helm_args+=(--dry-run=client) || helm_args+=(--wait)
    
    helm "${helm_args[@]}"
    
    # Обновляем хэш после успешного развертывания
    kubectl -n "${ns}" create configmap "${hash_cm}" \
        --from-literal=hash="${current_hash}" \
        -o yaml --dry-run=client | kubectl apply -f - >/dev/null 2>&1
        
    ok "${name} установлен/обновлен."
}
