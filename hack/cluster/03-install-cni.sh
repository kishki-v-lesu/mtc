#!/usr/bin/env bash
#
# Шаг 3. Установка CNI (Calico) и Storage provisioner (local-path).
# Запускается ТОЛЬКО на control-plane узле, ПОСЛЕ 01-init-control-plane.sh.
#
#   sudo ./03-install-cni.sh
#
# Почему Calico, а не flannel: Calico является CNI, который умеет принудительно
# применять NetworkPolicy. В этом решении NetworkPolicy — обязательная часть
# подхода к безопасности, и flannel их просто игнорирует.
#
# Почему local-path-provisioner: в кластере, собранном kubeadm, StorageClass
# по умолчанию отсутствует. Без него невозможно создать PVC (например, для
# Elasticsearch).
#
# Идемпотентен: повторный запуск ничего не ломает.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPT_DIR}/../lib.sh"
load_versions "${SCRIPT_DIR}/../../versions.env"

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

section "MTC Engineer Hack — установка CNI и Storage provisioner"

require_cmd kubectl curl
require_cluster

# --- Calico ---------------------------------------------------------------------
section "1/2 Calico ${CALICO_VERSION}"
# URL манифеста берём из versions.env — единый источник версий и ссылок
TMP_MANIFEST="$(mktemp /tmp/calico.XXXXXX.yaml)"
trap 'rm -f "${TMP_MANIFEST}"' EXIT

if kubectl get daemonset calico-node -n kube-system >/dev/null 2>&1; then
    ok "Calico уже установлена. Пропускаем установку."
else
    log "Загрузка манифеста Calico..."
    curl -fsSL --retry 5 --retry-delay 3 -o "${TMP_MANIFEST}" "${CALICO_MANIFEST_URL}"
    log "SHA256 манифеста: $(sha256_of "${TMP_MANIFEST}")"
    kubectl apply -f "${TMP_MANIFEST}"

    log "Ожидание готовности Calico (до 10 минут)..."
    kubectl -n kube-system rollout status daemonset/calico-node --timeout=600s
    kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=600s
    ok "Calico установлена и готова."
fi

# Проверяем, что все узлы перешли в Ready (CNI поднялся на каждом узле)
log "Текущее состояние узлов:"
kubectl get nodes -o wide
if ! kubectl wait --for=condition=Ready nodes --all --timeout=300s; then
    die "Не все узлы перешли в состояние Ready. Проверьте: kubectl describe node <node>"
fi

# --- local-path-provisioner ------------------------------------------------------
section "2/2 Storage provisioner (local-path) ${LOCAL_PATH_PROVISIONER_VERSION}"
TMP_LP="$(mktemp /tmp/local-path.XXXXXX.yaml)"
trap 'rm -f "${TMP_MANIFEST}" "${TMP_LP}"' EXIT

if kubectl get deploy local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
    ok "local-path-provisioner уже установлен. Пропускаем."
else
    log "Загрузка манифеста local-path-provisioner..."
    curl -fsSL --retry 5 --retry-delay 3 -o "${TMP_LP}" "${LOCAL_PATH_MANIFEST_URL}"
    log "SHA256 манифеста: $(sha256_of "${TMP_LP}")"
    kubectl apply -f "${TMP_LP}"
    kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s
    ok "local-path-provisioner установлен."
fi

# local-path создаёт StorageClass с именем local-path и сам помечает его default,
# но проверяем явно: jsonpath-фильтр по аннотации вида
# ?(@.metadata.annotations.storageclass\.kubernetes\.io/...=="true") внутри
# kubectl jsonpath работает нестабильно из-за точки в имени аннотации, поэтому
# читаем аннотацию нужного StorageClass напрямую.
SC_IS_DEFAULT="$(kubectl get storageclass local-path \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' \
    2>/dev/null || true)"
if [[ "${SC_IS_DEFAULT}" != "true" ]]; then
    warn "StorageClass 'local-path' не помечен как default. Помечаем..."
    kubectl annotate storageclass local-path \
        storageclass.kubernetes.io/is-default-class="true" --overwrite >/dev/null
    ok "StorageClass 'local-path' назначен default."
else
    ok "StorageClass 'local-path' уже является default."
fi

# --- Итоговая проверка -----------------------------------------------------------
section "Итоговая проверка кластера"
kubectl get nodes -o wide
# sed вместо head: при `sort | head` head завершается первым, sort ловит SIGPIPE,
# а с `set -o pipefail` это ломает весь скрипт на самом последнем шаге.
kubectl get pods -n kube-system --no-headers | sort -u | sed -n '1,20p'
kubectl get storageclass

section "Готово: кластер полностью развёрнут"
cat <<EOF
Версия Kubernetes: $(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "${KUBERNETES_VERSION}")
CNI:               Calico ${CALICO_VERSION}
StorageClass:      local-path (default)

Теперь разверните решение:

  ./hack/deploy.sh        # или  make deploy
EOF
