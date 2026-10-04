# MTC Engineer Hack — веб-приложение в Kubernetes с Gateway API, мониторингом и логированием

Решение хакатона: развёртывание демонстрационного веб-приложения в Kubernetes,
организация доступа через **Gateway API**, сбор метрик через **Prometheus** и
сбор логов через **Filebeat → Elasticsearch** — всё автоматизировано и
воспроизводится по инструкции на **Ubuntu 24.04** и **kubeadm**.

```
Пользователь ──▶ [Gateway API / NGINX Gateway Fabric] ──▶ [NGINX "Hello World!"]
                                    │                            │
                                    │                     ┌──────┴───────┐
                                    │                     │              │
                                    ▼                     ▼              ▼
                            [HTTPRoute 90/10]     [nginx-prometheus-  [Filebeat]
                                                     exporter]            │
                                                                      ┌────▼─────┐
                                                                      │Elasticsearch│
                                                                      └──────────┘
                                    ┌──────────────────────────────────────────┐
                                    │  Prometheus ◀── ServiceMonitor'ы        │
                                    │  Grafana      ◀── дашборд + node-exporter│
                                    └──────────────────────────────────────────┘
```

---

## Содержание

1. [Быстрый старт](#быстрый-старт)
2. [Что реализовано](#что-реализовано)
3. [Архитектура](#архитектура)
4. [Технологии и версии](#технологии-и-версии)
5. [Требования к среде](#требования-к-среде)
6. [Развёртывание](#развертывание)
7. [Проверка](#проверка)
8. [Дополнительные возможности](#дополнительные-возможности)
9. [Безопасность и надёжность](#безопасность-и-надёжность)
10. [Структура репозитория](#структура-репозитория)
11. [Известные ограничения](#известные-ограничения)
12. [Развитие решения](#развитие-решения)

---

## Быстрый старт

```bash
# 1. На чистой VM Ubuntu 24.04 — подготовить узел и развернуть кластер
sudo ./hack/cluster/00-prepare-node.sh
sudo ./hack/cluster/01-init-control-plane.sh
sudo ./hack/cluster/03-install-cni.sh

# 2. Развернуть решение (одна команда, идемпотентна)
./hack/deploy.sh

# 3. Проверить, что всё работает
./hack/verify.sh
```

Проверка доступности приложения через Gateway API:

```bash
curl http://<IP-узла>:30080/
# Hello World!
```

Через `make`:

```bash
make cluster     # бутстрап кластера (от root)
make deploy      # развернуть решение
make verify      # проверить все требования задания
make smoke       # нагрузочный тест + проверка метрик и логов
make help        # все цели
```

---

## Что реализовано

| Требование задания | Реализация | Как проверить |
|---|---|---|
| Kubernetes-кластер на kubeadm | Ubuntu 24.04, kubeadm v1.37.1, containerd, CNI Calico | `kubectl get nodes` |
| Демонстрационное веб-приложение | `nginxinc/nginx-unprivileged:1.29.4-alpine`, отдаёт `Hello World!`, пишет access-логи в JSON | `kubectl -n mtc-demo exec deploy/web -c nginx -- cat /var/log/nginx/access.log` |
| Gateway API | NGINX Gateway Fabric v2.7.2 (NGINX OSS), CRD Gateway API v1.6.1, ресурсы `GatewayClass` / `Gateway` / `HTTPRoute` | `curl http://<NODE_IP>:30080/` |
| Мониторинг | Prometheus + Grafana (kube-prometheus-stack 91.9.0), метрики NGINX через `nginx-prometheus-exporter`, метрики узлов и Kubernetes | `hack/verify.sh`, раздел «Проверка мониторинга» |
| Логирование | Filebeat 9.5.4 (sidecar) → Elasticsearch 9.5.4, индекс `nginx-logs-*` | `hack/verify.sh`, раздел «Проверка логирования» |
| Автоматизация | `hack/deploy.sh` + kustomize + Helm, идемпотентно | `./hack/test-idempotency.sh` |
| Документация | Этот README + `docs/ARCHITECTURE.md` + `docs/PASSPORT.md` | — |

---

## Архитектура

```
                          ┌───────────────────────────────────────────────┐
   Пользователь           │  namespace: nginx-gateway                    │
   (curl / браузер)       │                                               │
        │                 │  ┌─────────────────────────────────────┐      │
        │                 │  │ NGINX Gateway Fabric 2.7.2          │      │
        │                 │  │  • control plane (Deployment)       │      │
        │                 │  │  • GatewayClass: nginx              │      │
        │                 │  └──────────────┬──────────────────────┘      │
        │                 │                 │ настраивает                  │
│                 │  ┌──────────────▼──────────────────────┐      │
         │                 │  │ Gateway: web-gateway                │      │
         │                 │  │   • listener HTTP:80                 │      │
         │                 │  │   • resource: nginx                  │      │
         │                 │  │   • data plane создаётся NGF здесь   │      │
         ▼                 │  └──────────────┬──────────────────────┘      │
    ┌─────────┐            │  ┌──────────────▼──────────────────────┐      │
    │  curl   │            │  │ data plane NGINX (2 реплики)        │      │
    └────┬────┘            │  │ Service type=NodePort 30080→80      │      │
   │  curl   │            │  └──────────────┬──────────────────────┘      │
   └────┬────┘            └─────────────────┼─────────────────────────────┘
        │                                    │ проксирует
        │            ┌───────────────────────▼──────────────────────────┐
│            │  namespace: mtc-demo                               │
         │            │                                                       │
         │            │  HTTPRoute web-route               (90% / 10%)      │
         │            │    ├─ path /canary → Service web-canary            │
         │            │    └─ path /      → web (90) + canary (10)         │
         │            │                                                       │
         │            │  HTTPRoute web-hostname-route                      │
         │            │    Host: web.mtc.local  → web 100%                 │
         │            │                                                       │
        │            │  ┌────────────────────────────────────────────────┐  │
        │            │  │ Deployment: web  (3 реплики, PDB minAvailable=2)│  │
        │            │  │  ┌────────────┬──────────────┬─────────────┐  │  │
        │            │  │  │ nginx :8080│ exporter     │ filebeat    │  │  │
        │            │  │  │            │ :9113        │ → ES :9200  │  │  │
        │            │  │  └────────────┴──────────────┴─────────────┘  │  │
        │            │  │  ConfigMap web-nginx-config (nginx.conf)        │  │
        │            │  │  ConfigMap filebeat-config  (filebeat.yml)     │  │
        │            │  │  emptyDir /var/log/nginx — общий том            │  │
        │            │  └────────────────────────────────────────────────┘  │
        │            │                                                       │
        │            │  ┌────────────────────────────────────────────────┐  │
        └───────────▶│  │ Service: web (ClusterIP:80→8080)               │  │
                     │  │ Service: web-metrics (headless:9113)          │  │
                     │  │ Deployment: web-canary (1 реплика)            │  │
                     │  │ StatefulSet→Deployment: elasticsearch (1) + PVC│  │
                     │  │ NetworkPolicy: default-deny + 4 правила       │  │
                     │  └────────────────────────────────────────────────┘  │
                     └───────────────────────────────────────────────────────┘

   ┌────────────────────────────────────────────────────────────────────────┐
   │  namespace: monitoring                                                  │
   │  Prometheus (2 ЦОД в replicaSet) ◀── ServiceMonitor/PodMonitor           │
   │  Grafana      ◀── ConfigMap с дашбордом (sidecar, метка grafana_dashboard)│
   │  node-exporter, kube-state-metrics, kubelet/cAdvisor                    │
   └────────────────────────────────────────────────────────────────────────┘

   ┌────────────────────────────────────────────────────────────────────────┐
   │  kube-system: Calico (CNI + enforcement NetworkPolicy), CoreDNS        │
   └────────────────────────────────────────────────────────────────────────┘
```

Подробное описание компонентов и «почему именно так» — в
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Технологии и версии

Все версии зафиксированы в файле [`versions.env`](versions.env) — это
единственный файл, который нужно править при обновлении.

| Компонент | Версия | Роль |
|---|---|---|
| Ubuntu | 24.04 | ОС узлов кластера (требование задания) |
| Kubernetes | **v1.37.1** | Оркестратор (собирается kubeadm) |
| containerd | из `docker.com/linux/ubuntu` | CRI |
| Calico | v3.33.0 | CNI + enforcement NetworkPolicy |
| local-path-provisioner | v0.0.37 | StorageClass (в kubeadm его нет по умолчанию) |
| Gateway API | v1.6.1 (standard channel) | CRD `Gateway`, `GatewayClass`, `HTTPRoute` |
| NGINX Gateway Fabric | **v2.7.2** | Реализация Gateway API (NGINX OSS) |
| NGINX (приложение) | 1.29.4 (`nginx-unprivileged`, alpine) | Демонстрационное приложение |
| nginx-prometheus-exporter | v1.5.3 | Экспортёр метрик NGINX |
| kube-prometheus-stack | 91.9.0 | Prometheus + Grafana + node-exporter + kube-state-metrics |
| Prometheus | 3.15.0 | Сбор и хранение метрик |
| Grafana | 13.2.3 | Визуализация метрик |
| Filebeat | 9.5.4 | Сбор логов приложения |
| Elasticsearch | 9.5.4 | Централизованное хранение логов |
| Helm | 4.x | Установка NGINX Gateway Fabric и мониторинга |
| Kustomize | встроен в kubectl | Сборка манифестов |

Матрица совместимости (NGF 2.7.2 → Gateway API 1.6.1, Kubernetes 1.32+)
взята из официальной документации NGINX Gateway Fabric.

---

## Требования к среде

### Для запуска в кластере

| Параметр | Значение |
|---|---|
| ОС | Ubuntu 24.04 (x86_64 или arm64) |
| Ресурсов на control-plane VM | минимум 4 vCPU, **8 ГБ RAM**, 40 ГБ диск |
| worker-узлы | по необходимости, те же требования |
| Утилиты на машине, откуда запускается `deploy.sh` | `kubectl`, `helm`, `curl`, `jq` |
| Доступ в интернет | к реестрам `registry.k8s.io`, `ghcr.io`, `docker.io`, `docker.elastic.co`, `quay.io`, а также к `pkgs.k8s.io` и `dl.k8s.io` |

> **8 ГБ RAM — важно.** В решении одновременно работают Prometheus (до 2 ГБ),
> Grafana, Elasticsearch (до 2 ГБ) и NGINX. На 4 ГБ pod'ы будут вытеснены
> по OOM. Если ресурсов меньше, разверните минимальный вариант:
> `./hack/deploy.sh --skip-monitoring --skip-canary` и отключите Elasticsearch
> через `--skip-logging`.

### Рекомендуемая топология

Вариант A — **одна VM** (быстрее развернуть, снимать taint вручную):

```bash
sudo ./hack/cluster/00-prepare-node.sh
sudo ALLOW_SCHEDULE_ON_CONTROL_PLANE=true ./hack/cluster/01-init-control-plane.sh
sudo ./hack/cluster/03-install-cni.sh
```

Вариант B — **две VM** (рекомендуется заданием, честный кластер):

```bash
# На обеих VM
sudo ./hack/cluster/00-prepare-node.sh

# На control-plane VM
sudo ./hack/cluster/01-init-control-plane.sh
sudo ./hack/cluster/03-install-cni.sh
kubeadm token create --print-join-command   # скопировать вывод

# На worker VM
sudo JOIN_COMMAND='<вывод команды выше>' ./hack/cluster/02-join-worker.sh
```

---

## Развертывание

### Шаг 1. Подготовка узла

```bash
sudo ./hack/cluster/00-prepare-node.sh
```

Скрипт: обновляет систему, ставит зависимости, отключает swap, загружает
модули ядра (`overlay`, `br_netfilter`), выставляет sysctl (включая
`vm.max_map_count=262144`, необходимый Elasticsearch), устанавливает
containerd из официального репозитория Docker и kubeadm/kubelet/kubectl
**версии 1.37.1** с фиксацией пакетов (`apt-mark hold`).

Kubernetes-компоненты ставятся в два этапа. Сначала — штатный путь: apt-репозиторий
`pkgs.k8s.io/core:/stable:/v1.37/deb/`. Если репозиторий не отдаёт пакеты этой
минорной версии (community-репозиторий не гарантирует наличие всех минорных
версий, а суффикс пакета вроде `-1.1` — внутренняя деталь apt-нумерации),
скрипт автоматически переключается на официальные бинарники с
`dl.k8s.io/release/v1.37.1/bin/linux/amd64` и **проверяет SHA-256 каждого
архива** по опубликованной контрольной сумме. В этом варианте скрипт сам
создаёт systemd-юнит `kubelet` и drop-in `10-kubeadm.conf`; если юнит уже есть
(apt-вариант), он не трогается. Требуемый доступ в интернет — к `pkgs.k8s.io`
и `dl.k8s.io`.

Идемпотентен — можно запускать повторно.

### Шаг 2. Инициализация control-plane

```bash
sudo ./hack/cluster/01-init-control-plane.sh
```

Использует шаблон конфигурации [`hack/cluster/kubeadm-config.yaml`](hack/cluster/kubeadm-config.yaml)
(`kubeadm.k8s.io/v1beta4`), в котором явно заданы: версия Kubernetes, сети
под и сервисов, `criSocket`, режим автоповорота сертификатов kubelet,
пороги очистки образов и RBAC-режим API-сервера.

### Шаг 3. CNI и хранилище

```bash
sudo ./hack/cluster/03-install-cni.sh
```

Устанавливает Calico (выбран как CNI, умеющий **применять** NetworkPolicy —
flannel их игнорирует) и local-path-provisioner (в кластере kubeadm
StorageClass по умолчанию отсутствует). Оба шага идемпотентны.

### Шаг 4. Развёртывание решения

```bash
./hack/deploy.sh
```

Порядок операций:

1. **Префлайт** — версии kubectl/helm/Kubernetes, наличие Calico, проверка
   доступности зафиксированных образов через `crictl` (понятная ошибка сразу,
   а не в середине развёртывания).
2. **Gateway API CRD** v1.6.1 — скачивается релиз-ассет с проверкой SHA-256,
   применяется только если версия отличается.
3. **NGINX Gateway Fabric** v2.7.2 — `helm upgrade --install` из OCI-реестра
   `oci://ghcr.io/nginx/charts/nginx-gateway-fabric` с `--wait`.
4. **Мониторинг** — `helm upgrade --install` kube-prometheus-stack 91.9.0.
5. **Манифесты решения** — `kubectl apply --server-side` по каталогам
   (namespace → приложение → canary → шлюз → логирование → мониторинг → политики).
6. **Ожидание** — `Available` у Deployment'ов, `Programmed` у Gateway, `Ready`
   у Prometheus.

Полезные флаги:

```bash
./hack/deploy.sh --skip-monitoring   # без Prometheus и Grafana
./hack/deploy.sh --skip-logging      # без Elasticsearch и Filebeat
./hack/deploy.sh --skip-canary       # без canary-версии и traffic splitting
./hack/deploy.sh --skip-images       # не проверять наличие образов в registry
./hack/deploy.sh --dry-run           # показать, что будет сделано, ничего не меняя
./hack/deploy.sh --timeout 600s      # увеличить таймаут ожидания ресурсов
```

`--dry-run` полезен в двух случаях: проверить, что скрипт дойдёт до конца
на текущем кластере, и заранее увидеть список Helm-параметров, не создавая
релиз.

### Идемпотентность

`deploy.sh` можно запускать сколько угодно раз:

- манифесты применяются через `kubectl apply --server-side` (не `create`);
- Helm использует `upgrade --install`, а не `install`;
- CRD Gateway API пропускаются, если `bundle-version` уже совпадает;
- пароль Grafana генерируется один раз и хранится в `.secrets/`
  (каталог в `.gitignore`), а не в репозитории;
- скрипты подготовки кластера проверяют текущее состояние и выходят.

Проверка:

```bash
./hack/test-idempotency.sh
```

Скрипт снимает «отпечаток» состояния (реплики, образы, порты, IP-адреса,
условия Gateway/HTTPRoute/GatewayClass, Helm-релизы, NetworkPolicy, PDB),
запускает `deploy.sh` повторно и сравнивает отпечатки.

---

## Проверка

### Автоматическая проверка всех требований

```bash
./hack/verify.sh
```

32 проверки, сгруппированные по требованиям задания. Скрипт завершается с
ненулевым кодом при любой неудаче и печатает, что именно сломалось.

### Доступность приложения через Gateway API

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | head -1)

curl http://$NODE_IP:30080/
# Hello World!
```

Дополнительно:

```bash
# Маршрутизация по hostname (100% трафика на стабильный backend)
curl -H 'Host: web.mtc.local' http://$NODE_IP:30080/

# Маршрутизация по path (100% трафика на canary)
curl http://$NODE_IP:30080/canary

# Traffic splitting: 90 запросов, ~10 из них попадут на canary
for i in $(seq 1 90); do curl -s http://$NODE_IP:30080/; done | sort | uniq -c
```

Состояние ресурсов Gateway API:

```bash
kubectl get gatewayclass
kubectl -n nginx-gateway get gateway,svc
kubectl -n nginx-gateway describe gateway web-gateway
kubectl -n mtc-demo get httproute
```

### Проверка мониторинга

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Открыть <http://localhost:9090> и выполнить запросы:

| Запрос | Что проверяет |
|---|---|
| `up{namespace="mtc-demo"}` | Все таргеты приложения доступны (значение `1`) |
| `nginx_http_requests_total` | Метрики NGINX собираются с каждого пода |
| `nginx_connections_active` | Активные соединения NGINX |
| `nginx_connections_waiting` | Очередь запросов |
| `node_cpu_seconds_total` | Метрики CPU узлов (node-exporter) |
| `node_memory_MemAvailable_bytes` | Метрики памяти узлов |
| `kube_pod_status_ready{namespace="mtc-demo"}` | Состояние подов (kube-state-metrics) |

Через API, без браузера:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=nginx_http_requests_total' | jq .
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq '.data.activeTargets[] | {job: .labels.job, health}'
```

Grafana с готовым дашбордом:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000 — логин admin
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Дашборд **«MTC Engineer Hack — Web Application»** подхватывается автоматически:
доступность приложения, всего запросов, активных соединений, готовых подов,
RPS по каждому экземпляру, состояние таргетов, CPU и память узлов.

### Проверка логирования

```bash
# 1. Сгенерировать трафик
./hack/smoke-test.sh 200

# 2. Открыть Elasticsearch
kubectl -n mtc-demo port-forward svc/elasticsearch 9200:9200
```

Запросы к API Elasticsearch:

```bash
# Какие индексы с логами есть
curl -s 'http://localhost:9200/_cat/indices/nginx-logs-*?v'

# Сколько всего документов
curl -s 'http://localhost:9200/nginx-logs-*/_count' | jq .

# Последние access-логи
curl -s 'http://localhost:9200/nginx-logs-*/_search?size=5&sort=@timestamp:desc' \
  | jq '.hits.hits[]._source'

# Распределение по HTTP-кодам ответа
curl -s -H 'Content-Type: application/json' \
  'http://localhost:9200/nginx-logs-*/_search' -d '{
    "size": 0,
    "query": {"term": {"log_type": "access"}},
    "aggs": {"codes": {"terms": {"field": "status"}}}
  }' | jq '.aggregations.codes.buckets'
```

Пример документа в Elasticsearch:

```json
{
  "@timestamp": "2026-10-03T14:21:05+00:00",
  "log_type": "access",
  "service": { "name": "nginx", "type": "mtc-hack-app" },
  "cluster": { "name": "mtc-hack" },
  "remote_addr": "10.0.0.5",
  "request_method": "GET",
  "request_uri": "/?run=smoke-1750000000&i=17",
  "nginx_host": "10.0.0.10",
  "status": 200,
  "body_bytes_sent": 13,
  "request_time": "0.001",
  "http_user_agent": "curl/8.5.0",
  "request_id": "3f2a...",
  "agent": { "type": "filebeat" }
}
```

Поля разделены на `log_type: access` (JSON-логи NGINX, разобранные Filebeat)
и `log_type: error` (текстовые строки error-лога NGINX, сохраняемые как есть).

Имена полей доступа NGINX — `nginx_host` и `http_user_agent`, а не `host` и
`user_agent`: в Elasticsearch оба этих имени заняты объектами ECS
(`host.name`, `user_agent.original`). Строковое значение в корне приводит к
ошибке `object mapping ... tried to parse field as object`, и все документы
отбрасываются с `status=400`. По той же причине `service` и `cluster`
заданы как объекты, а не как строки.

Поиск в UI (опционально):

```bash
make kibana    # добавляет Kibana ~1 ГБ RAM
kubectl -n mtc-demo port-forward svc/kibana 5601:5601
# http://localhost:5601 → Discover → index pattern: nginx-logs-*
```

---

## Дополнительные возможности

| Возможность | Как реализовано |
|---|---|
| **Traffic splitting 90/10** | `HTTPRoute web-route`: `backendRefs` с `weight: 90` и `weight: 10` |
| **Маршрутизация по hostname** | `HTTPRoute web-hostname-route` с `hostnames: [web.mtc.local]` |
| **Маршрутизация по path** | Правило `path: /canary` → отдельный backend |
| **Несколько backend'ов** | `web` (3 реплики) и `web-canary` (1 реплика, другая версия ответа) |
| **Дашборд Grafana** | ConfigMap с меткой `grafana_dashboard: "1"`, подхватывается sidecar'ом |
| **CI/CD: статический анализ** | `.github/workflows/ci.yml`: kubeconform по схемам Kubernetes, yamllint, shellcheck, проверка доступности зафиксированных версий и артефактов, детерминированность рендера kustomize |
| **Ловля ошибок, невидимых схемам** | `ci/check_yaml.py`: кросс-пространственные DNS-имена против объявленных namespace'ов, размещение `Gateway` в `GATEWAY_NAMESPACE` (NGF создаёт data plane в namespace шлюза) и явность `parentRef.namespace` у `HTTPRoute` |
| **CI/CD: сквозной тест** | `.github/workflows/e2e-kind.yml`: реальное развёртывание в kind + Calico, прогон `verify.sh` и `smoke-test.sh` |
| **Идемпотентность как тест** | `hack/test-idempotency.sh` сравнивает отпечатки состояния до и после повторного развёртывания |
| **Автоматическая проверка требований** | `hack/verify.sh`: 32 проверки, привязанные к пунктам задания |
| **PodDisruptionBudget** | `minAvailable: 2` из 3 реплик приложения |
| **Anti-affinity через topology spread** | `topologySpreadConstraints` по `kubernetes.io/hostname` |
| **Graceful shutdown** | `preStop: sleep 5` + `terminationGracePeriodSeconds: 40`, `maxUnavailable: 0` |
| **Zero-downtime rolling update** | `maxUnavailable: 0`, `maxSurge: 1` |
| **Опциональный Kibana** | `make kibana` — поиск по логам в UI, не влияет на минимальный путь |

---

## Безопасность и надёжность

**Минимальные права**

- контейнеры работают как непривилегированный пользователь (nginx — uid 101,
  Filebeat — uid 1000, Elasticsearch — uid 1000);
- `readOnlyRootFilesystem: true` у nginx, exporter'а и Filebeat: все
  изменяемые каталоги вынесены в `emptyDir` и/или ConfigMap;
- `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`,
  `seccompProfile: RuntimeDefault`;
- ServiceAccount приложения существует, но **токен не монтируется**
  (`automountServiceAccountToken: false`) — приложению не нужен API-сервер;
- телеметрия NGINX One выключена (`productTelemetry.enable: false`).

**Сетевая изоляция** (требует CNI с поддержкой NetworkPolicy — в решении это Calico)

| Политика | Действие |
|---|---|
| `default-deny-all` | Запрещены все входящие и исходящие соединения внутри `mtc-demo` |
| `allow-dns-egress` | DNS ко всем pod'ам namespace |
| `allow-web-traffic` | Входящий на `:8080` только из `nginx-gateway`, на `:9113` только из `monitoring`; исходящий на `:9200` только в Elasticsearch |
| `allow-elasticsearch-traffic` | Входящий на `:9200` только от pod'ов приложения |

**Pod Security Admission** — namespace помечен `enforce: baseline`,
`warn/audit: restricted`: несоблюдение строгих требований даёт предупреждение,
но не блокирует развёртывание.

**Секреты**

- в репозитории **нет** паролей, токенов и ключей;
- пароль администратора Grafana генерируется случайно при первом
  развёртывании, передаётся в Helm через `--set` и хранится в `.secrets/`
  (исключён из Git);
- проверка наличия секретов в репозитории автоматизирована в `ci/lint.sh`.

**Надёжность**

- `startupProbe` → `readinessProbe` → `livenessProbe` для каждого контейнера,
  который это поддерживает;
- requests/limits заданы для всех контейнеров;
- `imagePullPolicy: IfNotPresent` — не перекачиваются образы на каждом рестарте;
- PVC для данных Elasticsearch — логи переживают перезапуск pod'а;
- два рупора NGINX (data plane) и `leaderElection` у control plane.

---

## Структура репозитория

```
.
├── README.md                       Этот документ
├── Makefile                        Точка входа: make help
├── versions.env                    ЕДИНЫЙ источник зафиксированных версий
├── .gitignore                      Исключает .secrets/, kubeconfig и временные файлы
│
├── hack/
│   ├── lib.sh                      Общие функции (логирование, ожидание, kubectl-хелперы)
│   ├── deploy.sh                   Развёртывание всего решения (идемпотентно)
│   ├── verify.sh                   32 проверки по требованиям задания
│   ├── smoke-test.sh               Нагрузочный тест: трафик → метрики → логи
│   ├── test-idempotency.sh         Проверка безопасности повторного развёртывания
│   ├── destroy.sh                  Удаление решения (опционально — сброс кластера)
│   └── cluster/
│       ├── 00-prepare-node.sh      Подготовка узла Ubuntu 24.04
│       ├── 01-init-control-plane.sh  kubeadm init
│       ├── 02-join-worker.sh       kubeadm join
│       ├── 03-install-cni.sh       Calico + local-path-provisioner
│       ├── kubeadm-config.yaml     Шаблон ClusterConfiguration/InitConfiguration
│       └── kubeadm-join-config.yaml Шаблон JoinConfiguration
│
├── deploy/                         Все манифесты решения (kustomize)
│   ├── kustomization.yaml          Точка входа: kubectl apply -k deploy
│   ├── 00-namespace.yaml
│   ├── app/                        Приложение: nginx + exporter + filebeat
│   ├── canary/                     Canary-версия приложения
│   ├── gateway/                    Gateway + 2 HTTPRoute
│   ├── logging/                    Elasticsearch (StatefulSet-подобный Deployment + PVC)
│   ├── logging-kibana/             Опциональный Kibana (не входит в путь по умолчанию)
│   ├── monitoring/                 ServiceMonitor'ы + дашборд Grafana
│   └── security/                   NetworkPolicy
│
├── helm-values/
│   ├── nginx-gateway-fabric.yaml   Values NGINX Gateway Fabric
│   └── kube-prometheus-stack.yaml  Values мониторинга
│
├── ci/
│   ├── lint.sh                     Проверки качества (те же, что в CI)
│   ├── check_yaml.py               Статический анализ манифестов, 32 проверки
│   └── .yamllint                   Правила стиля YAML
│
├── .github/workflows/
│   ├── ci.yml                      Статический анализ на каждый push в main
│   └── e2e-kind.yml                Сквозной тест в kind (вручную / по расписанию)
│
└── docs/
    ├── ARCHITECTURE.md             Архитектура и обоснование решений
    └── PASSPORT.md                 Паспорт проекта (для сдачи)
```

---

## Известные ограничения

1. **Логи собираются sidecar'ом, а не node-level агентом.** NGINX пишет
   access-логи в файл внутри контейнера, поэтому DaemonSet на узле не увидит
   их без `hostPath`-монтирования (которое ломает работу на нескольких узлах).
   Второй sidecar внутри приложения решает задачу для одного приложения, но
   логи других pod'ов так не собираются. План развития — в разделе ниже.
2. **Логи теряются при пересоздании pod'а до отправки.** Файл логов лежит в
   `emptyDir`. Filebeat батчит записи (до 5 секунд), поэтому при аварийном
   `kill` pod'а возможна потеря последнего батча. Для критичных данных нужен
   `emptyDir` на PV или прямое пирование в stdout.
3. **Elasticsearch без аутентификации и TLS.** Для изолированного стенда это
   осознанное упрощение; доступ ограничен NetworkPolicy. В продуктиве нужно
   включить `xpack.security.enabled: true` и передавать учётные данные
   в Filebeat через Kubernetes Secret.
4. **Elasticsearch — один узел, данные без репликации.** PVC 5 ГБ.
   Для продакшена — три узла и выше.
5. **Prometheus хранит данные 24 часа в `emptyDir`.** Постоянное хранилище
   не настроено намеренно: оно не является требованием задания.
6. **Данные NGINX Gateway Fabric в `emptyDir`.** Пересоздание pod'а data
   plane приводит к короткому разрыву соединений.
7. **`xpack.security.enabled: false` в Elasticsearch** требует, чтобы в
   namespace `mtc-demo` не было посторонних pod'ов. Политика
   `allow-elasticsearch-traffic` это обеспечивает.
8. **Зависимость от внешних реестров.** Требуется доступ в интернет к
   `registry.k8s.io`, `ghcr.io`, `docker.io`, `docker.elastic.co`, `quay.io`,
   `pkgs.k8s.io`. Для air-gapped развёртывания нужен локальный реестр
   и зеркала образов.
9. **Один реестр Gateway API.** Не проверялась совместимость с
   Envoy Gateway / Traefik / Istio — решение использует NGINX Gateway Fabric.
10. **DNS-имя `web.mtc.local` не прописывается автоматически.** Для проверки
    маршрутизации по hostname используйте `curl -H 'Host: web.mtc.local'`.

---

## Развитие решения

В том числе с учётом телеком-специфики.

1. **Node-level сбор логов** — Filebeat DaemonSet с парсером CRI-формата
   (`parsers: [cri]`) для всех pod'ов узла, включая gateway, Prometheus и
   Elasticsearch. Устраняет ограничения 1 и 2.
2. **Гео-резервирование и отказоустойчивость** — три control-plane узла в
   разных зонах доступности, `PodDisruptionBudget` для control plane,
   восстановление кластера из etcd-снапшотов по расписанию.
3. **Интеграция с ЛВС и QoS** — для телеком-трафика: IP SLA/DSCP-матрицы,
   ограничение полосы на шлюзе, учёт задержки и джиттера в метриках
   (histogram-метрики NGINX дают latency перцентилей).
4. **Мониторинг качества обслуживания** — SLI по доступности (из synthetic
   probe `blackbox-exporter`) и по задержке (P95/P99 из histogram-метрик),
   правила алертов в Prometheus и уведомления в Telegram/email.
5. **Наблюдаемость конвейера логов** — включить `monitoring.enabled: true`
   в `filebeat.yml` с `monitoring.http.host: 0.0.0.0:5066` и добавить
   `ServiceMonitor` на `/stats`. Сейчас внутренние метрики Filebeat
   (очередь, `publish.events`, ошибки отправки) намеренно не собираются:
   при выключенном мониторинге порт 5066 не поднимается, а объявлять
   Service без эндпоинта — значит вводить в заблуждение.
6. **A/B- и canary-развёртывания как процесс** — текущий traffic splitting
   (10% на canary) развить в автоматический откат по метрикам ошибок 5xx.
7. **Хранение логов в Loki вместо Elasticsearch** — легче и дешевле при
   том же UX поиска в Grafana; потребуется замена `output.elasticsearch`
   на `loki`. Учтите: задание требует Fluentd или Filebeat, поэтому
   связка будет Filebeat → OpenTelemetry → Loki.
8. **Внешняя аутентификация и авторизация** — OAuth2/OIDC перед приложением,
   `BasicAuth`/`OIDC`-фильтры Gateway API (NGINX Gateway Fabric 2.x
   поддерживает `BasicAuth` и `OIDC` через политики).
9. **TLS-терминация на шлюзе** — самоподписанный CA в репозитории плюс
   `HTTPRoute` с `tls.mode: Terminate` и `certificateRefs`; проверка
   соответствия требованиям регуляторов.
10. **Secret Management** — External Secrets Operator с интеграцией
    HashiCorp Vault: пароли и TLS-ключи перестают храниться в кластере.
11. **Infrastructure as Code для самой ВМ** — Vagrant-файл или Terraform
    для создания виртуальных машин, чтобы кластер разворачивался
    полностью автоматически из чистой машины.

---

## Лицензия и контакты

Манифесты и скрипты можно свободно использовать в учебных целях.
Используются open-source компоненты: Kubernetes (Apache-2.0), Calico (Apache-2.0),
NGINX Gateway Fabric (Apache-2.0), NGINX OSS (BSD-2-Clause),
Prometheus (Apache-2.0), Grafana (AGPL-3.0), Filebeat (Elastic License 2.0),
Elasticsearch (Elastic License 2.0 / SSPL), NGINX Prometheus Exporter (Apache-2.0).
