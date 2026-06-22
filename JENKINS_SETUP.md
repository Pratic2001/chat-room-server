# JENKINS_SETUP.md

One-time setup of the Jenkins build host (192.168.0.111).

## Design note: Jenkins clones, never copies

Jenkins reads source by cloning the repo into its own workspace
(`$JENKINS_HOME/workspace/chatroom-server`). It never reads
`/home/pratic/Desktop/chat-room-server` directly. This avoids
"dubious ownership" errors, permission conflicts, and accidental
deploys of uncommitted local edits.

You have two options for exposing the source. Pick one.

## 1. Install Jenkins

```bash
# Jenkins LTS via the official apt repo (Ubuntu 26.04 / Debian)
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins-keyring.asc >/dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null
sudo apt update
sudo apt install -y jenkins
sudo systemctl enable --now jenkins
# Unlock with the initial admin password printed by the installer.
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://192.168.0.111:8080` and finish the install wizard.

## 2. Install the required plugins

`Manage Jenkins → Plugins → Available plugins`:

- **Pipeline**
- **Git**
- **SSH Agent**
- **Credentials Binding**
- **Timestamper**

Skip the suggested "Docker" and "Kubernetes" plugins — we drive everything from the Jenkinsfile + `sshagent`, so they add no value.

Restart Jenkins when prompted.

## 3. Install buildkit

```bash
sudo apt install -y buildkitd buildctl
sudo systemctl enable --now buildkitd
# Sanity check
sudo -u jenkins buildctl --addr unix:///run/buildkit/buildkitd.sock debug workers
```

The Jenkins user must be able to read the socket. The `apt` package sets this up by running `buildkitd` as a system service; if the socket is in a directory the `jenkins` user can't read, run:

```bash
sudo chmod 755 /run/buildkit
sudo systemctl restart buildkitd
```

`scripts/ensure-buildkit.sh` (called by the Jenkinsfile) is idempotent — it probes a known socket, and if none answers, falls back to a user-mode `buildkitd` under the running user.

## 4. Add the SSH credential

`Manage Jenkins → Credentials → System → Global credentials → Add Credentials`:

- Kind: **SSH Username with private key**
- ID: **`pratic-ssh`**
- Username: **`pratic`**
- Private key: paste the contents of `~/.ssh/id_ed25519` (the same key the pratic user uses to reach the k8s nodes from the Jenkins host)
- Passphrase: empty
- Treat username as secret: off

This credential is referenced by the Jenkinsfile as `sshagent(['pratic-ssh'])` and by the `SSH_CRED_ID` env var. Don't change the ID without updating the Jenkinsfile.

The same key is used for git SSH remotes if you pick option A below. Add its public half (`~/.ssh/id_ed25519.pub`) to your GitHub/Gitea account.

## 5. Expose the source to Jenkins

### Option A — Git remote (recommended)

From your dev machine:

```bash
cd /home/pratic/Desktop/chat-room-server
git remote add origin git@github.com:pratic/chat-room-server.git   # example
git push -u origin main
```

In the Jenkins job (step 6 below):
- Repository URL: `git@github.com:pratic/chat-room-server.git`
- Credentials: an SSH credential whose private key matches a key trusted by that remote (often the same `pratic-ssh` from step 4 if its public key is on the git host)

### Option B — Local bare repo on the Jenkins host

If you have no remote yet, create a bare clone on the same host and push to it:

```bash
# one-time, on 192.168.0.111 as pratic
git clone --bare /home/pratic/Desktop/chat-room-server \
              /home/pratic/chatroom-server.git

# from your dev machine
cd /home/pratic/Desktop/chat-room-server
git remote add jenkins /home/pratic/chatroom-server.git
git push jenkins main
```

In the Jenkins job:
- Repository URL: `file:///home/pratic/chatroom-server.git`
- Credentials: `- none -`

This works cleanly because the bare repo is owned by `pratic`, and
Jenkins reads it through the `pratic-ssh` agent (so the effective
filesystem user matches the owner). No `safe.directory` workaround is
needed — and even if it were, Jenkins wouldn't honour it because the
workspace directory is recreated on every build.

## 6. Create the pipeline job

`New Item → Pipeline`:

- Name: `chatroom-server`
- Definition: **Pipeline script from SCM**
- SCM: **Git**
  - Repository URL: per option A or B above
  - Credentials: per option A or B above
  - Branches to build: `*/main`
  - Script path: `Jenkinsfile`
- Build Triggers: **Poll SCM** with schedule `H/5 * * * *` (every 5 min, off the :00 mark). Switch to "GitHub hook trigger" once a webhook is set up.
- Save.

## 7. First build

`chatroom-server → Build Now`. Expected first-run failures and what they mean:

| Stage | Failure | Cause |
|---|---|---|
| `Checkout` | `dubious ownership` | You pointed the job at `/home/pratic/Desktop/chat-room-server` directly. Switch to option A or B above. |
| `Checkout` | `Permission denied (publickey)` | The git remote's authorized_keys doesn't include the public half of the credential's key. Add it. |
| `Distribute to cluster` | `Permission denied` running `sudo -n ctr` | The sudoers snippet in `BOOTSTRAP.md` step 2 wasn't applied. Re-run `scripts/bootstrap.sh`. |
| `Distribute to cluster` | `Image not found` on worker | Either ssh key doesn't include the worker, or the worker host key isn't trusted (`ssh pratic@192.168.0.106` once from the Jenkins host). |
| `Deploy` | `No such file or directory` for `k8s/*.yaml` | Older Jenkinsfile revision; pull the latest. The current Jenkinsfile scp's the manifests explicitly. |
| `Deploy` | `forbidden` from `kubectl apply` | `pratic` user doesn't have admin in the cluster. Re-run the bootstrap script. |
| `Deploy` | `ImagePullBackOff` on the new pod | The MySQL image (`mysql:8.0`) couldn't be pulled — check internet egress from the worker node. |
| `Verify` | `502 Bad Gateway` from nginx | The NodePort isn't reachable from the Jenkins host, OR no pods are yet Ready. Check `kubectl -n chatroom get pods`. |

Once the first green run completes, every push to `main` (on the
remote/bare repo, not your local working copy) triggers a real
rolling update.