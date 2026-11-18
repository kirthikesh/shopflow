# ShopFlow on a laptop: the whole platform on a free kind cluster.
# The app's own targets are in app/Makefile, the Azure ones in infra/Makefile.
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

local-up: ## Create the cluster and install everything (about 15 minutes the first time)
	local/up.sh

local-app: ## Rebuild the images and redeploy the app
	REBUILD=1 local/up.sh images && local/up.sh app

local-down: ## Delete the local cluster and the Service Bus emulator
	local/down.sh

tracing-on: ## Add OpenTelemetry tracing (operator, collector, Tempo) and instrument the services
	local/up.sh tracing

tracing-off: ## Remove tracing again to free memory
	local/up.sh tracing-off

load-test: ## k6: ramp to 12 shoppers for 5 minutes and check the thresholds (TARGET=n for more)
	k6 run tests/load/shop.js

chaos-test: ## k6 traffic while Chaos Mesh kills pods, slows the database and stops payments
	local/chaos.sh

backup-drill: ## Velero: back up, delete the namespace, restore, compare orders
	local/backup-drill.sh

policy-report: ## Kyverno: what passed and what failed in the ShopFlow namespace
	kubectl -n shopflow-local get policyreport -o wide

grafana: ## Open Grafana (admin / shopflow)
	open https://grafana.localtest.me:9443

shop: ## Open the shop
	open https://shop.localtest.me:9443
