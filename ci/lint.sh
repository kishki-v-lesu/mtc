#!/usr/bin/env bash
#
# Проверки качества, которые выполняет CI (.github/workflows/ci.yml).
# Скрипт не требует Kubernetes-кластера — только статический анализ.
#
#   ./ci/lint.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
pass() { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
fail() { printf '\033[33m[FAIL]\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# --- 1. Синтаксис bash-скриптов ---------------------------------------------------
step "Синтаксис bash-скриптов"
while IFS= read -r script; do
    if bash -n "${script}" 2>/tmp/bashn.err; then
        pass "$(basename "${script}")"
    else
        fail "$(basename "${script}"): $(cat /tmp/bashn.err)"
    fi
done < <(find "${REPO_ROOT}/hack" "${REPO_ROOT}/ci" -name '*.sh' -type f | sort)

# Проверяем, что все скрипты помечены как исполняемые.
# Проверять бит в индексе git, а не [[ -x ]] в файловой системе: на Windows и в
# MSYS любой .sh выглядит исполняемым, поэтому локально проверка проходит, а
# на Linux-раннере падает и роняет весь CI.
step "Права на исполнение"
IN_GIT_REPO=false
if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    IN_GIT_REPO=true
fi
while IFS= read -r script; do
    rel="${script#"${REPO_ROOT}"/}"
    if [[ "${IN_GIT_REPO}" == "true" ]]; then
        mode="$(git -C "${REPO_ROOT}" ls-files -s -- "${rel}" | awk '{print $1}')"
        if [[ "${mode}" == "100755" ]]; then
            pass "$(basename "${script}") executable (в git)"
        elif [[ -z "${mode}" ]]; then
            fail "$(basename "${script}") не отслеживается git"
        else
            fail "$(basename "${script}"): в git режим ${mode}, нужен 100755"
            fail "  исправление: git update-index --chmod=+x ${rel} && git commit -m 'Make script executable'"
        fi
    elif [[ -x "${script}" ]]; then
        pass "$(basename "${script}") executable"
    else
        fail "$(basename "${script}") не имеет бита +x"
    fi
done < <(find "${REPO_ROOT}/hack" "${REPO_ROOT}/ci" -name '*.sh' -type f | sort)

# --- 2. YAML-манифесты -----------------------------------------------------------
step "Синтаксис YAML"
if command -v python3 >/dev/null 2>&1; then
    if python3 "${REPO_ROOT}/ci/check_yaml.py"; then
        pass "все YAML-файлы корректны"
    else
        fail "см. ошибки выше"
    fi
else
    printf '\033[33m[SKIP]\033[0m python3 недоступен — проверка YAML пропущена\n'
fi

# --- 3. kubeconform --------------------------------------------------------------
step "Валидация Kubernetes-манифестов (kubeconform)"
if command -v kubeconform >/dev/null 2>&1; then
    # Два источника схем:
    #   default      — встроенные схемы Kubernetes (Deployment, Service, ...);
    #   CRDs-catalog — Gateway API, Prometheus Operator и другие CRD.
    # -ignore-missing-schemas оставлен на случай новых CRD, которых ещё нет
    # в каталоге: неизвестный CRD не должен ронять сборку целиком.
    if kubeconform -strict -ignore-missing-schemas -summary \
            -kubernetes-version "${KUBECONFORM_K8S_VERSION:-1.37.0}" \
            -schema-location default \
            -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
            "${REPO_ROOT}/deploy"; then
        pass "kubeconform: расхождений со схемами Kubernetes и CRD нет"
    else
        fail "kubeconform обнаружил расхождения со схемами"
    fi
else
    printf '\033[33m[SKIP]\033[0m kubeconform не установлен (см. .github/workflows/ci.yml)\n'
fi

# --- 4. yamllint -----------------------------------------------------------------
step "Стиль YAML (yamllint)"
if command -v yamllint >/dev/null 2>&1; then
    if yamllint -c "${REPO_ROOT}/ci/.yamllint" \
            "${REPO_ROOT}/deploy" \
            "${REPO_ROOT}/helm-values" \
            "${REPO_ROOT}/.github" \
            "${REPO_ROOT}/hack/cluster/kubeadm-config.yaml" \
            "${REPO_ROOT}/hack/cluster/kubeadm-join-config.yaml"; then
        pass "yamllint: нарушений стиля нет"
    else
        fail "yamllint обнаружил нарушения стиля"
    fi
else
    printf '\033[33m[SKIP]\033[0m yamllint не установлен\n'
fi

# --- 5. shellcheck ---------------------------------------------------------------
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    mapfile -t scripts < <(find "${REPO_ROOT}/hack" "${REPO_ROOT}/ci" -name '*.sh' -type f | sort)
    if shellcheck --severity=warning --external-sources "${scripts[@]}"; then
        pass "shellcheck: предупреждений нет"
    else
        fail "shellcheck обнаружил предупреждения"
    fi
else
    printf '\033[33m[SKIP]\033[0m shellcheck не установлен\n'
fi

# --- 6. Плейсхолдеры шаблонов kubeadm --------------------------------------------
# Каждый плейсхолдер __X__ в шаблонах обязан подставляться хотя бы одним скриптом:
# иначе kubeadm получит файл с "__NODE_IP__" вместо адреса.
step "Плейсхолдеры шаблонов kubeadm подставляются скриптами"
tmpl_ph="$(grep -hvE '^[[:space:]]*#' "${REPO_ROOT}"/hack/cluster/*.yaml 2>/dev/null | grep -ohE '__[A-Z_]+__' | sort -u || true)"
script_ph="$(grep -ohE '__[A-Z_]+__' "${REPO_ROOT}"/hack/cluster/*.sh 2>/dev/null | sort -u || true)"
if [[ -z "${tmpl_ph}" ]]; then
    printf '\033[33m[INFO]\033[0m плейсхолдеры в шаблонах не найдены\n'
else
    missing_ph="$(comm -23 <(printf '%s\n' "${tmpl_ph}") <(printf '%s\n' "${script_ph}"))"
    if [[ -n "${missing_ph}" ]]; then
        fail "плейсхолдеры не подставляются ни одним скриптом: $(printf '%s' "${missing_ph}" | tr '\n' ' ')"
    else
        pass "подставляются все плейсхолдеры шаблонов: $(printf '%s' "${tmpl_ph}" | tr '\n' ' ')"
    fi
fi

# --- 7. Образы зафиксированы в versions.env ---------------------------------------
# Требование о воспроизводимости: каждый образ в манифестах должен быть
# прописан в versions.env, иначе при обновлении его легко забыть.
step "Образы из манифестов присутствуют в versions.env"
undeclared=""
while IFS= read -r img; do
    [[ -n "${img}" ]] || continue
    grep -qF "\"${img}\"" "${REPO_ROOT}/versions.env" || undeclared="${undeclared} ${img}"
done < <(grep -rhoE '^[[:space:]]*image:[[:space:]]*[^[:space:]#]+' "${REPO_ROOT}"/deploy \
         | sed -E 's/^[[:space:]]*image:[[:space:]]*//' | sort -u)
if [[ -n "${undeclared}" ]]; then
    fail "образы не зафиксированы в versions.env:${undeclared}"
else
    pass "все образы из deploy/ зафиксированы в versions.env"
fi

# --- 8. Секреты в репозитории ----------------------------------------------------
step "Проверка отсутствия секретов в репозитории"
if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    # Ищем типичные маркеры приватных ключей и токенов.
    # --untracked обязателен: без него git grep смотрит только индекс и на
    # свежем репозитории без коммитов проверка проходит вхолостую.
    if git -C "${REPO_ROOT}" grep --untracked -InE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|xox[baprs]-|ghp_[A-Za-z0-9]{20,}' -- . \
        | grep -v '^ci/lint.sh' >/dev/null 2>&1; then
        fail "в репозитории найдены похожие на секреты строки"
        git -C "${REPO_ROOT}" grep --untracked -InE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|xox[baprs]-|ghp_[A-Za-z0-9]{20,}' -- . | grep -v '^ci/lint.sh'
    else
        pass "приватных ключей и токенов не найдено"
    fi
    if git -C "${REPO_ROOT}" ls-files --error-unmatch .secrets >/dev/null 2>&1; then
        fail ".secrets попал под контроль версий — добавьте его в .gitignore"
    else
        pass ".secrets не отслеживается Git"
    fi
else
    printf '\033[33m[SKIP]\033[0m не git-репозиторий — проверка секретов пропущена\n'
fi

# --- Итог ------------------------------------------------------------------------
printf '\n'
if [[ ${FAILURES} -gt 0 ]]; then
    printf '\033[31mПровалено проверок: %s\033[0m\n' "${FAILURES}"
    exit 1
fi
printf '\033[32mВсе проверки качества пройдены.\033[0m\n'
