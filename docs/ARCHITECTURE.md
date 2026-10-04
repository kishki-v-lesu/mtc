# Архитектура решения

Документ описывает, как устроено решение и **почему** выбраны именно такие
компоненты. Операционная инструкция — в [README.md](../README.md).

---

## 1. Целевая архитектура

```
                        ┌──────────────────────────────────────────────┐
                        │  kube-system                                  │
   Пользователь  ──┐    │  Calico (CNI + enforcement NetworkPolicy)     │
   curl / браузер │    │  CoreDNS                                       │
   :30080          │    └──────────────────────────────────────────────┘
                   │                      │
                   │                      │ адресация, политики трафика
                   ▼                      │
        ┌──────────────────────┐          │
        │  NGINX Gateway Fabric│          │  watch: Gateway, HTTPRoute
        │  namespace          │          │
        │  nginx-gateway      │          │
        │                      │          │
│  control plane ──► конфигурация ┐
         │  Gateway web-gateway ── listener HTTP:80
         │  data plane (2 реплики, NodePort 30080 → :80)
         └───────────┬──────────┘           │
                     │ проксирует           │
                     ▼                      ▼
         ┌───────────────────────────────────────────────┐
         │  mtc-demo                                     │
         │                                               │
         │  HTTPRoute web-route (parentRef: Gateway      │
         │  в namespace nginx-gateway)                   │
         │      │                                        │
        │      ├─ HTTPRoute web-route                   │
        │      │     ├─ PathPrefix /canary ──► web-canary:80 (100%)
        │      │     └─ PathPrefix /       ──► web:80 (90%) + web-canary:80 (10%)
        │      │                                        │
        │      └─ HTTPRoute web-hostname-route          │
        │            └─ Host: web.mtc.local, / ──► web:80 (100%)
        │                                               │
        │  ┌─────────────────────────────────────────┐  │
        │  │ Deployment web (3 реплики, PDB=2)       │  │
        │  │   nginx :8080          ─┐               │  │
        │  │   exporter :9113        │ emptyDir      │  │
        │  │   filebeat ─────────────┴─► /var/log/nginx ──► ES:9200
        │  └─────────────────────────────────────────┘  │
        │  ┌─────────────────────────────────────────┐  │
        │  │ Deployment web-canary (1 реплика)       │  │
        │  └─────────────────────────────────────────┘  │
        │  ┌─────────────────────────────────────────┐  │
        │  │ Deployment elasticsearch + PVC 5Gi     │  │
        │  └─────────────────────────────────────────┘  │
        │  ServiceMonitor web + PodMonitor web (экспортёр)  │
        │  NetworkPolicy × 6                            │
        └──────────┬────────────────────────────┬───────┘
                   │ scrape :9113               │ :9200 (write)
                   ▼                            │
        ┌────────────────────────┐               │
        │  monitoring            │               │
        │  Prometheus (2 реплики)│               │
        │  Grafana + дашборд     │               │
        │  node-exporter         │               │
        │  kube-state-metrics    │               │
        └────────────────────────┘               │
                                                 ▼
                                    ┌──────────────────────────┐
                                    │ Elasticsearch 9.5.4      │
                                    │ индекс nginx-logs-*      │
                                    └──────────────────────────┘
```

---

## 2. Ключевые решения и их обоснование

### 2.1. Kubernetes собирается через kubeadm, а не kind/minikube

| Критерий | kubeadm (выбрано) | kind | minikube |
|---|---|---|---|
| Соответствие заданию | прямо рекомендовано | допустимо | допустимо |
| Чистое production-подобное окружение | да (control plane, etcd, CNI, kubelet) | упрощённое | упрощённое |
| NetworkPolicy | да (при Calico) | kindnet — **нет** | частично |
| Время развёртывания | ~10 мин | ~1 мин | ~3 мин |
| Требования к ресурсам VM | 8 ГБ RAM | 4 ГБ | 6 ГБ |

Решение принято в пользу kubeadm: проверяющий получает настоящий кластер из
нескольких VM с настоящим control plane, а не контейнер-в-контейнере.
Дополнительный плюс — возможность продемонстрировать worker-узлы.

**Цена решения:** более высокие требования к ВМ (8 ГБ RAM) и больше шагов
при развёртывании. Для быстрых экспериментов в репозитории есть CI-сквозной
тест на kind (`.github/workflows/e2e-kind.yml`).

### 2.2. Calico, а не flannel

