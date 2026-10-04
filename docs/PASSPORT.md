# Паспорт проекта

**Проект:** веб-приложение в Kubernetes с доступом через Gateway API,
мониторингом на Prometheus и централизованным сбором логов

**Автор:** ________________________________ (ФИО, группа)

**Площадка:** MTC Engineer Hack

**Стек:** Ubuntu 24.04 · Kubernetes v1.37.1 (kubeadm) · Calico v3.33.0 ·
Gateway API v1.6.1 · NGINX Gateway Fabric v2.7.2 · NGINX OSS 1.29.4 ·
nginx-prometheus-exporter v1.5.3 · kube-prometheus-stack 91.9.0 ·
Filebeat 9.5.4 · Elasticsearch 9.5.4 · Helm · Kustomize · Bash

---

## 1. Актуальность

Контейнерные платформы стандартизировались на Kubernetes, но доступ к
приложениям до сих пор чаще всего организуется через устаревшие Ingress-аннотации,
которые не входят в модель CNCF и не дают контроллеру принимать решения о
маршрутизации. **Gateway API** — современная замена Ingress, включённая в
Kubernetes как SIG-проект и поддерживаемая CNCF: единая модель для шлюзов,
маршрутов и балансировки между несколькими сервисами, включая распределение
трафика.

Параллельно растёт требование к эксплуатации: приложение должно не только
работать, но и отдавать метрики и логи в централизованные системы, иначе
диагностика инцидента превращается в обход всех pod'ов вручную.

Проект демонстрирует связку этих практик на минимальном, но рабочем примере:
приложение в Kubernetes, доступ к нему через Gateway API с распределением
трафика, сбор метрик в Prometheus и сбор логов в Elasticsearch. Всё
разворачивается одной командой.

## 2. Постановка задачи

Развернуть демонстрационное веб-приложение в Kubernetes-кластере и выполнить
следующие требования:

1. Подготовить кластер Kubernetes, указать версию.
2. Развернуть демонстрационное веб-приложение с публичным образом, отдающим
   `Hello World!`, пишущим access- и error-логи.
3. Организовать доступ к приложению через open-source реализацию Gateway API
   (`GatewayClass`, `Gateway`, `HTTPRoute`), проверить запросом `curl`.
4. Подключить Prometheus, обеспечить сбор метрик минимум от одного компонента,
   продемонстрировать запрос метрик.
5. Подключить Fluentd или Filebeat, обеспечить сбор логов приложения и
   передачу в хранилище или на конечную точку, продемонстрировать.
6. Развернуть всё на Ubuntu 24.04.
7. Автоматизировать развёртывание так, чтобы не требовалось ручное применение
   каждого ресурса через `kubectl apply`, и чтобы повторный запуск не ломал
   систему.

Дополнительно (бонусные возможности): распределение трафика между несколькими
сервисами, дашборд метрик приложения в Grafana, CI/CD.

## 3. Архитектура решения

Кластер собирается **kubeadm** на Ubuntu 24.04: один control-plane и
опциональные worker-узлы. В качестве CNI используется **Calico**, потому что
в отличие от flannel она **применяет NetworkPolicy**. Для работы PVC
устанавливается **local-path-provisioner** — в кластере kubeadm StorageClass
отсутствует.

