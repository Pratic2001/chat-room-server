# BOOTSTRAP.md

One-time setup, run on 192.168.0.111 as the `pratic` user, **before** the first Jenkins build.

The fastest path: `bash scripts/bootstrap.sh` does every step below. The checklist is here so you can run the same steps by hand or understand what the script is doing.

## 0. Prereqs

- 192.168.0.104 and 192.168.0.106 are reachable over SSH from 192.168.0.111 with pratic's ed25519 key (passwordless).
- The remote cluster is `kubectl get nodes` Ready.
- `mysql` client and `openssl` are installed on 192.168.0.111 (`apt install -y mysql-client openssl`).

## 1. StorageClass

The kubeadm cluster was installed without a default StorageClass. The MySQL PVC needs one, so we install `local-path-provisioner` (small, single-node-friendly, no RAID):

```bash
ssh pratic@192.168.0.104
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
kubectl get storageclass
```

The MySQL StatefulSet's PVC requests `storageClassName: local-path`; if you ever switch to a different provisioner, edit `k8s/30-mysql-statefulset.yaml`.

## 2. Passwordless sudo for the pipeline

The Jenkinsfile runs `sudo -n ctr -n k8s.io images import …` and `sudo -n kubectl …` on each k8s node. The Jenkins host already has SSH access to both nodes; the only piece we add is limited passwordless sudo for the pratic user, scoped to exactly those commands.

The bootstrap script installs the snippet on every node currently in the cluster, discovered via `kubectl get nodes`. Re-run `scripts/bootstrap.sh` after adding new nodes to install the snippet on them too. The snippet is identical on every node:

```bash
ssh pratic@<node-ip>
echo '%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images import *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images tag *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images ls *
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl *' \
  | sudo tee /etc/sudoers.d/99-jenkins-deploy
sudo chmod 440 /etc/sudoers.d/99-jenkins-deploy
exit
```

Verify from the Jenkins host:

```bash
ssh pratic@<node-ip> 'sudo -n ctr -n k8s.io images ls | head'
ssh pratic@<node-ip> 'sudo -n kubectl get nodes'
```

Both should run without prompting.

> The pratic user's day-to-day sudo is unchanged — only the four patterns above are NOPASSWD. This is the minimum the pipeline needs.

### Adding a new node to the cluster

The Jenkinsfile's Distribute stage auto-discovers all node IPs via `kubectl get nodes`, so it will pick up new nodes automatically. The only manual step on a new node is:

1. `ssh pratic@<new-node-ip>` once from the Jenkins host to add the host key.
2. Ensure the pratic user's SSH key is in `~/.ssh/authorized_keys` on the new node.
3. Re-run `bash scripts/bootstrap.sh` on 192.168.0.111 — it will install the sudoers snippet on the new node.

## 3. MySQL data migration (only if you have an existing DB)

The old MySQL on 192.168.0.111 has the chatroom_db the app currently uses. If you want to keep that data, dump it now and restore it into the cluster's MySQL after step 5 (the init Job creates the schema; you just need to add the data).

```bash
# On 192.168.0.111
mysqldump -u root -p --single-transaction --routines --triggers \
  --databases chatroom_db \
  | gzip > /tmp/chatroom_db.sql.gz

# Save it aside — we'll restore it AFTER the cluster MySQL is up and the
# init Job has run, by exec'ing into the pod.
scp /tmp/chatroom_db.sql.gz pratic@192.168.0.104:/tmp/
```

## 4. Run the bootstrap script

```bash
cd /home/pratic/Desktop/chat-room-server
bash scripts/bootstrap.sh
```

What it does, in order:

