#!/bin/bash

set -x
set -e

RANCHER_VERSION=${RANCHER_VERSION:-v2.13.0}
CLUSTER_NAME=${CLUSTER_NAME:-llm-rancher}
RANCHER_IMAGE=${RANCHER_IMAGE:-rancher/rancher:$RANCHER_VERSION}

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

create_kind_cluster() {
    log_info "Creating KIND cluster..."
    kind create cluster --config "manifests/infra/kind-cluster-with-extramounts.yaml" --name $CLUSTER_NAME
    docker pull $RANCHER_IMAGE
    kind load docker-image $RANCHER_IMAGE --name $CLUSTER_NAME
}

setup_helm_repos() {
    log_info "Setting up Helm repositories..."
    helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update
    helm repo add capi-operator https://kubernetes-sigs.github.io/cluster-api-operator --force-update
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo add ngrok https://charts.ngrok.com --force-update
    helm repo add turtles https://rancher.github.io/turtles --force-update
    helm repo update
}

install_cert_manager() {
    log_info "Installing cert-manager..."
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set crds.enabled=true \
        --wait
    log_info "Waiting for cert-manager to be ready..."
    until kubectl get pods -n cert-manager -l app=cert-manager --field-selector=status.phase=Running 2>/dev/null | grep -q cert-manager; do
        echo "Waiting for cert-manager pods to be running..."
        sleep 5
    done
}

install_rancher() {
    log_info "Installing Rancher..."
    helm install rancher rancher-latest/rancher \
        --namespace cattle-system \
        --create-namespace \
        --set bootstrapPassword=rancheradmin \
        --set replicas=1 \
        --set hostname="$RANCHER_HOSTNAME" \
        --version="$RANCHER_VERSION" \
        --wait
    kubectl rollout status deployment rancher -n cattle-system --timeout=180s
}

patch_rancher() {
    log_info "Patching Rancher..."
    until kubectl get deployment rancher -n cattle-system 2>/dev/null; do
        echo "Waiting for Rancher deployment to exist before patching..."
        sleep 5
    done
    envsubst <manifests/infra/rancher-patches.yaml | kubectl apply -f -
}

wait_for_turtles() {
    log_info "Waiting for Rancher Turtles (built-in to Rancher 2.13+)..."
    until kubectl get deployment rancher-turtles-controller-manager -n cattle-turtles-system 2>/dev/null; do
        echo "Waiting for rancher-turtles-controller-manager deployment to be created..."
        sleep 5
    done
    kubectl rollout status deployment rancher-turtles-controller-manager -n cattle-turtles-system --timeout=180s
}

apply_capi_manifests() {
    log_info "Applying CAPI manifests..."
    kubectl apply -f manifests/infra/capi-providers.yaml
    log_info "Waiting for CAPI provider deployments to be created..."
    until kubectl get deployment capd-controller-manager -n capd-system 2>/dev/null; do
        echo "Waiting for capd-controller-manager deployment to be created..."
        sleep 5
    done
    until kubectl get deployment capi-kubeadm-bootstrap-controller-manager -n capi-kubeadm-bootstrap-system 2>/dev/null; do
        echo "Waiting for capi-kubeadm-bootstrap-controller-manager deployment to be created..."
        sleep 5
    done
    until kubectl get deployment capi-kubeadm-control-plane-controller-manager -n capi-kubeadm-control-plane-system 2>/dev/null; do
        echo "Waiting for capi-kubeadm-control-plane-controller-manager deployment to be created..."
        sleep 5
    done
    log_info "Waiting for CAPI provider deployments to be ready..."
    kubectl rollout status deployment capd-controller-manager -n capd-system --timeout=180s
    kubectl rollout status deployment capi-kubeadm-bootstrap-controller-manager -n capi-kubeadm-bootstrap-system --timeout=180s
    kubectl rollout status deployment capi-kubeadm-control-plane-controller-manager -n capi-kubeadm-control-plane-system --timeout=180s
}