```
Пользователь ──curl http://<NODE_IP>:30080/──┐
                                             ▼
┌─ namespace: nginx-gateway ──────────────────────────────┐
│ NGINX Gateway Fabric 2.7.2                               │
│   control plane — контроллер Gateway API                │
│   Gateway web-gateway (listener HTTP:80)                 │
│   data plane — 2 реплики NGINX, NodePort 30080 → :80    │
└──────────────────────────────┬──────────────────────────┘
                               │ проксирует
                               ▼
┌─ namespace: mtc-demo ────────────────────────────────────┐
│ HTTPRoute web-route (parentRef: Gateway в nginx-gateway) │
│     /canary ──► web-canary (100%)                        │
│     /       ──► web (90%) + web-canary (10%)             │
│   HTTPRoute web-hostname-route: Host web.mtc.local → web  │
│                                                            │
│ Deployment web (3 реплики, PDB minAvailable 2)           │
│   nginx :8080 → "Hello World!", JSON-логи                │
│   exporter :9113 — метрики NGINX                         │
│   filebeat — читает /var/log/nginx (emptyDir) ─► ES      │
│ Deployment web-canary (1 реплика)                        │
│ Deployment elasticsearch (1 узел) + PVC 5 Gi             │
│ ServiceMonitor web + PodMonitor web (экспортёр)          │
│ NetworkPolicy: default-deny-all + 5 исключений           │
└──────────────────────────────┬──────────────────────────┘
                               │ scrape :9113
                               ▼
┌─ namespace: monitoring ───────────────────────────────────┐
│ Prometheus (2 реплики, retention 24 ч)                    │
│ Grafana + дашборд «Web Application»                       │
│ node-exporter, kube-state-metrics                         │
└────────────────────────────────────────────────────────────┘
```

Развёртывание выполняет `hack/deploy.sh`: префлайт-проверки → CRD Gateway
API (по контрольной версии) → NGINX Gateway Fabric (Helm) → мониторинг
(Helm) → манифесты решения (`kubectl apply --server-side` по каталогам
kustomize) → ожидание готовности.

## 4. Выполнение требований задания

| № | Требование | Реализация | Проверка |
|---|---|---|---|
| 1 | Kubernetes-кластер, версия указана | kubeadm, Kubernetes **v1.37.1**, Calico, local-path | `kubectl get nodes` |
| 2 | Веб-приложение, `Hello World!`, логи | 3 реплики NGINX OSS 1.29.4, JSON-логи в `/var/log/nginx` | `kubectl exec deploy/web -c nginx -- wget -qO- http://127.0.0.1:8080/` |
| 3 | Gateway API, проверка `curl` | GatewayClass `nginx`, Gateway, 2 HTTPRoute | `curl http://<NODE_IP>:30080/` → `Hello World!` |
| 4 | Prometheus собирает метрики | exporter + ServiceMonitor; также node-exporter и kube-state-metrics | `nginx_http_requests_total`, `node_cpu_seconds_total` |
| 5 | Fluentd или Filebeat → хранилище | Filebeat 9.5.4 sidecar → Elasticsearch 9.5.4 | `_cat/indices/nginx-logs-*`, запрос по `request_uri` |
| 6 | Ubuntu 24.04 | `hack/cluster/00-prepare-node.sh` | `lsb_release -a` |
| 7 | Автоматизация, идемпотентность | `deploy.sh` + Helm + Kustomize; повторный запуск безопасен | `hack/test-idempotency.sh` |
| Б | Traffic splitting 90/10 | `backendRefs` с весами 90/10 | 60 запросов, оба backend'а видны |
| Б | Дашборд Grafana | ConfigMap с меткой `grafana_dashboard: "1"` | Дашборд «MTC Engineer Hack — Web Application» |
| Б | CI/CD | `ci.yml` (kubeconform, yamllint, shellcheck, проверка версий), `e2e-kind.yml` (реальное развёртывание и прогон проверок) | Зелёные workflow |

## 5. Результаты апробации

Автоматическая проверка `hack/verify.sh` выполняет **32 проверки**,
привязанные к пунктам задания, и завершается с ненулевым кодом при любой
ошибке:

- **окружение:** версия Kubernetes, `Ready` у всех узлов, наличие Calico,
  StorageClass;
- **приложение:** rollout, минимум 2 готовых пода, ответ `Hello World!`,
  непустой access-лог;
- **Gateway API:** CRD установлены, версия совпадает, `GatewayClass` принят
  (`Accepted=True`), `Gateway` — `Programmed=True`, `HTTPRoute` принят,
  `curl` по IP, по `Host` и по пути `/canary`, распределение трафика;
- **мониторинг:** Prometheus запущен, таргеты приложения в состоянии `UP`,
  отдаются `nginx_http_requests_total`, `nginx_connections_active`,
  метрики узлов, работает Grafana;
