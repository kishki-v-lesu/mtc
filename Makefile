# =============================================================================
# MTC Engineer Hack — точка входа в решение.
#
#   make help          список целей
#   make cluster       бутстрап кластера на текущем узле (запускать от root)
#   make deploy        развернуть всё решение в кластере
#   make verify        проверить все обязательные требования задания
#
# =============================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

REPO_ROOT := $(shell pwd)
HACK := ${REPO_ROOT}/hack
DEPLOY_DIR := ${REPO_ROOT}/deploy

# Значения для внешних Make-вызовов (документированы в README)
GATEWAY_IP ?= $(shell kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | head -n1)
NAMESPACE ?= mtc-demo
MONITORING_NS ?= monitoring
APP_NODEPORT ?= 30080

.PHONY: help
help: ## Показать список доступных целей
	@echo ""
	@echo "  MTC Engineer Hack — доступные цели:"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---------------------------------------------------------------- подготовка --
.PHONY: cluster
cluster: ## Подготовить ТЕКУЩИЙ узел Ubuntu 24.04 и инициализировать кластер (от root)
	@echo "Внимание: скрипт изменяет систему (apt, sysctl, containerd, kubeadm)."
	sudo ${HACK}/cluster/00-prepare-node.sh
	sudo ALLOW_SCHEDULE_ON_CONTROL_PLANE=$${ALLOW_SCHEDULE_ON_CONTROL_PLANE:-false} \
		${HACK}/cluster/01-init-control-plane.sh
	sudo ${HACK}/cluster/03-install-cni.sh
	@echo ""
	@echo "Кластер готов. Для добавления worker-узлов см. README, раздел «Кластер»."

.PHONY: cluster-worker
cluster-worker: ## Присоединить ТЕКУЩИЙ узел как worker (нужна переменная JOIN_COMMAND)
	@test -n "$${JOIN_COMMAND}" || (echo "Передайте JOIN_COMMAND (см. README)"; exit 1)
	sudo JOIN_COMMAND="$${JOIN_COMMAND}" ${HACK}/cluster/02-join-worker.sh

# ----------------------------------------------------------------- развёртывание
.PHONY: deploy
deploy: ## Развернуть всё решение (Gateway API, приложение, мониторинг, логирование)
	${HACK}/deploy.sh

.PHONY: deploy-minimal
deploy-minimal: ## Развернуть только обязательный минимум (без Grafana и canary)
	${HACK}/deploy.sh --skip-monitoring --skip-canary

.PHONY: redeploy
redeploy: ## Повторно применить развёртывание (проверка идемпотентности)
	${HACK}/deploy.sh

.PHONY: kibana
kibana: ## Дополнительно развернуть Kibana для поиска по логам
	kubectl apply -k ${DEPLOY_DIR}/logging-kibana
	kubectl -n ${NAMESPACE} rollout status deploy/kibana --timeout=300s
	@echo "Kibana: kubectl -n ${NAMESPACE} port-forward svc/kibana 5601:5601"

# ------------------------------------------------------------------- проверки --
.PHONY: verify
verify: ## Проверить ВСЕ обязательные требования задания
	${HACK}/verify.sh

.PHONY: smoke
smoke: ## Сгенерировать нагрузку и проверить метрики и логи
	${HACK}/smoke-test.sh

.PHONY: test-idempotency
test-idempotency: ## Проверить, что повторный запуск развёртывания безопасен
	${HACK}/test-idempotency.sh

.PHONY: check
check: ## Быстрая проверка доступности приложения через Gateway API
	@curl -sS --max-time 10 http://$(GATEWAY_IP):$(APP_NODEPORT)/ && echo " <- ответ приложения"

# ------------------------------------------------------------------ диагностика
.PHONY: status
status: ## Показать состояние всех компонентов решения
	@echo "== Узлы =="            && kubectl get nodes -o wide
	@echo ""                      && echo "== Gateway API =="     && kubectl get gatewayclass && kubectl -n ${NAMESPACE} get gateway,httproute
	@echo ""                      && echo "== Приложение =="       && kubectl -n ${NAMESPACE} get deploy,svc,pod -l app.kubernetes.io/part-of=mtc-hack
	@echo ""                      && echo "== Helm-релизы =="      && helm list -A
	@echo ""                      && echo "== Мониторинг =="       && kubectl -n ${MONITORING_NS} get pods
	@echo ""                      && echo "== Логи (ES) ==" && kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/component=logging

.PHONY: grafana
grafana: ## Открыть Grafana через port-forward (Ctrl+C для остановки)
	kubectl -n ${MONITORING_NS} port-forward svc/kube-prometheus-stack-grafana 3000:80
	@echo "Grafana: http://localhost:3000  (логин admin, пароль: kubectl -n ${MONITORING_NS} get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"

.PHONY: prometheus
prometheus: ## Открыть Prometheus через port-forward (Ctrl+C для остановки)
	kubectl -n ${MONITORING_NS} port-forward svc/kube-prometheus-stack-prometheus 9090:9090
	@echo "Prometheus: http://localhost:9090"

.PHONY: es
es: ## Открыть Elasticsearch API через port-forward (Ctrl+C для остановки)
	kubectl -n ${NAMESPACE} port-forward svc/elasticsearch 9200:9200
	@echo "Elasticsearch: http://localhost:9200"

# --------------------------------------------------------------------- очистка
.PHONY: destroy
destroy: ## Удалить все компоненты решения из кластера
	${HACK}/destroy.sh

.PHONY: destroy-all
destroy-all: ## Удалить решение И сбросить кластер (kubeadm reset)
	${HACK}/destroy.sh --all

# ------------------------------------------------------------------------- CI
.PHONY: lint
lint: ## Локальный запуск проверок качества (то же, что делает CI)
	./ci/lint.sh