`flannel` — CNI по умолчанию в kubeadm и самый простой в установке, но он
**не поддерживает NetworkPolicy**: политики в манифестах создавались бы,
но ничего бы не ограничивали. Поскольку требование «качество решения» и
практики безопасности — часть оценки, выбран Calico:

- применяет `NetworkPolicy` (enforcement на уровне iptables/eBPF);
- поставляется одним `kubectl apply -f` без дополнительных компонентов;
- совместим с `kubeadm` v1beta4 и Kubernetes 1.37.

### 2.3. local-path-provisioner

В кластере, собранном kubeadm, StorageClass отсутствует, поэтому PVC для
Elasticsearch не к чему привязать. Требование допускает установку
дополнительного компонента с открытым исходным кодом — rancher/local-path
полностью этому соответствует. Альтернативы (ceph-csi, csi-driver-nfs)
значительно тяжелее и не нужны для демонстрации.

### 2.4. NGINX Gateway Fabric + NGINX OSS

Требование задания — open-source реализация Gateway API. Рассмотрены:

| Реализация | Плюсы | Минусы |
|---|---|---|
| **NGINX Gateway Fabric 2.7.2** | официальный вендорский проект на NGINX OSS; простая модель «GatewayClass + Gateway + HTTPRoute»; data plane — привычный NGINX; есть ServiceMonitor из коробки | контрольная плоскость — Go-контроллер |
| Envoy Gateway | мощнее по фильтрам | тяжёлый data plane (Envoy), сложнее воспроизвести |
| Traefik | компактный | самонаписанный контроллер Gateway API, меньше документации |
| Istio | огромная экосистема | избыточен для задачи, долгое развёртывание |

Выбран NGINX Gateway Fabric: минимум компонентов, знакомый экспортёр метрик
(его же мы используем для приложения) и совместимость с NGINX OSS.

**Версии фиксируются по официальной матрице совместимости:**
NGF 2.7.2 → Gateway API 1.6.1, Kubernetes 1.32+. Отдельно отклонялась
более свежая Gateway API 1.6.2: она не входит в проверенную матрицу.

### 2.5. GatewayClass создаётся Helm-чартом

Чарт NGINX Gateway Fabric сам создаёт ресурс `GatewayClass` с именем из
`nginxGateway.gatewayClassName`. Поэтому в репозитории нет отдельного
манифеста `GatewayClass` — иначе при `helm upgrade` возник бы конфликт
владения ресурсом (`kubectl apply` перехватил бы объект у Helm).

### 2.6. Почему Gateway лежит в namespace `nginx-gateway`

NGINX Gateway Fabric создаёт data plane (поды NGINX и Service с NodePort)
**в namespace ресурса `Gateway`**, а не в namespace control plane. Выбрать
другой нельзя: в CRD `NginxProxy` (gateway.nginx.org/v1alpha2) поля
`spec.kubernetes.namespace` просто нет — проверено по схеме CRD из чарта
2.7.2; задать namespace data plane невозможно.

Поэтому ресурс `Gateway` намеренно размещён в `nginx-gateway` рядом с control
plane, а `HTTPRoute` остались в `mtc-demo` рядом с приложением. Следствия:

* поды data plane не попадают под `default-deny-all` в `mtc-demo`, который
  иначе заблокировал бы им egress к `web:8080` и обрушил маршрутизацию;
* NodePort Service создаётся там же, где `hack/deploy.sh` его ищет;
* ingress-политики приложения уже разрешают трафик из `nginx-gateway`
  (см. `allow-web-traffic` и `allow-canary-traffic`);
* подключение маршрута к шлюзу из другого namespace разрешено
  `allowedRoutes.namespaces.from: All`, а `backendRefs` резолвятся в
  namespace самого маршрута, поэтому `ReferenceGrant` не требуется.

Цена решения — `kubectl` для проверки шлюза нужно указывать два namespace;
это отражено в `verify.sh` и в README.

### 2.7. Почему логи собирает sidecar, а не DaemonSet

NGINX пишет access-логи в **файл** внутри контейнера, а не в stdout:

```
/var/log/nginx/access.log  (JSON, log_format json_combined)
/var/log/nginx/error.log
```

Варианты сбора:

| Вариант | Плюсы | Минусы |
|---|---|---|
| **Sidecar Filebeat** (выбрано) | не требует hostPath; работает на любом CNI; доступны права на конкретные файлы; просто изолировано | логи только одного приложения; удваивает число контейнеров в поде |
| DaemonSet + hostPath `/var/log` | собирает всё на узле | требует mountPath на хосте; логи NGINX всё равно лежат в слое контейнера, а не на хосте, — пришлось бы монтировать каталог логов pod'а в хост |
| NGINX → stdout + CRI-парсер | «правильный» подход для Kubernetes | требует переписывания конфигурации логирования NGINX; для учебного стенда избыточно |

Sidecar выбран как компромисс: он полностью решает задачу «собрать логи
приложения и показать их в Elasticsearch», не трогая хост. Ограничение
явно описано в README (раздел «Известные ограничения», п. 1–2) вместе
с планом развития — node-level сборщик с `parsers: [cri]`.

**Важная деталь реализации:** том с логами объявлен как `emptyDir`
(`medium: Memory`) и примонтирован в оба контейнера — NGINX пишет,
Filebeat читает с правами только на чтение. `fsGroup: 101` гарантирует,
чему читателю хватает групповых прав, а `--strict.perms=false` снимает
проверку владельца файла.

### 2.8. Elasticsearch, а не Loki

Задание требует «хранилище или конечная точка для логов». Elasticsearch
выбран потому, что Filebeat умеет отправлять в него «из коробки» (официальный
output), не требуя ни Loki, ни OpenTelemetry-коллектора. Цена — ~2 ГБ RAM
на single-node инстанс, поэтому предусмотрены флаги `--skip-monitoring`
и `--skip-logging` для машин с 4 ГБ.

### 2.9. Трафик на шлюз: NodePort, а не LoadBalancer

На «голом» kubeadm-кластере LoadBalancer остался бы `pending` бесконечно —
обработчика нет. Варианты:

1. поставить MetalLB и получить LoadBalancer;
2. использовать NodePort.

Выбран NodePort: ноль дополнительных компонентов, детерминированный порт
`30080` из `versions.env` — проверяющему не нужно угадывать адрес.

`externalTrafficPolicy: Cluster` выбран намеренно: при `Local` порт работал бы
только на узлах с локальным подом NGINX, и `curl` к control-plane узлу мог бы
не отвечать. Цена — исходный IP клиента не сохраняется, что для стенда
несущественно (в access-логах видно IP прокси).

### 2.10. Canary и traffic splitting как бонус к заданию

Баллы за бонусные возможности даются за распределение трафика. Реализовано:

- два backend'а: `web` (3 реплики) и `web-canary` (1 реплика, ответ
  `Hello World! (canary)`);
- `HTTPRoute web-route`: `/` → `web` с весом 90 и `web-canary` с весом 10;
- `HTTPRoute web-hostname-route`: `Host: web.mtc.local` → 100 % в `web`.

Разные тела ответов позволяют на глаз определить, какой backend обработал
запрос, — это делает бонус проверяемым, а не декларативным.

Отдельная тонкость, найденная при ревью: политика `NetworkPolicy`
выбирала поды по `app.kubernetes.io/name=web`, поэтому поды canary
оставались под `default-deny-all` и были недостижимы из шлюза. Для canary
добавлена отдельная политика `allow-canary-traffic`.

### 2.11. Мониторинг: exporter внутри пода + ServiceMonitor

Требование — «Prometheus должен собирать метрики хотя бы от одного компонента».
Выбран `nginx-prometheus-exporter`, встроенный в под приложения:

- скраппит `stub_status` через `127.0.0.1:8080/nginx_status` — метрики
  отражают именно тот экземпляр NGINX, в поде которого живёт exporter;
- `ServiceMonitor` (а не `PodMonitor`) — Prometheus Operator сам находит
  порт по имени и добавляет стандартные лейблы `namespace`/`pod`, поэтому
  метрики сразу группируются по экземплярам без ручных `relabelings`;
- headless-сервис `web-metrics` позволяет видеть все реплики, а не одну.

Метрики узлов (`node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`)
и состояние подов (`kube_pod_status_ready`) даёт штатный
kube-prometheus-stack — это закрывает «мониторинг не только приложения,
но и инфраструктуры».

### 2.12. Пароль Grafana не в репозитории

`helm upgrade --install ... --set-string grafana.adminPassword=...` оставил бы
пароль в Helm-релизе и в истории команд. Поэтому пароль генерируется один
раз (20 случайных символов), кладётся в `.secrets/` с правами `0600`
(каталог в `.gitignore`) и переиспользуется при повторном развёртывании —
это и есть идемпотентность в действии: доступ к Grafana не ломается
от того, что скрипт запустили второй раз.