- **логирование:** Filebeat готов во всех подах, Elasticsearch отвечает,
  **лог конкретного проверочного запроса** `/verify/<id>` найден в индексе
  `nginx-logs-*`, документ содержит разобранные поля `service`, `log_type`,
  `request_method`, `status`;
- **практики:** PDB, NetworkPolicy, probes, requests/limits для всех
  контейнеров, ServiceAccount без токена.

Дополнительно `hack/smoke-test.sh` генерирует нагрузку через Gateway API и
показывает её отражение в метриках Prometheus и логах Elasticsearch,
`hack/test-idempotency.sh` сравнивает состояние кластера до и после
повторного развёртывания, а CI выполняет статический анализ и сквозной
прогон развёртывания.

## 6. Выводы

1. Все обязательные требования задания выполнены и подтверждены
   автоматическими проверками, а не только инструкцией.
2. Gateway API на примере NGINX Gateway Fabric показал преимущества перед
   Ingress: маршрутизация по пути и имени хоста, распределение трафика
   задаются декларативно в одном ресурсе `HTTPRoute`, без аннотаций и
   правки конфигурации NGINX вручную.
3. Автоматизация дала не только удобство, но и проверяемость: `verify.sh`
   превращает требования задания в 32 исполняемые проверки, а
   `test-idempotency.sh` — в отдельный тест.
4. Найденные при ревью ошибки (недоступность canary из-за NetworkPolicy,
   потеря `listenerPort` при передаче `--set` в Helm, дублирование порта в
   конфигурации `kubeadm join`) показали, что статический анализ манифестов и
   сквозной CI-прогон ловят проблемы, невидимые при беглом просмотре.

## 7. Перспективы развития

1. Node-level сбор логов Filebeat DaemonSet с парсером CRI — снимает
   ограничения sidecar-подхода.
2. Гео-резервирование: три control-plane узла, PDB для control plane,
   восстановление etcd из снапшотов.
3. Мониторинг качества обслуживания: SLI доступности через `blackbox-exporter`,
   P95/P99 задержки по histogram-метрикам, правила алертов.
4. Автоматический откат canary по росту ошибок 5xx вместо ручного.
5. Внешняя аутентификация и авторизация на шлюзе, TLS-терминация.
6. Хранение логов в Loki вместо Elasticsearch (Filebeat → OpenTelemetry → Loki).
7. Инфраструктура как код для самих виртуальных машин (Terraform, Vagrant).
8. Для телеком-задач: IP SLA/DSCP-матрицы, ограничение полосы на шлюзе,
   учёт задержки и джиттера в метриках.

## 8. Используемые компоненты и лицензии

Kubernetes, Calico, local-path-provisioner, Gateway API,
NGINX Gateway Fabric — Apache-2.0; NGINX OSS — BSD-2-Clause;
nginx-prometheus-exporter — Apache-2.0; kube-prometheus-stack,
Prometheus, Grafana — Apache-2.0 / AGPL-3.0; Filebeat, Elasticsearch —
Elastic License 2.0. Все компоненты свободны; платные и проприетарные
сервисы в решении не используются. Телеметрия NGINX Gateway Fabric
отключена (`productTelemetry.enable: false`).

---

### Как сформировать сдаваемые материалы

1. Заполнить поле «Автор» в шапке документа.
2. Выгрузить этот документ в `Паспорт.docx` или `Паспорт.pdf`, не превысив
   **4 страницы**. Надёжные способы:
   - `pandoc docs/PASSPORT.md -o Паспорт.docx` (потом при необходимости
     поправить вкладки вручную в LibreOffice / Word);
   - скопировать текст в любой редактор и экспортировать в PDF
     (`Ctrl+P` → «Сохранить как PDF»).
3. Положить в архив ровно два файла:
   - `Паспорт.docx` / `Паспорт.pdf`;
   - `Ссылка.txt` — одна строка со ссылкой на публичный репозиторий
     (ветка `main`).
4. Назвать архив по фамилии, проверить, что размер ≤ 18 МБ, и загрузить
   до дедлайна.