apply_capi_cluster() {
    log_info "Applying CAPI cluster manifest..."
    until kubectl apply -f manifests/infra/capi-cluster.yaml; do
        echo "Retrying CAPI cluster application..."
        sleep 5
    done
    kubectl wait --for=condition=Ready cluster/llm-workload --timeout=600s
}

deploy_helm_stack() {
    log_info "Deploying Helm stack (ClusterClass + applications) to management cluster..."
    log_info "Ensuring kubectl context is set to management cluster..."
    
    log_info "Waiting for management cluster API server to be ready..."
    until kubectl cluster-info >/dev/null 2>&1; do
        echo "Waiting for management cluster API server to be ready..."
        sleep 10
    done
    
    log_info "Installing ClusterClass and application components via Helm chart..."
    helm install llm-stack ./llm-stack \
        --set provider=docker \
        --namespace default \
        --create-namespace \
        --wait \
        --timeout 600s
    
    log_info "Helm stack deployed successfully. ClusterClass and Fleet bundles are now available."
    log_info "You can monitor Fleet deployment status with:"
    echo "  kubectl get bundles -A"
    echo "  kubectl get bundledeployments -A"
}

load_images_to_workload_cluster() {
    log_info "Pre-loading Docker images to workload cluster nodes..."
    log_info "Pulling Docker images..."
    # docker pull ghcr.io/berriai/litellm:main-v1.67.4-stable || echo "Failed to pull LiteLLM image, continuing..."
    # docker pull ollama/ollama:latest || echo "Failed to pull Ollama image, continuing..."
    # docker pull ghcr.io/open-webui/open-webui:v0.6.10 || echo "Failed to pull Open WebUI image, continuing..."
    docker pull docker.io/calico/node:v3.26.1 || echo "Failed to pull Calico node image, continuing..."
        
    log_info "Waiting for workload cluster nodes to be ready..."    
    WORKER_NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//' || true)
    if [ -z "$WORKER_NODES" ]; then
        log_warn "No worker nodes found, loading images to all nodes in cluster..."
        # until kind load docker-image ghcr.io/berriai/litellm:main-v1.67.4-stable --name llm-workload; do
        #     echo "Retrying LiteLLM image load to all nodes..."
        #     sleep 5
        # done
        # until kind load docker-image ollama/ollama:latest --name llm-workload; do
        #     echo "Retrying Ollama image load to all nodes..."
        #     sleep 5
        # done
        # until kind load docker-image ghcr.io/open-webui/open-webui:v0.6.10 --name llm-workload; do
        #     echo "Retrying Open WebUI image load to all nodes..."
        #     sleep 5
        # done
        until kind load docker-image docker.io/calico/node:v3.26.1 --name llm-workload; do
            echo "Retrying Calico node image load to all nodes..."
            sleep 5
        done
    else
        log_info "Found worker nodes: $WORKER_NODES"
        log_info "Loading Docker images only to worker nodes..."
        WORKER_NODES_LIST=$(echo "$WORKER_NODES" | tr ' ' ',' | sed 's/,$//')
        log_info "Loading LiteLLM image to worker nodes: $WORKER_NODES_LIST"
        until kind load docker-image ghcr.io/berriai/litellm:main-v1.67.4-stable --name llm-workload --nodes "$WORKER_NODES_LIST"; do
            echo "Retrying LiteLLM image load to worker nodes..."
            sleep 5
        done
        log_info "Loading Ollama image to worker nodes: $WORKER_NODES_LIST"
        until kind load docker-image ollama/ollama:latest --name llm-workload --nodes "$WORKER_NODES_LIST"; do
            echo "Retrying Ollama image load to worker nodes..."
            sleep 5
        done
        log_info "Loading Open WebUI image to worker nodes: $WORKER_NODES_LIST"
        until kind load docker-image ghcr.io/open-webui/open-webui:v0.6.10 --name llm-workload --nodes "$WORKER_NODES_LIST"; do
            echo "Retrying Open WebUI image load to worker nodes..."
            sleep 5
        done
        log_info "Loading Calico node image to worker nodes: $WORKER_NODES_LIST"
        until kind load docker-image docker.io/calico/node:v3.26.1 --name llm-workload --nodes "$WORKER_NODES_LIST"; do
            echo "Retrying Calico node image load to worker nodes..."
            sleep 5
        done
    fi
    
    log_info "Docker images loaded to workload cluster nodes."
}

