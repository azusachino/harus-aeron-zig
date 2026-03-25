#!/usr/bin/env bash
# test/interop/k8s-verify.sh
# Usage: k8s-verify.sh [--smoke]
#   --smoke   Run quick smoke tests (10 msgs, 45s timeout) instead of full suite
set -euo pipefail

# Configuration
NAMESPACE="aeron"
SMOKE=0

for arg in "$@"; do
  case "$arg" in
    --smoke) SMOKE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [ "$SMOKE" -eq 1 ]; then
  LABEL="app.kubernetes.io/part-of=interop-smoke"
  KUSTOMIZE_DIR="deploy/interop/smoke"
  TIMEOUT=90
  echo "=== Interop Smoke Test (quick path — 10 messages per scenario) ==="
else
  LABEL="app.kubernetes.io/part-of=interop"
  KUSTOMIZE_DIR="deploy/interop"
  TIMEOUT=180
  echo "=== Interop Full Test Suite (100 messages per scenario) ==="
fi

echo ""
echo "=== [1/4] Building and Importing Images ==="
# Nix build for Zig OCI
nix build .#oci --quiet
docker load < result > /dev/null
docker save harus-aeron-zig:latest | colima ssh -- sudo ctr -n k8s.io images import -

# Docker build for Java Aeron
docker build -t java-aeron:latest -f deploy/interop/Dockerfile.java-aeron deploy/interop/ --quiet
docker save java-aeron:latest | colima ssh -- sudo ctr -n k8s.io images import -

echo "=== [2/4] Deploying Interop Jobs ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# Idempotent: delete existing jobs with this label before re-creating
kubectl delete jobs -n "$NAMESPACE" -l "$LABEL" --ignore-not-found
kubectl delete -k "$KUSTOMIZE_DIR" --ignore-not-found 2>/dev/null || true

kubectl apply -k "$KUSTOMIZE_DIR"

TOTAL=$(kubectl get jobs -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[*].metadata.name}' | wc -w | tr -d '[:space:]')
if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: No interop jobs matched label selector $LABEL"
  kubectl get jobs -n "$NAMESPACE" --show-labels
  exit 1
fi
echo "Deployed $TOTAL job(s). Waiting up to ${TIMEOUT}s for completion."

echo "=== [3/4] Waiting for Jobs (Timeout: ${TIMEOUT}s) ==="
start_time=$(date +%s)
while true; do
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))

  if [ "$elapsed" -gt "$TIMEOUT" ]; then
    echo "ERROR: Timeout reached after ${elapsed}s."
    break
  fi

  # Count succeeded jobs (each succeeded job contributes "1" to the list)
  COMPLETED=$(kubectl get jobs -n "$NAMESPACE" -l "$LABEL" \
    -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{" "}{end}' \
    | wc -w | tr -d '[:space:]')

  if [ "$COMPLETED" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "SUCCESS: All $TOTAL interop job(s) completed successfully."
    echo ""
    echo "=== [4/4] Results ==="
    kubectl get jobs -n "$NAMESPACE" -l "$LABEL" -o wide
    exit 0
  fi

  # Check for failures
  FAILED_NAMES=$(kubectl get jobs -n "$NAMESPACE" -l "$LABEL" \
    -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
  if [ -n "$FAILED_NAMES" ]; then
    echo "ERROR: One or more jobs failed: $FAILED_NAMES"
    break
  fi

  echo "Progress: $COMPLETED/$TOTAL jobs finished (${elapsed}s elapsed)"
  sleep 5
done

echo ""
echo "=== [FAILED] Printing Logs for Debugging ==="
PODS=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for pod in $PODS; do
  echo "--- Logs for pod: $pod ---"
  kubectl -n "$NAMESPACE" logs "$pod" --all-containers 2>/dev/null || echo "(no logs available)"
done

echo ""
echo "=== Job Status ==="
kubectl get jobs -n "$NAMESPACE" -l "$LABEL" -o wide 2>/dev/null || true

exit 1
