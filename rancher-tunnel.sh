#!/bin/bash

set -e

PIDS=()
NGROK_PID=""

cleanup() {
    echo "Stopping Rancher port-forward and ngrok tunnel..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    if [ -n "$NGROK_PID" ]; then
        kill $NGROK_PID 2>/dev/null && echo "Stopped ngrok (PID: $NGROK_PID)"
    fi
}
trap cleanup EXIT INT TERM

NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN:-}
RANCHER_HOSTNAME=${RANCHER_HOSTNAME:-rancher.local}

# Port-forward Rancher on management cluster
if kubectl get service rancher -n cattle-system &>/dev/null; then
    echo "Port-forwarding Rancher (10000) to localhost:10000 in namespace cattle-system..."
    kubectl port-forward svc/rancher -n cattle-system 10000:80 > /tmp/portforward-rancher.log 2>&1 &
    PIDS+=($!)
else
    echo "Error: Rancher service not found in cattle-system namespace."
    exit 1
fi

wait_for_local_rancher() {
    echo "Waiting for Rancher to be accessible on localhost:10000..."
    until curl -s -o /dev/null -w "%{http_code}" http://localhost:10000 | grep -q "200\|302\|301"; do
        echo "Waiting for local Rancher port-forward..."
        sleep 2
    done
    echo "Rancher is accessible locally!"
}

start_ngrok() {
    if [ -z "$NGROK_AUTHTOKEN" ]; then
        echo "NGROK_AUTHTOKEN is not set. Skipping ngrok tunnel startup."
        return
    fi
    echo "Starting ngrok tunnel for Rancher..."
    ngrok config add-authtoken "$NGROK_AUTHTOKEN"
    ngrok http 10000 --hostname="$RANCHER_HOSTNAME" > /tmp/ngrok-rancher.log 2>&1 &
    NGROK_PID=$!
    echo "ngrok started with PID: $NGROK_PID"
}

wait_for_local_rancher
start_ngrok

echo "Rancher tunnel started. Press Ctrl+C to stop."
wait
