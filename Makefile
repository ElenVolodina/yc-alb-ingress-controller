ifneq (,$(wildcard ./.env))
	include .env
	export
endif

# temporarily support only Yandex Container registry to avoid providing imagePullSecrets
REGISTRY_HOST?=cr.yandex
IMG_NAME?=yc-alb-ingress-controller
TAG?=$(shell git rev-parse --short HEAD)
ifdef REGISTRY_ID
	IMG = $(REGISTRY_HOST)/${REGISTRY_ID}/$(IMG_NAME):${TAG}
endif

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

check_%:
	[ -n "${${*}}" ] || (echo ${*} env var required && false)

##@ Development

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	cd ${PROJECT_DIR} && $(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./controllers/..." output:crd:artifacts:config=config/crd/bases

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	cd ${PROJECT_DIR} && $(CONTROLLER_GEN) object:headerFile="./hack/boilerplate.go.txt" paths="./api/..."

fmt: ## Run go fmt against code.
	cd ${PROJECT_DIR} && go fmt ./...

vet: ## Run go vet against code.
	cd ${PROJECT_DIR} && go vet ./...

ENVTEST_ASSETS_DIR=$(shell pwd)/testbin
SHELL='/bin/bash'
test: manifests generate fmt vet ## Run tests.
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.7.0/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); cd ${PROJECT_DIR} && go test ./... -coverprofile cover.out

##@ Build

build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

docker-build: check_IMG test ## Build docker image with the manager.
	cd ${PROJECT_DIR} && docker build --platform linux/amd64 --build-arg CREATED_AT="$$(date --rfc-3339=seconds)" --build-arg COMMIT=$$(git rev-parse HEAD) -t ${IMG} .

docker-push: check_IMG ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ${KUBECONFIG} or ~/.kube/config.
	$(KUSTOMIZE) build ${PROJECT_DIR}/config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ${KUBECONFIG} or ~/.kube/config.
	$(KUSTOMIZE) build ${PROJECT_DIR}/config/crd | kubectl delete -f -

deploy: manifests kustomize check_IMG check_FOLDER_ID check_KEY_FILE patch apply ## Deploy controller to the K8s cluster

undeploy: check_FOLDER_ID check_KEY_FILE unapply unpatch ## Undeploy controller from the K8s cluster

CONTROLLER_GEN = $(PROJECT_DIR)/bin/controller-gen
controller-gen: ## Download controller-gen locally if necessary.
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.4.1)

KUSTOMIZE =  ${PROJECT_DIR}/bin/kustomize
kustomize: ## Download kustomize locally if necessary.
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v4@v4.5.7)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go install $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

apply: kustomize
	$(KUSTOMIZE) build ${PROJECT_DIR}/config/default | kubectl apply -f -

unapply: kustomize
	$(KUSTOMIZE) build ${PROJECT_DIR}/config/default | kubectl delete -f -

PROD_ENDPOINT=api.cloud.yandex.net:443
patch: check_IMG check_FOLDER_ID check_KEY_FILE
	cp $(KEY_FILE)  ${PROJECT_DIR}/config/default/ingress-key.json
	cd ${PROJECT_DIR}/config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	cd ${PROJECT_DIR}/config/manager && $(KUSTOMIZE) edit add patch \
		--kind Deployment \
		--name controller-manager \
		--namespace system \
		--patch '[{"op": "add", "path": "/spec/template/spec/containers/0/args/0", "value": "--folder-id='${FOLDER_ID}'"},{"op": "add", "path": "/spec/template/spec/containers/0/args/1", "value": "--endpoint='"$${ENDPOINT:-$(PROD_ENDPOINT)}"'"}]'

unpatch: check_FOLDER_ID
	cd ${PROJECT_DIR}/config/manager && $(KUSTOMIZE) edit remove patch \
		--kind Deployment \
		--name controller-manager \
		--namespace system \
		--patch '[{"op": "add", "path": "/spec/template/spec/containers/0/args/0", "value": "--folder-id='${FOLDER_ID}'"},{"op": "add", "path": "/spec/template/spec/containers/0/args/1", "value": "--endpoint='"$${ENDPOINT:-$(PROD_ENDPOINT)}"'"}]' || true
	cd ${PROJECT_DIR}/config/manager && $(KUSTOMIZE) edit set image controller=controller
	rm -f ${PROJECT_DIR}/config/default/ingress-key.json

GO_EXCLUDE := /vendor/|/bin/|/genproto/|.pb.go|.gen.go|sensitive.go|validate.go
GO_FILES_CMD := find . -name '*.go' | grep -v -E '$(GO_EXCLUDE)'
Q = $(if $(filter 1,$V),,@)

##@ local

gomod: ## Run go mod vendor
	$(Q) >&2 GOPRIVATE=bb.yandex-team.ru,bb.yandexcloud.net go mod tidy
	$(Q) >&2 GOPRIVATE=bb.yandex-team.ru,bb.yandexcloud.net go mod vendor

GOIMPORTS = $(shell pwd)/bin/goimports
goimports: ## Install goimports if necessary
	$(call go-get-tool,$(GOIMPORTS),golang.org/x/tools/cmd/goimports@latest)

imports: goimports ## Run goimports on all go files
	$(Q) $(GO_FILES_CMD) | xargs -n 50 $(GOIMPORTS) -w -local github.com/yandex-cloud/alb-ingress


GOLANGCI_LINT = $(shell pwd)/bin/golangci-lint
golangci-lint: ## Download golangci-lint locally if necessary.
	$(call go-get-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/cmd/golangci-lint@v1.60.1)

lint: golangci-lint
	$(Q) $(GOLANGCI_LINT) run ./... -v

lint-fix: golangci-lint
	$(Q) $(GOLANGCI_LINT) run ./... -v --fix

ci: lint
	go test ./...