---

## 3. Идемпотентность

| Операция | Механизм |
|---|---|
| Манифесты решения | `kubectl apply --server-side --force-conflicts` |
| Каталоги с kustomization | `kubectl apply -k` (не `-f`: kustomization.yaml не обрабатывается флагом `-f`) |
| NGINX Gateway Fabric | `helm upgrade --install` |
| kube-prometheus-stack | `helm upgrade --install` |
| CRD Gateway API | сверка лейбла `gateway.networking.k8s.io/bundle-version`, скачивание при отличии |
| Пакеты kubeadm/kubelet | `apt-get install` фиксированной версии + `apt-mark hold` |
| Calico, local-path | проверка `kubectl get` перед установкой |
| Конфигурация приложения | аннотация `checksum/config` на pod-шаблоне, вычисляется из файлов при каждом запуске; при неизменной сумме rollout не происходит |
| Пароль Grafana | генерация один раз, хранение в `.secrets/` |

Проверка: `hack/test-idempotency.sh` снимает «отпечаток» состояния,
повторно запускает `deploy.sh` и сравнивает отпечатки.

---

## 4. Безопасность

Слои защиты, реализованные в манифестах:

1. **Контейнер** — non-root (uid 101 для nginx, 1000 для Filebeat и
   Elasticsearch), `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`,
   `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`.
2. **Pod** — ServiceAccount без токена
   (`automountServiceAccountToken: false`), `runAsNonRoot`, `fsGroup`.
3. **Сеть** — `default-deny-all` в namespace приложения и четыре точечных
   исключения; вход на `:8080` разрешён только из `nginx-gateway`, на
   `:9113` — только из `monitoring`, на `:9200` — только от приложения.
4. **Namespace** — Pod Security Admission `enforce: baseline`.
5. **Доступность** — PDB `minAvailable: 2` из 3 реплик,
   `topologySpreadConstraints` по узлам, rolling update с
   `maxUnavailable: 0`, `preStop`-хук и `terminationGracePeriodSeconds: 40`.
6. **Репозиторий** — ни одного секрета; проверка на это автоматизирована
   в `ci/lint.sh` (шаг «Проверка отсутствия секретов в репозитории»).

---

## 5. Потоки данных

### 5.1. Запрос пользователя

```
curl ──► NodePort 30080 (любой узел)
      ──► NGINX Gateway Fabric data plane
      ──► выбор правила HTTPRoute (PathPrefix /canary важнее, чем /)
      ──► web:80 или web-canary:80
      ──► NGINX :8080 → 200 "Hello World!"
      ──► запись в /var/log/nginx/access.log (JSON)
```

### 5.2. Логи

```
nginx пишет JSON в emptyDir
  ──► Filebeat (filestream + парсер ndjson → поля верхнего уровня)
  ──► буфер в памяти (queue.mem, flush 512 событий / 5 с)
  ──► output.elasticsearch → индекс nginx-logs-YYYY.MM.DD
```

Два входа: `access.log` разбирается в поля (`status`, `request_uri`,
`request_time`, ...), `error.log` сохраняется как текст. Оба помечаются
полями `service: nginx` и `log_type: access|error`.

### 5.3. Метрики

```
NGINX stub_status ──► exporter :9113 (внутри пода приложения)
                  ──► ServiceMonitor web + PodMonitor web (интервал 15 с)
                  ──► Prometheus
                  ──► Grafana: дашборд + ad-hoc запросы

node-exporter, kube-state-metrics ──► Prometheus (инфраструктура)
```

---

## 6. Что осознанно не сделано

| Решение | Причина |
|---|---|
| Постоянное хранилище Prometheus | не требуется заданием; `emptyDir` + retention 24 ч достаточно для стенда |
| Elasticsearch с аутентификацией | усложняет Filebeat-конфигурацию и требует Secret; для изолированного стенда избыточно |
| Multi-AZ / три control-plane узла | для стенда достаточно одного; в README описан как пункт развития |
| TLS на шлюзе | задание не требует; добавление усложнило бы демонстрацию основных требований |
| Несколько Gateway API-реализаций | задание требует одну |

Каждое из этих ограничений описано в README (раздел «Известные ограничения»)
с планом развития, а не скрыто.
