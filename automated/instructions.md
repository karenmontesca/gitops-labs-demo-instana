To run this:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export REPO_URL=https://github.com/karenmontesca/gitops-labs-demo-instana.git
export GITHUB_USER=karenmontesca
export GITHUB_TOKEN=<tu-token>
./bootstrap.sh´
```

Si no defines las variables, el script te las pregunta (el token se escribe oculto). Instala ArgoCD, espera a que esté listo, registra tu repo con el token, crea el Application con sus tres fuentes (chart, values y hooks) y espera el primer sync. Al final imprime la contraseña de admin y el comando del port-forward.

Para que funcione "solito" con el DaemonSet, cambia el comando de hooks/job.yaml en tu repo por esta versión, que reinicia lo que encuentre en el namespace:

```yaml
          command:
            - sh
            - -c
            - kubectl get daemonset -n instana-agent -o name | xargs -n1 kubectl rollout restart -n instana-agent
```
Tres cosas a vigilar:

La imagen bitnami/kubectl:latest: Bitnami cambió su política de imágenes en 2025, así que verifica que todavía se descargue. Si falla, puedes usar registry.k8s.io/kubectl con una versión fija, pero ten en cuenta que esa imagen puede no traer sh, por lo que habría que ajustar el comando.

El token en Git: el script no lo guarda en el repo, solo en un Secret dentro del cluster. En cambio, el agent.key sigue en tu values.yaml, lo cual está bien para el lab pero no para producción.

Si el Application se queda en OutOfSync: lo más común es que la URL del repo no coincida exactamente entre el Secret y el Application. El script usa la misma variable en ambos, así que debería coincidir.