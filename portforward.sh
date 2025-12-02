#!/bin/bash

set -e

KUBECONFIG=${KUBECONFIG:-./kubeconfig-llm-workload.yaml}
export KUBECONFIG

PIDS=()

cleanup() {
    echo "Stopping port-forwarding..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

forward_service() {
    local service_name=$1
    local local_port=$2
    local target_port=$3

    if kubectl get service "$service_name" -n default &>/dev/null; then
        echo "Port-forwarding $service_name ($local_port) to localhost:$local_port..."
        kubectl port-forward "svc/$service_name" -n default "$local_port:$target_port" > /tmp/portforward-$service_name.log 2>&1 &
        PIDS+=($!)
    else
        echo "Warning: Service $service_name not found in default namespace. Skipping."
    fi
}

forward_service "ollama-service" 11434 11434
forward_service "litellm-service" 4000 4000
forward_service "openwebui-service" 8080 8080

echo "Port forwarding started for workload cluster services. Press Ctrl+C to stop."
wait