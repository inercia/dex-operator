SOURCES_DIRS      = cmd pkg
SOURCES_DIRS_GO   = ./pkg/... ./cmd/...
SOURCES_APIPS_DIR = ./pkg/apis/kubic

# go source files, ignore vendor directory
DEX_OPER_SRCS      = $(shell find $(SOURCES_DIRS) -type f -name '*.go' -not -path "*generated*")
DEX_OPER_MAIN_SRCS = $(shell find $(SOURCES_DIRS) -type f -name '*.go' -not -path "*_test.go")

DEX_OPER_GEN_SRCS       = $(shell grep -l -r "//go:generate" $(SOURCES_DIRS))
DEX_OPER_CRD_TYPES_SRCS = $(shell find $(SOURCES_APIPS_DIR) -type f -name "*_types.go")

DEX_OPER_EXE  = cmd/dex-operator/dex-operator
DEX_OPER_MAIN = cmd/dex-operator/main.go
.DEFAULT_GOAL: $(DEX_OPER_EXE)

IMAGE_BASENAME = dex-operator
IMAGE_NAME     = opensuse/$(IMAGE_BASENAME)
IMAGE_TAR_GZ   = $(IMAGE_BASENAME)-latest.tar.gz
IMAGE_DEPS     = $(DEX_OPER_EXE) Dockerfile

# should be non-empty when these exes are installed
DEP_EXE       := $(shell command -v dep 2> /dev/null)
KUSTOMIZE_EXE := $(shell command -v kustomize 2> /dev/null)

# These will be provided to the target
DEX_OPER_VERSION := 1.0.0
DEX_OPER_BUILD   := `git rev-parse HEAD 2>/dev/null`

# Use linker flags to provide version/build settings to the target
DEX_OPER_LDFLAGS = -ldflags "-X=main.Version=$(DEX_OPER_VERSION) -X=main.Build=$(DEX_OPER_BUILD)"

# sudo command (and version passing env vars)
SUDO = sudo
SUDO_E = $(SUDO) -E

# the default kubeconfig program generated by kubeadm (used for running things locally)
KUBECONFIG = /etc/kubernetes/admin.conf

# the deployment manifest for the operator
DEX_DEPLOY = deployments/dex-operator-full.yaml

# the kubebuilder generator
CONTROLLER_GEN = vendor/sigs.k8s.io/controller-tools/cmd/controller-gen/main.go

# CONTROLLER_GEN_RBAC_NAME = ":controller"

# increase to 8 for detailed kubeadm logs...
# Example: make local-run VERBOSE_LEVEL=8
VERBOSE_LEVEL = 5

CONTAINER_VOLUMES = \
        -v /sys/fs/cgroup:/sys/fs/cgroup \
        -v /var/run:/var/run

#############################################################
# Build targets
#############################################################

all: $(DEX_OPER_EXE)

dep-exe:
ifndef DEP_EXE
	@echo ">>> dep does not seem to be installed. installing dep..."
	go get github.com/golang/dep/cmd/dep
endif

dep-rebuild: dep-exe Gopkg.toml
	@echo ">>> Rebuilding vendored deps (respecting Gopkg.toml constraints)"
	rm -rf vendor Gopkg.lock
	dep ensure -v && dep status

dep-ensure: dep-exe Gopkg.toml
	@echo ">>> Checking vendored deps (respecting Gopkg.toml constraints)"
	dep ensure -v && dep status

dep-download: dep-exe Gopkg.toml Gopkg.lock
	@echo ">>> Downloading deps"
	dep ensure -v --vendor-only && dep status

dep-update: dep-exe Gopkg.toml
	@echo ">>> Updating vendored deps (respecting Gopkg.toml constraints)"
	dep ensure -update -v && dep status

# download automatically the vendored deps when "vendor" doesn't exist
vendor: dep-exe
	@[ -d vendor ] || dep ensure -v

generate: $(DEX_OPER_GEN_SRCS)
	@echo ">>> Generating files..."
	@go generate -x $(SOURCES_DIRS_GO)

# Create a new CRD object XXXXX with:
#    kubebuilder create api --namespaced=false --group kubic --version v1beta1 --kind XXXXX

kustomize-exe:
ifndef KUSTOMIZE_EXE
	@echo ">>> kustomize does not seem to be installed. installing kustomize..."
	go get sigs.k8s.io/kustomize
endif

#
# NOTE: we are currently not using the RBAC rules generated by kubebuilder:
#       we are just assigning the "cluster-admin" role to the manager (as we
#       must generate ClusterRoles/ClusterRoleBindings)
# TODO: investigate if we can reduce these privileges...
#
# manifests-rbac:
# 	@echo ">>> Creating RBAC manifests..."
# 	@rm -rf config/rbac/*.yaml
# 	@go run $(CONTROLLER_GEN) rbac --name $(CONTROLLER_GEN_RBAC_NAME)
#

