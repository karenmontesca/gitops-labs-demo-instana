#!/usr/bin/env bash
#
# bootstrap.sh - one-command GitOps bootstrap for the Instana agent.
#
# What it does:
#   1. Installs ArgoCD into the "argocd" namespace
#   2. Waits until ArgoCD and its CRDs are ready
#   3. Registers your (private) Git repo using a Personal Access Token
#   4. Creates the multi-source ArgoCD Application
#      (Instana Helm chart + your values.yaml + the hooks/ folder)
#   5. Waits for the first sync and prints how to reach the ArgoCD UI
#
# Required (env vars or you will be prompted):
#   REPO_URL      e.g. https://github.com/<you>/gitops-labs-demo-instana.git
#   GITHUB_USER   your GitHub username
#   GITHUB_TOKEN  a fine-grained, read-only Personal Access Token
#
# Optional:
#   TARGET_REVISION  branch to track              (default: main)
#   AGENT_NAMESPACE  namespace for the agent      (default: instana-agent)
#   ARGOCD_VERSION   ArgoCD release, e.g. v2.13.0 (default: stable)
#   APP_NAME         name of the Application      (default: instana-agent)
#   WAIT_TIMEOUT     seconds to wait for steps    (default: 300)
#
# Usage:
#   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # if needed
#   export REPO_URL=https://github.com/<you>/<repo>.git
#   export GITHUB_USER=<you>
#   export GITHUB_TOKEN=<token>
#   ./bootstrap.sh

set -euo pipefail

TARGET_REVISION="${TARGET_REVISION:-main}"
AGENT_NAMESPACE="${AGENT_NAMESPACE:-instana-agent}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
APP_NAME="${APP_NAME:-instana-agent}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"
ARGOCD_NS="argocd"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH."

if [ -z "${REPO_URL:-}" ]; then
  read -r -p "Git repo URL (https://github.com/<you>/<repo>.git): " REPO_URL
fi
if [ -z "${GITHUB_USER:-}" ]; then
  read -r -p "GitHub username: " GITHUB_USER
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
  read -r -s -p "GitHub Personal Access Token (input hidden): " GITHUB_TOKEN
  echo
fi

[ -n "$REPO_URL" ]     || die "REPO_URL is empty."
[ -n "$GITHUB_USER" ]  || die "GITHUB_USER is empty."
[ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN is empty."

case "$REPO_URL" in
  https://*) ;;
  *) die "REPO_URL must start with https:// (SSH URLs need a different secret)." ;;
esac

log "Checking cluster access..."
kubectl cluster-info >/dev/null 2>&1 \
  || die "Cannot reach the cluster. Check KUBECONFIG (e.g. export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)."

# ---------------------------------------------------------------------------
# 1. Install ArgoCD
# ---------------------------------------------------------------------------
log "Creating namespace '$ARGOCD_NS' (if missing)..."
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [ "$ARGOCD_VERSION" = "stable" ]; then
  MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
else
  MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
fi

log "Installing ArgoCD ($ARGOCD_VERSION)..."
# --server-side avoids the "annotation too long" error on ArgoCD's large CRDs.
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NS" -f "$MANIFEST_URL" >/dev/null

# ---------------------------------------------------------------------------
# 2. Wait for ArgoCD to be ready
# ---------------------------------------------------------------------------
log "Waiting for ArgoCD CRDs..."
kubectl wait --for=condition=Established --timeout="${WAIT_TIMEOUT}s" \
  crd/applications.argoproj.io crd/appprojects.argoproj.io

log "Waiting for ArgoCD components (this can take a few minutes on small nodes)..."
for d in argocd-server argocd-repo-server argocd-redis argocd-applicationset-controller; do
  kubectl rollout status "deployment/$d" -n "$ARGOCD_NS" --timeout="${WAIT_TIMEOUT}s"
done
kubectl rollout status statefulset/argocd-application-controller \
  -n "$ARGOCD_NS" --timeout="${WAIT_TIMEOUT}s"

# ---------------------------------------------------------------------------
# 3. Register the Git repo (replaces Settings -> Repositories -> Connect Repo)
# ---------------------------------------------------------------------------
log "Registering repository credentials..."
# The token goes through stdin, never through the command line.
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-instana-gitops
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${REPO_URL}
  username: ${GITHUB_USER}
  password: ${GITHUB_TOKEN}
EOF

# ---------------------------------------------------------------------------
# 4. Create the multi-source Application
# ---------------------------------------------------------------------------
log "Creating ArgoCD Application '$APP_NAME'..."
kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NS}
spec:
  project: default
  sources:
    # 1) The official Instana Helm chart (the "recipe")
    - repoURL: https://agents.instana.io/helm
      chart: instana-agent
      targetRevision: "*"
      helm:
        valueFiles:
          - \$values/values.yaml
    # 2) Your values.yaml (the "toppings")
    - repoURL: ${REPO_URL}
      targetRevision: ${TARGET_REVISION}
      ref: values
    # 3) The PostSync hook that restarts the agent after each sync
    - repoURL: ${REPO_URL}
      targetRevision: ${TARGET_REVISION}
      path: hooks
  destination:
    server: https://kubernetes.default.svc
    namespace: ${AGENT_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# ---------------------------------------------------------------------------
# 5. Wait for the first sync
# ---------------------------------------------------------------------------
log "Waiting for the first sync (up to ${WAIT_TIMEOUT}s)..."
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
sync_status=""
health_status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sync_status="$(kubectl get application "$APP_NAME" -n "$ARGOCD_NS" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kubectl get application "$APP_NAME" -n "$ARGOCD_NS" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  printf '    sync=%s health=%s\n' "${sync_status:-?}" "${health_status:-?}"
  if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
    break
  fi
  sleep 10
done

if [ "$sync_status" != "Synced" ]; then
  warn "Application is not Synced yet. Check the conditions with:"
  warn "  kubectl describe application $APP_NAME -n $ARGOCD_NS"
  warn "Common causes: repo URL mismatch, expired token, missing 'repo' scope."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
ADMIN_PASSWORD="$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

echo
log "Bootstrap finished."
echo "  Agent pods:     kubectl get pods -n $AGENT_NAMESPACE -o wide"
echo "  ArgoCD UI:      kubectl port-forward svc/argocd-server -n $ARGOCD_NS 8080:443 --address 0.0.0.0"
echo "                  then open https://<your-VM-IP>:8080"
echo "  ArgoCD login:   admin / ${ADMIN_PASSWORD:-<secret not found>}"
echo
echo "From now on, edit values.yaml, git push, and ArgoCD does the rest."