#!/usr/bin/env bash
# test/interop/k8s-verify.sh
set -euo pipefail

# Configuration
NAMESPACE="aeron"
LABEL="app.kubernetes.io/part-of=interop"
TIMEOUT=150

echo "=== [1/4] Building and Importing Images ==="
# Nix build for Zig OCI
nix build .#oci --quiet
docker load < result > /dev/null
docker save harus-aeron-zig:latest | colima ssh -- sudo ctr -n k8s.io images import -

# Docker build for Java Aeron
docker build -t java-aeron:latest -f deploy/interop/Dockerfile.java-aeron deploy/interop/ --quiet
docker save java-aeron:latest | colima ssh -- sudo ctr -n k8s.io images import -

echo "=== [2/4] Deploying Interop Jobs ==="
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl delete -k deploy/interop/ --ignore-not-found
kubectl delete jobs -n $NAMESPACE -l $LABEL --ignore-not-found

# Apply kustomization
kubectl apply -k deploy/interop/

TOTAL=$(kubectl get jobs -n $NAMESPACE -l $LABEL -o jsonpath='{.items[*].metadata.name}' | wc -w | tr -d '[:space:]')
if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: No interop jobs matched label selector $LABEL"
    kubectl get jobs -n $NAMESPACE --show-labels
    exit 1
fi

echo "=== [3/4] Waiting for Jobs (Timeout: ${TIMEOUT}s) ==="
# Start a background process to tail logs if possible, or just wait
# We use a loop to check status so we can fail early if a pod crashes
start_time=$(date +%s)
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    if [ $elapsed -gt $TIMEOUT ]; then
        echo "ERROR: Timeout reached."
        break
    fi

    # Check if all jobs are complete
    COMPLETED=$(kubectl get jobs -n $NAMESPACE -l $LABEL -o jsonpath='{.items[*].status.succeeded}' | wc -w | tr -d '[:space:]')
    
    if [ "$COMPLETED" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
        echo "SUCCESS: All interop jobs completed successfully."
        exit 0
    fi

    # Check for failures
    FAILED=$(kubectl get jobs -n $NAMESPACE -l $LABEL -o jsonpath='{range .items[*]}{.status.failed}{" "}{end}' | tr -d '[:space:]')
    if [[ -n "$FAILED" && "$FAILED" != "0" ]]; then
        echo "ERROR: One or more jobs failed."
        break
    fi

    echo "Waiting... ($COMPLETED/$TOTAL jobs finished, ${elapsed}s elapsed)"
    sleep 5
done

echo "=== [FAILED] Printing Logs for Debugging ==="
PODS=$(kubectl get pods -n $NAMESPACE -l $LABEL -o jsonpath='{.items[*].metadata.name}')
for pod in $PODS; do
    echo "--- Logs for $pod ---"
    kubectl -n $NAMESPACE logs $pod --all-containers || true
done

exit 1