manifests-crd: $(DEX_OPER_CRD_TYPES_SRCS)
	@echo ">>> Creating CRDs manifests..."
	@rm -rf config/crds/*.yaml
	@go run $(CONTROLLER_GEN) crd --domain "opensuse.org"

$(DEX_DEPLOY): kustomize-exe manifests-crd
	@echo ">>> Collecting all the manifests for generating $(DEX_DEPLOY)..."
	@rm -f $(DEX_DEPLOY)
	@echo "#" >> $(DEX_DEPLOY)
	@echo "# DO NOT EDIT! Generated automatically with 'make $(DEX_DEPLOY)'" >> $(DEX_DEPLOY)
	@echo "#              from files in 'config/*'" >> $(DEX_DEPLOY)
	@echo "#" >> $(DEX_DEPLOY)
	@for i in config/sas/*.yaml config/crds/*.yaml ; do \
		echo -e "\n---" >> $(DEX_DEPLOY) ; \
		cat $$i >> $(DEX_DEPLOY) ; \
	done
	@echo -e "\n---" >> $(DEX_DEPLOY)
	@kustomize build config/default >> $(DEX_DEPLOY)

# Generate manifests e.g. CRD, RBAC etc.
manifests: $(DEX_DEPLOY)

$(DEX_OPER_EXE): $(DEX_OPER_MAIN_SRCS) generate Gopkg.lock vendor
	@echo ">>> Building $(DEX_OPER_EXE)..."
	go build $(DEX_OPER_LDFLAGS) -o $(DEX_OPER_EXE) $(DEX_OPER_MAIN)

.PHONY: fmt
fmt: $(DEX_OPER_SRCS)
	@echo ">>> Reformatting code"
	@go fmt $(SOURCES_DIRS_GO)

.PHONY: simplify
simplify:
	@gofmt -s -l -w $(DEX_OPER_SRCS)

.PHONY: check
check:
	@test -z $(shell gofmt -l $(DEX_OPER_MAIN) | tee /dev/stderr) || echo "[WARN] Fix formatting issues with 'make fmt'"
	@for d in $$(go list ./... | grep -v /vendor/); do golint $${d}; done
	@go tool vet ${DEX_OPER_SRCS}

.PHONY: test
test:
	@go test -v $(SOURCE_DIRS_GO) -coverprofile cover.out

.PHONY: check
clean: docker-image-clean
	rm -f $(DEX_OPER_EXE)

#############################################################
# Some simple run targets
# (for testing things locally)
#############################################################

# assuming the k8s cluster is accessed with $(KUBECONFIG),
# deploy the dex-operator manifest file in this cluster.
local-deploy: $(DEX_DEPLOY) docker-image-local
	@echo ">>> (Re)deploying..."
	@[ -r $(KUBECONFIG) ] || $(SUDO_E) chmod 644 $(KUBECONFIG)
	@echo ">>> Deleting any previous resources..."
	-@kubectl get ldapconnectors -o jsonpath="{..metadata.name}" | \
		xargs -r kubectl delete --all=true ldapconnector 2>/dev/null
	-@kubectl get dexconfigurations -o jsonpath="{..metadata.name}" | \
		xargs -r kubectl delete --all=true dexconfiguration 2>/dev/null
	@sleep 30
	-@kubectl delete --all=true --cascade=true -f $(DEX_DEPLOY) 2>/dev/null
	@echo ">>> Regenerating manifests..."
	@make manifests
	@echo ">>> Loading manifests..."
	kubectl apply --kubeconfig $(KUBECONFIG) -f $(DEX_DEPLOY)

clean-local-deploy:
	@make manifests
	@echo ">>> Uninstalling manifests..."
	kubectl delete --kubeconfig $(KUBECONFIG) -f $(DEX_DEPLOY)

# Usage:
# - Run it locally:
#   make local-run VERBOSE_LEVEL=5
# - Start a Deployment with the manager:
#   make local-run EXTRA_ARGS="--"
#
local-run: $(DEX_OPER_EXE) manifests
	[ -r $(KUBECONFIG) ] || $(SUDO_E) chmod 644 $(KUBECONFIG)
	@echo ">>> Running $(DEX_OPER_EXE) as _root_"
	$(DEX_OPER_EXE) manager \
		-v $(VERBOSE_LEVEL) \
		--kubeconfig /etc/kubernetes/admin.conf \
		$(EXTRA_ARGS)

docker-run: $(IMAGE_TAR_GZ)
	@echo ">>> Running $(IMAGE_NAME):latest in the local Docker"
	docker run -it --rm \
		--privileged=true \
		--net=host \
		--security-opt seccomp:unconfined \
		--cap-add=SYS_ADMIN \
		--name=$(IMAGE_BASENAME) \
		$(CONTAINER_VOLUMES) \
		$(IMAGE_NAME):latest $(EXTRA_ARGS)

local-$(IMAGE_TAR_GZ): $(DEX_OPER_EXE)
	@echo ">>> Creating Docker image (Local build)..."
	docker build -f Dockerfile.local \
		--build-arg BUILT_EXE=$(DEX_OPER_EXE) \
		-t $(IMAGE_NAME):latest .
	@echo ">>> Creating tar for image (Local build)"
	docker save $(IMAGE_NAME):latest | gzip > local-$(IMAGE_TAR_GZ)

docker-image-local: local-$(IMAGE_TAR_GZ)

$(IMAGE_TAR_GZ):
	@echo ">>> Creating Docker image..."
	docker build -t $(IMAGE_NAME):latest .
	@echo ">>> Creating tar for image..."
	docker save $(IMAGE_NAME):latest | gzip > $(IMAGE_TAR_GZ)

docker-image: $(IMAGE_TAR_GZ)
docker-image-clean:
	rm -f $(IMAGE_TAR_GZ)
	-docker rmi $(IMAGE_NAME)


#############################################################
# Other stuff
#############################################################

-include Makefile.local