1. Verifies SSH to both k8s nodes.
2. Installs `local-path-provisioner` (step 1 above) if not already present.
3. Installs the sudoers snippet (step 2 above) on both nodes.
4. Applies `k8s/00-namespace.yaml` (creates the `chatroom` namespace).
5. Renders a ConfigMap from the repo's `database_setup.sql` into `k8s/35-mysql-init-job.yaml`'s volume mount.
6. Generates **random passwords** for MySQL root, the `chatroom` app user, the JWT secret, and the Fernet key. Writes them to `~/.chatroom-bootstrap/secrets.env` (mode 0600) — this is the **only** place these values live on disk. Then creates the live k8s `Secret`s with real values.
7. Applies `k8s/30-mysql-statefulset.yaml` and waits for `mysql-0` to be Ready (timeout 5 min).
8. Applies `k8s/35-mysql-init-job.yaml` and waits for the Job to complete. The Job applies the schema and creates the `chatroom` MySQL user.
9. Applies the remaining manifests: ConfigMap, app Deployment (placeholder tag), NodePort Service.
10. Patches `/etc/nginx/nginx.conf` so the existing TLS server proxies to `http://192.168.0.104:30800` (the new NodePort), with WebSocket upgrade headers and `client_max_body_size 100m`.

Re-running the script is safe — every step is gated by a marker file under `~/.chatroom-bootstrap/markers/`. Secret values are only generated on the first run; if `mysql-secret` already exists, the script skips generation and warns that rotation is a manual `kubectl edit secret`.

## 5. (If you migrated data) Restore the dump

```bash
ssh pratic@192.168.0.104
kubectl -n chatroom exec -i mysql-0 -- \
  bash -c 'gunzip | mysql -u root -p"$MYSQL_ROOT_PASSWORD" chatroom_db' \
  < /tmp/chatroom_db.sql.gz
```

(The env var is set on the StatefulSet's container, so the pod's `mysql` client can read it via `$$` if you need to expand it interactively. For a one-shot restore, it's simpler to copy the dump into the pod first and then exec the `mysql` client.)

## 6. Decommission the old MySQL (optional)

```bash
# On 192.168.0.111
sudo systemctl disable --now mysql        # or mariadb, depending on distro
# Close port 3306 in the firewall if it was open to the world.
```

And the old `uvicorn` process on 192.168.0.111 — once the cluster is serving traffic, it's no longer needed:

```bash
# Find it
ps -ef | grep uvicorn
# Kill it (only after the cluster has been live and serving 200s for at least 24h)
kill <pid>
```

## 7. Verify

```bash
# Pods
ssh pratic@192.168.0.104 'kubectl -n chatroom get pods'
# Expect: mysql-0 1/1, mysql-init 0/1 (Completed) or absent, chatroom-server-… pending until first build

# Schema
ssh pratic@192.168.0.104 'kubectl -n chatroom exec mysql-0 -- \
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"' \
  # (or use the password from ~/.chatroom-bootstrap/secrets.env)

# MySQL NodePort
ssh pratic@192.168.0.104 'kubectl -n chatroom get svc'
# Expect: chatroom-server NodePort 30800, mysql ClusterIP

# nginx (will 502 until first Jenkins build)
curl -kfsS https://localhost/healthz
# Expect: 502 with "connect() failed …" — that's fine, the pods aren't there yet
```

Once everything above is green, kick off the first Jenkins build (or `Build Now` in the UI). The first build distributes the image, smoke-tests it, deploys it, and verifies the `/healthz` round-trip through nginx.

## Troubleshooting

- **`kubectl -n chatroom exec mysql-0 -- mysql …` fails with "command not found"**: the official `mysql:8.0` image only ships the client as a *binary*; use `mysql -h 127.0.0.1 …` or exec into the pod interactively.
- **PVC pending forever**: the StorageClass isn't reachable. Check `kubectl describe pvc -n chatroom mysql-data-mysql-0`.
- **`mysql-init` Job stuck in `Pending`**: image pull failure or wrong node selector. Check `kubectl describe job -n chatroom mysql-init`.
- **App pods `ImagePullBackOff`**: the worker node doesn't have the image yet. Re-run the build, or manually `ctr -n k8s.io images import` on the worker.