wait_for_rancher_cluster() {
    log_info "Waiting for Rancher cluster to exist..."
    until kubectl get clusters.management.cattle.io \
        --selector="cluster-api.cattle.io/capi-cluster-owner=llm-workload,cluster-api.cattle.io/capi-cluster-owner-ns=default,cluster-api.cattle.io/owned" \
        -o name | grep .; do
        echo "Waiting for Rancher cluster to exist..."
        sleep 2
    done
    log_info "Waiting for Rancher cluster agent to be deployed..."
    until kubectl get clusters.management.cattle.io \
        --selector="cluster-api.cattle.io/capi-cluster-owner=llm-workload,cluster-api.cattle.io/capi-cluster-owner-ns=default,cluster-api.cattle.io/owned" \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="AgentDeployed")].status}' | grep -q "True"; do
        echo "Waiting for Rancher cluster agent to be deployed..."
        sleep 10
    done
    log_info "Waiting for Rancher cluster to be ready..."
    until kubectl get clusters.management.cattle.io \
        --selector="cluster-api.cattle.io/capi-cluster-owner=llm-workload,cluster-api.cattle.io/capi-cluster-owner-ns=default,cluster-api.cattle.io/owned" \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; do
        echo "Waiting for Rancher cluster to be ready..."
        sleep 10
    done
}

export_kubeconfig() {
    log_info "Exporting kubeconfig for llm-workload..."
    kind get kubeconfig --name llm-workload > kubeconfig-llm-workload.yaml
}

apply_autoscaler() {
    log_info "Applying autoscaler manifest..."
    kubectl apply -f manifests/infra/cluster-autoscaler.yaml
}

usage() {
    echo "Usage: $0"
    echo "Deploys LLM serverless infrastructure."
}

main() {
    create_kind_cluster
    setup_helm_repos
    install_cert_manager
    install_rancher
    patch_rancher
    wait_for_turtles
    apply_capi_manifests
    deploy_helm_stack
    apply_capi_cluster
    load_images_to_workload_cluster
    export_kubeconfig
    log_info "Installing Calico CNI in workload cluster..."
    kubectl --kubeconfig=./kubeconfig-llm-workload.yaml apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml
    wait_for_rancher_cluster
    apply_autoscaler
    log_info "Deployment complete."
    echo ""
    echo "=== Deployment Summary ==="
    echo "✓ Management cluster (KIND) created with Rancher and Fleet"
    echo "✓ Workload cluster provisioned via CAPI"
    echo "✓ Helm chart deployed for ClusterClass and application components"
    echo ""
    echo "=== Next Steps ==="
    echo "1. Monitor Fleet bundle deployment:"
    echo "   kubectl get bundles -A"
    echo "   kubectl get bundledeployments -A"
    echo ""
    echo "2. Check workload cluster status:"
    echo "   KUBECONFIG=kubeconfig-llm-workload.yaml kubectl get nodes"
    echo "   KUBECONFIG=kubeconfig-llm-workload.yaml kubectl get pods -A"
    echo ""
    echo "3. Use port forwarding to access services:"
    echo "   ./portforward.sh"
    echo ""
    echo "4. Access applications (after port forwarding):"
    echo "   - Open WebUI: http://localhost:8080"
    echo "   - LiteLLM: http://localhost:4000" 
    echo "   - Ollama: http://localhost:11434"
    echo ""
    echo "5. Monitor autoscaling:"
    echo "   kubectl logs -f deployment/cluster-autoscaler"
}

main "$@"
