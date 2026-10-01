# Instana Agent Configuration via GitOps and ArgoCD

This tutorial documents a full, hands-on lab: managing Instana agent configuration through Git, first on a classic VM host, then on Kubernetes with Helm and ArgoCD. It's written for people who are new to GitOps, Kubernetes, or Instana — every concept is explained before it's used, and every troubleshooting step is a real problem that came up while building this lab.

---

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Option 1: Classic VM Host — Git-based Configuration Management](#part-1-classic-vm-host)
3. [Option 2: Kubernetes — Manual Setup with Helm](#part-2-kubernetes-with-helm)
4. [Option 3: Kubernetes — True GitOps with ArgoCD](#part-3-argocd)
5. [Option 3.1: Closing the Loop — Automatic Pod Restarts with a PostSync Hook](#part-4-postsync-hook)
6. [Troubleshooting Log (real problems, real fixes)](#troubleshooting-log)
7. [Security Checklist](#security-checklist)
8. [Glossary](#glossary)

---

## Core Concepts

Before starting, I think it helps to understand a few ideas that show up everywhere in this guide.

**GitOps** — an approach to managing infrastructure where a Git repository is the single source of truth. Instead of logging into a machine and changing something by hand, you change a file in a repo, and some tool makes sure the real system matches what that file says.
So what's wrong with logging into a machine and changing things by hand? Many situations that have come up in my line of work. One of them is having to change many things in many servers. So one anecdote is that a client wanted to add a simple 'environment=PROD' tag in Instana to all of their hosts in production so they could find them easily in Instana. This is great, right? However, this client had about 50 servers, to add the tag in Instana means to go into each host, open the configuration.yaml change it, save it and restart the agent. Not to mention how messy it would get for Kubernetes situations. Another constant anecdote is that we want to help the client enable certain sensors in their configuration yaml. It's just a matter of adding an 'enable=true' in the yaml, but of course, we din't have access to their host, we cannot enter and edit their configuration yaml.

**Push model vs. Pull model** — the two ways GitOps can actually apply changes:

| | Push model | Pull model |
|---|---|---|
| Who initiates the connection? | An external system (e.g. GitHub Actions) reaches *into* your infrastructure | Your infrastructure reaches *out* to Git |
| Works behind a private network / firewall? | Only if the external system can reach you (often not, for home/office labs) | Yes - it only needs outbound internet access |
| Example in this guide | GitHub Actions calling `helm upgrade` | ArgoCD running inside the cluster |

This distinction matters a lot in practice: if your infrastructure lives on a private network (like VMs on a home lab), a push-based pipeline (GitHub Actions with a cloud runner) usually **cannot reach it**. A pull-based tool running inside your own network doesn't have that problem.

**Helm** a package manager for Kubernetes. Instead of writing dozens of raw YAML files by hand, you use a pre-built "chart" (a template) and supply your own values.

**ArgoCD** a tool that runs inside a Kubernetes cluster and continuously compares "what the Git repo says" against "what's actually running," correcting any difference automatically.

**Application (ArgoCD)** the basic unit of work in ArgoCD: an object that says "watch this repo, apply it to this namespace."

**Sync** the act of applying what the repo says to the real cluster.

**Drift** when the running cluster no longer matches the repo (e.g., someone ran `kubectl edit` by hand).

**Self-heal** an ArgoCD option that automatically corrects drift, even reverting manual changes.

**Prune** an ArgoCD option that deletes resources from the cluster if they were removed from the repo.

---

## Option 1: Classic VM Host: Git-based Configuration Management (public github repository)

The traditional Instana host agent (installed directly on a Linux VM) has a **built-in Git client**. It can clone a Git repository directly into its own internal folder and use it as its configuration source, no external tooling required.

### How it fits together

- **Your Git repo** = the source of truth. It should mirror the folder structure inside `<agentInstallDir>/etc/`. In most cases that just means an `instana/` folder containing your `configuration.yaml`.
- **Your laptop** = your working copy, where you edit and `git push`. Nothing here matters to the agent directly, it's just where you make changes before they reach GitHub.
- **The host (VM)** = where the agent actually runs, and clones the repo internally.

```
instana-gitops-lab/
└── instana/
    └── configuration.yaml
```

### Connecting a host to the repo

In the Instana UI: **Agent Dashboard → Configuration Management → Initialize**, then supply the repository URL and branch. This is the same as calling the API directly:

```bash
curl --request POST \
  --url "https://<your-tenant>.instana.io/api/host-agent/configuration?query=entity.host.name:LABS" \
  --header "authorization: apiToken $INSTANA_API_TOKEN" \
  --header "content-type: application/json" \
  --data '{
    "remoteUri": "https://github.com/<you>/instana-gitops-lab.git",
    "remoteBranch": "main",
    "remoteName": "configuration"
  }'
```

### Updating configuration afterwards

Editing the repo does **not** update the host instantly. Two separate things happen:

1. `git push` → updates the repo. That's it, nothing on the host knows yet.
2. Something tells the agent to re-pull and reload: either restart the instana agent (`systemctl restart instana-agent`), or call the same API endpoint **without** the body, just the `query`, to trigger it remotely.

### Scaling to a fleet of hosts

The `query` parameter accepts filters like `entity.tag:environment=prod`, which can match **many hosts at once** — both when initially connecting them and when triggering updates. Combine this with branches (one branch per environment) so different groups of hosts track different configurations.

---

## Option 2: Kubernetes (Manual Setup with Helm)

In Kubernetes, there's no standalone `configuration.yaml` file living on a "host" — the agent runs as a **DaemonSet** (one pod per node), and its configuration is supplied inline through Helm's `values.yaml`.

### Get your Agent Key and Endpoint (Installing the Instana Agent)

From Instana: **Settings → Agents → Installation → Kubernetes**.

### Create `values.yaml`

```yaml
agent:
  key: "<YOUR_AGENT_KEY>"
  downloadKey: "<YOUR_AGENT_KEY>"
  endpointHost: "<YOUR_ENDPOINT_HOST>"
  endpointPort: "443"
  configuration_yaml: |
    com.instana.plugin.host:
      tags:
        - 'lab'

cluster:
  name: "instana-lab"

zone:
  name: "instana-lab-zone"
```

### Install

```bash
kubectl create namespace instana-agent

helm install instana-agent \
  --repo https://agents.instana.io/helm \
  --namespace instana-agent \
  -f values.yaml \
  instana-agent
```

### Verify

```bash
kubectl get pods -n instana-agent -o wide
```

You should see one pod per node, all `Running`.

### Updating manually

Edit `values.yaml`, then:

```bash
helm upgrade instana-agent \
  --repo https://agents.instana.io/helm \
  --namespace instana-agent \
  -f values.yaml \
  instana-agent

kubectl rollout restart daemonset instana-agent -n instana-agent
```

> **Note:** modern versions of the Instana Helm chart install an **Operator** under the hood (you'll see resources like `instana-agent-controller-manager` and a custom resource of kind `InstanaAgent`). This doesn't change how you use Helm, but it does change how you diagnose things later — see Part 4.

---

## Opction 3: Kubernetes (GitOps with ArgoCD)

### Why ArgoCD instead of a CI/CD pipeline (e.g. GitHub Actions)?

A GitHub Actions workflow uses the **push model**: a cloud-hosted runner tries to reach *into* your cluster to run `helm upgrade`. If your cluster lives on a private network (like VMs on a home/office lab), this may not work (unreachable network). Installing a self-hosted runner is one workaround, but ArgoCD solves this more directly: it runs **inside your cluster** and reaches *out* to GitHub, so no inbound connectivity is required.

### Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd
```

### Access the UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0
```

> This command must keep running the entire time you use the UI. If your SSH session drops (idle timeout, laptop sleep, Wi-Fi blip), the tunnel dies with it. Consider running it inside `tmux` so it survives a dropped SSH connection:
> ```bash
> tmux new -s argocd-tunnel
> kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0
> # detach with Ctrl+B then D — reattach later with: tmux attach -t argocd-tunnel
> ```

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Open `https://<your-VM-IP>:8080`, log in as `admin`.

### If your Git repo is private (As it should be)

Go to **Settings → Repositories → Connect Repo**:
- **Repository URL:** `https://github.com/<you>/<your-repo>.git`
- **Username:** your GitHub username
- **Password:** a GitHub **Personal Access Token**

### The key idea: two sources, combined

Your Git repo only contains *your values* (the tag, the zone, the agent key), it does **not** contain the full Helm chart (the DaemonSet template, RBAC rules, etc.). ArgoCD needs **both**: the official chart (the "recipe") and your values file (the "toppings"). This is done with ArgoCD's **multi-source Application** feature:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: instana-agent
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://agents.instana.io/helm
      chart: instana-agent
      targetRevision: "*"
      helm:
        valueFiles:
          - $values/values.yaml
    - repoURL: https://github.com/<you>/<your-repo>.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: instana-agent
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f instana-application.yaml
```

**Important:** don't remove the Instana chart source to "simplify" this. Without it, ArgoCD has nothing to build from, and it will interpret the missing chart as "delete everything," triggering ArgoCD's built-in safety brake (see Troubleshooting Log below).

### What happens, step by step, after you edit `values.yaml`

1. You edit `values.yaml` and `git push`.
2. ArgoCD polls the repo (every 3 minutes by default, or on-demand via the **Refresh** button) and notices the commit changed.
3. ArgoCD fetches both sources: the Instana chart (unchanged) and your updated values.
4. ArgoCD renders them together (conceptually, `helm template --values values.yaml`), producing the final manifests.
5. ArgoCD compares that result against what's currently running (`Synced` vs `OutOfSync`).
6. With `selfHeal: true`, ArgoCD applies the difference automatically (no human runs `helm upgrade`).
7. The Instana agent's underlying objects (ConfigMap / custom resource) get updated.

You only ever touch step 1. Everything else is automatic.

---

## Option 3.1: Closing the Loop (Automatic Pod Restarts with a PostSync Hook)

There's a subtlety: updating a ConfigMap or custom resource does **not** automatically make an already-running pod re-read it. A pod reads its configuration once, at startup. Something has to explicitly tell Kubernetes "recreate this pod", otherwise the new configuration sits there, correctly applied, but ignored by anything already running.

ArgoCD's **PostSync Hook** solves this: a Kubernetes `Job` that runs automatically right after each successful sync.

### 1. Confirm your DaemonSet's real name

```bash
kubectl get daemonset -n instana-agent
```

Use this exact name in the Job below (this guide assumes it's `instana-agent`, which is the default).

### 2. Create the hook's RBAC and Job manifests

Create a folder called `hooks`and create the following 4 YAML files in it:

`hooks/serviceaccount.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-instana-hook
  namespace: instana-agent
```

`hooks/role.yaml`:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: restart-daemonset
  namespace: instana-agent
rules:
  - apiGroups: ["apps"]
    resources: ["daemonsets"]
    verbs: ["get", "list", "patch"]
```

`hooks/rolebinding.yaml`:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-instana-hook-binding
  namespace: instana-agent
subjects:
  - kind: ServiceAccount
    name: argocd-instana-hook
    namespace: instana-agent
roleRef:
  kind: Role
  name: restart-daemonset
  apiGroup: rbac.authorization.k8s.io
```

`hooks/job.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: restart-instana-agent
  namespace: instana-agent
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      serviceAccountName: argocd-instana-hook
      restartPolicy: Never
      containers:
        - name: kubectl
          image: bitnami/kubectl:latest
          command:
            - sh
            - -c
            - kubectl rollout restart daemonset instana-agent -n instana-agent
```

The two annotations are what make this a hook:
- `argocd.argoproj.io/hook: PostSync` → run this after every successful sync.
- `argocd.argoproj.io/hook-delete-policy: HookSucceeded` → delete the Job automatically once it succeeds, so they don't pile up.

### 3. Push, and add a third source

```bash
git add hooks/
git commit -m "add postsync hook to restart agent on config change"
git push
```

Add a third entry to your Application's `sources`:

```yaml
    - repoURL: https://github.com/<you>/<your-repo>.git
      targetRevision: main
      path: hooks
```

```bash
kubectl apply -f instana-application.yaml
```

### 4. Test end-to-end

Edit `values.yaml`, push, and touch nothing else. Within a few minutes you should see:
- ArgoCD syncs automatically.
- A `Job` named `restart-instana-agent` briefly appears in the app tree, runs, and disappears.
- `kubectl get pods -n instana-agent` shows freshly restarted pods.
- Instana reflects the new configuration.

At this point, there's no manual step left between `git push` and the change showing up in Instana.

---

## Troubleshooting Log

Real problems encountered while building this lab, and how they were diagnosed.

### "not authorized" when connecting a VM host to Git

```
org.eclipse.jgit.api.errors.TransportException: ...: not authorized
```
GitHub deprecated password authentication for Git operations. Use a **Personal Access Token** instead, stored in `.netrc`:
```
machine github.com
login <your-username>
password <your-token>
```

### `helm`/`kubectl` commands failing on Windows with weird file errors

Notepad silently saves files with a hidden `.txt` extension (`config.yaml` instead of `config`, `values.yaml.txt` instead of `values.yaml`). Always verify with `dir` after saving, or just use Visual Studio Code or another IDE, or edit on the Linux side (`vi`) instead, it doesn't have this problem.

### `kubectl` defaulting to `localhost:8080`

This means it couldn't find `~/.kube/config` at all, usually because of the file-extension issue above, or because `KUBECONFIG` is pointing elsewhere:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```
### `curl: Could not resolve host` inside a VM

DNS resolution failing while ping-by-IP works confirms a **DNS-specific** issue, not a general connectivity one. Check `/etc/resolv.conf`; on RHEL with NetworkManager, this file can be regenerated on reboot, so a manual fix may not be permanent (use `nmcli` for a lasting change.)

### CoreDNS / metrics-server stuck in `CrashLoopBackOff`

```
Liveness probe failed: ... context deadline exceeded
```
Multiple core services crash-looping simultaneously is a classic sign of a **starved node** (CPU or memory), not a config bug. Check:
```bash
free -h
uptime   # look at load average vs. number of vCPUs
```
A lab VM with 1.5–2GB RAM running k3s + ArgoCD + an agent is undersized. 4GB+ RAM and 2 vCPUs on the control-plane node is a safer minimum.

### ArgoCD: `repository not accessible` / `authentication required: Repository not found`

Usually one of:
- The repo URL registered under **Settings → Repositories** doesn't exactly match the `repoURL` used in the `Application` (case, trailing `.git`, etc.).
- The token is invalid, expired, or missing the `repo` scope.
- You changed the repo but only updated one of the two places it's referenced.

### ArgoCD: `Skipping sync attempt: auto-sync will wipe out all resources`

This is a **safety feature**, not a bug. It happens when the rendered manifests would result in deleting everything currently running, usually because one of the multiple `sources` (e.g. the Helm chart source) was accidentally removed from the `Application` spec, leaving only "values with nothing to apply them to." Restore the full `sources` list.

### A configuration change reaches the cluster but never reaches Instana

Check in order:
1. Did the commit actually reach GitHub? (`git status`, `git log`)
2. Did ArgoCD sync to that commit? (`kubectl get application <name> -n argocd -o jsonpath='{.status.sync.revisions}'`)
3. Did the underlying object (ConfigMap / custom resource) actually update? (`kubectl get instanaagent <name> -n <ns> -o yaml`)
4. Did the **pod** restart to pick it up? Pods don't hot-reload a changed ConfigMap on their own — see Part 4.

---

## Security Checklist

- [ ] Don't commit `agent.key` in plaintext to a public repo. Use a Kubernetes `Secret` or your pipeline's secret store. (This is a lab so it doesn't really matter for this test)
- [ ] Use a fine-grained GitHub Personal Access Token, scoped to a single repository, read-only where possible.
- [ ] If you set an expiration date on tokens and have a rotation plan, an expired token breaks every host/cluster using it simultaneously.
- [ ] `.netrc` files should have `600` permissions.
- [ ] Keep consistent environment tags (e.g. `environment=prod`) across your fleet, the API's `query` filters depend on them being accurate.

---

## Glossary

| Term | Meaning |
|---|---|
| GitOps | Managing infrastructure by treating a Git repo as the source of truth |
| Push model | An external system reaches into your infrastructure to apply changes |
| Pull model | Your infrastructure reaches out to Git to check for changes |
| Helm | A package manager for Kubernetes; charts are templates, values are your customizations |
| DaemonSet | A Kubernetes controller that ensures one pod runs on every node |
| ArgoCD | A GitOps controller that runs inside Kubernetes, syncing it against Git |
| Application (ArgoCD) | The object that tells ArgoCD which repo to watch and where to apply it |
| Sync | Applying what Git says onto the real cluster |
| OutOfSync | The cluster's state doesn't match the repo |
| Drift | Unintended divergence between the cluster and the repo (e.g., a manual `kubectl edit`) |
| Self-heal | ArgoCD automatically correcting drift |
| Prune | ArgoCD deleting resources that were removed from the repo |
| Hook (PreSync/Sync/PostSync) | An extra Job ArgoCD runs at a specific point in the sync process |
| Operator | A Kubernetes controller that manages an application's full lifecycle via a Custom Resource |