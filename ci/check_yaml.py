#!/usr/bin/env python3
"""Проверка синтаксиса и базовой структуры YAML-файлов репозитория.

Не требует установленного Kubernetes: проверяет, что файлы разбираются,
а Kubernetes-манифесты содержат обязательные поля apiVersion/kind/metadata.
Используется в CI (см. ci/lint.sh).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML не установлен: pip install pyyaml")
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent

# Каталоги с Kubernetes-манифестами: проверяем структуру ресурсов.
MANIFEST_DIRS = ["deploy"]

# Каталоги с прочим YAML (values для Helm, workflow CI): достаточно корректного
# синтаксиса и верхнеуровневого отображения, требования kind/metadata неприменимы.
PLAIN_DIRS = ["helm-values", ".github/workflows"]

# Шаблоны kubeadm: содержат плейсхолдеры __NAME__, поэтому проверяем только
# синтаксис YAML.
TEMPLATE_FILES = [
    REPO_ROOT / "hack" / "cluster" / "kubeadm-config.yaml",
    REPO_ROOT / "hack" / "cluster" / "kubeadm-join-config.yaml",
]

# Ресурсы, для которых namespace не требуется: они либо кластерные,
# либо пространство имён задаётся вне манифеста.
CLUSTER_SCOPED = {
    "Namespace",
    "ClusterRole",
    "ClusterRoleBinding",
    "CustomResourceDefinition",
    "GatewayClass",
    "PriorityClass",
    "PersistentVolume",
    "APIService",
    "MutatingWebhookConfiguration",
    "ValidatingWebhookConfiguration",
}

errors: list[str] = []
checked = 0

# Полные DNS-имена внутри кластера: <service>.<namespace>.svc.cluster.local.
# Второй сегмент обязан совпадать с namespace, который реально объявлен
# в манифестах. Ошибка здесь невидима при статическом анализе схем: манифест
# остаётся валидным, но в рантайме DNS не разрешится и компонент молча
# не свяжется (исторически здесь был потерян namespace elasticsearch).
FQDN_RE = re.compile(
    r"\b([a-z0-9](?:[-a-z0-9]*[a-z0-9])?)\.([a-z0-9](?:[-a-z0-9]*[a-z0-9])?)"
    r"\.svc\.cluster\.local\b"
)

# Значения по умолчанию для переменных подстановки, которые не разрешаются
# без внешнего состояния: их нельзя проверять.
FQDN_ALLOW = {"localhost"}


def collect_namespaces(docs_by_path: dict[Path, list]) -> set[str]:
    """Все namespace'ы, объявленные в манифестах, плюс Namespace-ресурсы."""
    found: set[str] = set()
    for docs in docs_by_path.values():
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            meta = doc.get("metadata")
            if not isinstance(meta, dict):
                continue
            ns = meta.get("namespace")
            if isinstance(ns, str) and ns:
                found.add(ns)
            if doc.get("kind") == "Namespace" and meta.get("name"):
                found.add(meta["name"])
    return found


def collect_fqdn_refs(docs_by_path: dict[Path, list]) -> list[tuple[Path, int, str, str]]:
    """Найти полные DNS-имена вида <svc>.<ns>.svc.cluster.local."""
    hits: list[tuple[Path, int, str, str]] = []
    for path, docs in docs_by_path.items():
        try:
            raw = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for lineno, line in enumerate(raw.splitlines(), 1):
            for match in FQDN_RE.finditer(line):
                svc, ns = match.group(1), match.group(2)
                if ns in FQDN_ALLOW or svc in FQDN_ALLOW:
                    continue
                hits.append((path, lineno, svc, ns))
    return hits


def add_error(msg: str) -> None:
    errors.append(msg)


def rel(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT)).replace("\\", "/")


def read_versions_env(key: str) -> str | None:
    """Прочитать скалярное значение из versions.env (формат KEY="value")."""
    env_file = REPO_ROOT / "versions.env"
    if not env_file.is_file():
        return None
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"')
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1)
    return None


def parse(path: Path) -> list | None:
    """Разобрать файл. Возвращает список документов или None при ошибке."""
    try:
        return list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    except yaml.YAMLError as exc:
        add_error(f"{rel(path)}: ошибка YAML: {exc}")
        return None


def check_kustomization(path: Path, docs: list) -> None:
    if not docs:
        add_error(f"{rel(path)}: пустой kustomization.yaml")
        return
    for i, doc in enumerate(docs):
        if not isinstance(doc, dict):
            add_error(f"{rel(path)}[doc {i}]: документ не является словарём")
            continue
        if doc.get("kind") != "Kustomization":
            add_error(f"{rel(path)}[doc {i}]: ожидался kind: Kustomization, получено {doc.get('kind')!r}")
        if doc.get("apiVersion") != "kustomize.config.k8s.io/v1beta1":
            add_error(f"{rel(path)}[doc {i}]: неожиданный apiVersion {doc.get('apiVersion')!r}")
        resources = doc.get("resources")
        if resources is None:
            add_error(f"{rel(path)}[doc {i}]: отсутствует секция resources")
        elif not isinstance(resources, list) or not resources:
            add_error(f"{rel(path)}[doc {i}]: resources должен быть непустым списком")
        else:
            for res in resources:
                if not isinstance(res, str):
                    add_error(f"{rel(path)}[doc {i}]: ресурс {res!r} не является строкой")
                elif (path.parent / res).exists() is False and not res.startswith(("http://", "https://", "git@")):
                    add_error(f"{rel(path)}[doc {i}]: ресурс '{res}' не найден в каталоге")

        for key in ("namespace", "namePrefix", "commonLabels", "commonAnnotations"):
            if key in doc:
                add_error(
                    f"{rel(path)}[doc {i}]: не используйте '{key}' — "
                    "ресурсы манифеста уже содержат явный namespace"
                )


def check_manifest(path: Path, docs: list) -> None:
    if not docs:
        add_error(f"{rel(path)}: пустой файл")
        return
    for i, doc in enumerate(docs):
        if doc is None:
            continue
        if not isinstance(doc, dict):
            add_error(f"{rel(path)}[doc {i}]: документ не является словарём")
            continue

        kind = doc.get("kind")
        api = doc.get("apiVersion")
        meta = doc.get("metadata")
        where = f"{rel(path)}[doc {i}]"

        if not kind:
            add_error(f"{where}: отсутствует kind")
        if not api:
            add_error(f"{where}: отсутствует apiVersion")
        if not isinstance(meta, dict):
            add_error(f"{where}: отсутствует или неверный metadata")
            continue
        if not meta.get("name"):
            add_error(f"{where}: kind={kind} без metadata.name")
        if kind not in CLUSTER_SCOPED and not meta.get("namespace"):
            add_error(
                f"{where}: kind={kind} без metadata.namespace — "
                "namespace указан явно, чтобы kustomize его не переопределял"
            )
        if kind == "Pod":
            add_error(f"{where}: Pod нельзя применять напрямую, создавайте его через контроллер")


def check_plain(path: Path, docs: list) -> None:
    if not docs:
        add_error(f"{rel(path)}: пустой файл")
        return
    for i, doc in enumerate(docs):
        if doc is None:
            continue
        if not isinstance(doc, dict):
            add_error(f"{rel(path)}[doc {i}]: ожидался словарь на верхнем уровне")


def check_workflow(path: Path, docs: list) -> None:
    check_plain(path, docs)
    for i, doc in enumerate(docs):
        if not isinstance(doc, dict):
            continue
        where = f"{rel(path)}[doc {i}]"
        if "jobs" not in doc:
            add_error(f"{where}: workflow без секции jobs")
            continue
        if not isinstance(doc["jobs"], dict) or not doc["jobs"]:
            add_error(f"{where}: jobs должен быть непустым словарём")
            continue
        for job_name, job in doc["jobs"].items():
            if not isinstance(job, dict) or "steps" not in job:
                add_error(f"{where}: job '{job_name}' без steps")


def check_gateway_placement(docs_by_path: dict[Path, list]) -> None:
    """Проверить, что Gateway лежит в GATEWAY_NAMESPACE и на него ссылаются
    корректно.

    NGINX Gateway Fabric создаёт data plane (поды NGINX и Service с NodePort)
    в namespace ресурса Gateway: поля spec.kubernetes.namespace в CRD
    NginxProxy не существует, выбрать другой namespace невозможно. Отсюда
    два требования, нарушение которых ломает развёртывание молча:

    1. Gateway обязан находиться в GATEWAY_NAMESPACE из versions.env. Иначе
       data plane попадёт в mtc-demo под default-deny-all (его egress к
       приложению заблокирован) и NodePort Service окажется не там, где его
       ищет hack/deploy.sh.
    2. HTTPRoute, живущий в другом namespace, обязан указывать namespace
       в parentRef — иначе он не привяжется к шлюзу.
    """
    global checked

    expected = read_versions_env("GATEWAY_NAMESPACE")
    if not expected:
        add_error("versions.env: не найден GATEWAY_NAMESPACE")
        return

    gateways: dict[str, str] = {}
    routes: list[tuple[Path, dict, str]] = []

    for path, docs in docs_by_path.items():
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            kind = doc.get("kind")
            ns = (doc.get("metadata") or {}).get("namespace")
            name = (doc.get("metadata") or {}).get("name")
            if kind == "Gateway" and name:
                gateways[name] = ns
                if ns != expected:
                    add_error(
                        f"{rel(path)}: Gateway '{name}' в namespace '{ns}', "
                        f"ожидался '{expected}' (GATEWAY_NAMESPACE). "
                        f"NGF создаст data plane в namespace '{ns}'."
                    )
                else:
                    checked += 1
            elif kind == "HTTPRoute" and name:
                routes.append((path, doc, ns))

    if not gateways:
        return

    for path, doc, route_ns in routes:
        for parent in (doc.get("spec") or {}).get("parentRefs") or []:
            if not isinstance(parent, dict):
                continue
            target = parent.get("name")
            if target not in gateways:
                continue
            ref_ns = parent.get("namespace") or route_ns
            if ref_ns != gateways[target]:
                add_error(
                    f"{rel(path)}: HTTPRoute '{doc['metadata']['name']}' ссылается "
                    f"на Gateway '{target}' через namespace '{ref_ns}', а сам Gateway "
                    f"в '{gateways[target]}' — маршрут не привяжется к шлюзу."
                )
            elif parent.get("namespace") != gateways[target]:
                add_error(
                    f"{rel(path)}: HTTPRoute '{doc['metadata']['name']}' в namespace "
                    f"'{route_ns}' ссылается на Gateway '{target}' в "
                    f"'{gateways[target]}' без явного parentRef.namespace."
                )
            else:
                checked += 1


def main() -> int:
    global checked

    for path in TEMPLATE_FILES:
        if not path.exists():
            add_error(f"{rel(path)}: файл шаблона отсутствует")
            continue
        if parse(path) is not None:
            print(f"OK   {rel(path)} (шаблон kubeadm, проверен только синтаксис)")
            checked += 1

    manifest_docs: dict[Path, list] = {}

    for target in MANIFEST_DIRS:
        base = REPO_ROOT / target
        if not base.exists():
            add_error(f"{target}: каталог отсутствует")
            continue
        for path in sorted(base.rglob("*.yaml")) + sorted(base.rglob("*.yml")):
            docs = parse(path)
            if docs is None:
                continue
            checked += 1
            manifest_docs[path] = docs
            if path.name == "kustomization.yaml":
                check_kustomization(path, docs)
            else:
                check_manifest(path, docs)

    for target in PLAIN_DIRS:
        base = REPO_ROOT / target
        if not base.exists():
            add_error(f"{target}: каталог отсутствует")
            continue
        for path in sorted(base.rglob("*.yaml")) + sorted(base.rglob("*.yml")):
            docs = parse(path)
            if docs is None:
                continue
            checked += 1
            if target == ".github/workflows":
                check_workflow(path, docs)
            else:
                check_plain(path, docs)

    # --- Кросс-пространственные DNS-имена против реальных namespace'ов ------
    known_ns = collect_namespaces(manifest_docs)
    hits = collect_fqdn_refs(manifest_docs)
    if hits:
        print(f"OK   проверено полных DNS-имён внутри кластера: {len(hits)}")
        for path, lineno, svc, ns in hits:
            if ns not in known_ns:
                add_error(
                    f"{rel(path)}:{lineno}: DNS-имя '{svc}.{ns}.svc.cluster.local' "
                    f"ссылается на namespace '{ns}', которого нет в манифетах "
                    f"(известные: {', '.join(sorted(known_ns)) or 'нет'}). "
                    f"В рантайме имя не разрешится."
                )
            else:
                checked += 1

    # --- Размещение Gateway и ссылки HTTPRoute на него --------------------
    check_gateway_placement(manifest_docs)

    for err in errors:
        print(f"FAIL {err}", file=sys.stderr)

    if errors:
        print(f"\nПроблем: {len(errors)}.", file=sys.stderr)
        return 1

    print(f"Проверено файлов: {checked}. Проблем не найдено.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
