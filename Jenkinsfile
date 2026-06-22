// Jenkinsfile — declarative pipeline for chat-room-server.
//
// Stages:
//   Checkout → Lint → Ensure BuildKit → Build app image → Distribute to
//   cluster (sshagent to both nodes, ctr import) → Smoke test → Deploy
//   (envsubst + kubectl apply + set image + rollout status) → Verify.
//
// Source layout: the Jenkinsfile lives at the repo root. The pipeline
// runs against whatever Jenkins cloned into $WORKSPACE — typically a
// fresh clone from a git remote or a local bare repo. It never reads
// the developer's personal working copy.
//
// Required Jenkins plugins: Pipeline, Git, SSH Agent, Credentials
// Binding, Timestamper.
//
// Required Jenkins credential: `pratic-ssh` (SSH Username with private
// key, username `pratic`, key = the local pratic user's ed25519 key).

pipeline {
  agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    IMAGE         = "chatroom-server"
    // Tag is the git short SHA plus the Jenkins build number, e.g.
    // "abc1234-42". Unique, traceable, and the only thing that varies
    // between builds (so `kubectl rollout undo` goes to a known tag).
    TAG           = "${sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()}-${BUILD_NUMBER}"
    // Used only for the Verify stage, which curls /healthz through the
    // NodePort. The Distribute and Deploy stages discover all nodes
    // dynamically via `kubectl get nodes`, so adding or removing nodes
    // does not require editing this file.
    K8S_API       = "192.168.0.104"
    SSH_USER      = "pratic"
    SSH_CRED_ID   = "pratic-ssh"
    APP_NODEPORT  = "30800"
    TAR           = "/tmp/${IMAGE}-${TAG}.tar"
    NAMESPACE     = "chatroom"
    // The buildkitd socket is started by scripts/ensure-buildkit.sh.
    BUILDKIT_HOST = "unix:///run/buildkit/buildkitd.sock"
  }

  stages {

    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Lint') {
      steps {
        sh '''#!/bin/bash
          # Force bash: Jenkins' sh step defaults to /bin/sh (dash on
          # Debian/Ubuntu), which lacks `[[ ]]`, `mapfile`, and
          # `<(...)`. Stages that need any of those must be bash.
          set -euo pipefail
          if which hadolint >/dev/null 2>&1; then
            hadolint Dockerfile
          else
            echo "hadolint not installed; skipping Dockerfile lint"
          fi
        '''
      }
    }

    stage('Ensure BuildKit') {
      steps {
        sh 'bash scripts/ensure-buildkit.sh'
      }
    }

    stage('Build app image') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          # The build context is the repo root. .dockerignore keeps .env,
          # k8s/, *.pem etc. out of the image.
          buildctl --addr "$BUILDKIT_HOST" build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt filename=Dockerfile \
            --output type=image,name=${IMAGE}:${TAG},push=false \
            --output type=oci,dest=${TAR}
          ls -lh ${TAR}
        '''
      }
    }

    stage('Distribute to cluster') {
      steps {
        sshagent([SSH_CRED_ID]) {
          sh '''#!/bin/bash
            # This stage needs bash (not dash) for two reasons:
            #   (a) `mapfile -t NODES < <(...)` uses process
            #       substitution, which dash's parser rejects with
            #       "Syntax error: redirection unexpected".
            #   (b) `[[ ${#NODES[@]} -eq 0 ]]` is a bash keyword; dash
            #       only has `[ ... ]` (and that one would need
            #       different quoting too).
            # The shebang above makes Jenkins re-exec this script with
            # bash. `set -o pipefail` is also load-bearing here: the
            # `ssh ... | sort -u` pipeline would otherwise swallow
            # ssh's non-zero exit (sort sees empty input and exits 0),
            # and a failed node-discovery would silently look like an
            # empty cluster.
            set -euo pipefail
            # Discover all node InternalIPs from the cluster. This way,
            # adding or removing nodes does not require editing this
            # Jenkinsfile — the next build picks them up automatically.
            #
            # Requires: SSH_USER can ssh to every node and has the
            # passwordless-sudo snippet from scripts/bootstrap.sh
            # installed (/usr/bin/ctr -n k8s.io images …).
            mapfile -t NODES < <(
              ssh ${SSH_USER}@${K8S_API} \
                "sudo -n kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}'" \
                | sort -u
            )
            if [[ ${#NODES[@]} -eq 0 ]]; then
              echo "no nodes discovered via kubectl; check kubeconfig and SSH access" >&2
              exit 1
            fi
            echo "discovered ${#NODES[@]} node(s): ${NODES[*]}"
            HOSTS=()
            for n in "${NODES[@]}"; do HOSTS+=("${SSH_USER}@${n}"); done
            bash scripts/distribute-image.sh ${TAR} "${HOSTS[@]}"
            echo "--- images present on each node ---"
            for n in "${NODES[@]}"; do
              ssh ${SSH_USER}@${n} "sudo -n ctr -n k8s.io images ls | grep ${IMAGE} || echo 'NOT FOUND on ${n}'"
            done
          '''
        }
      }
    }

    stage('Smoke test (any node)') {
      steps {
        sshagent([SSH_CRED_ID]) {
          sh '''#!/bin/bash
            set -euo pipefail
            REF=docker.io/library/${IMAGE}:${TAG}
            # Pick any node to run the smoke test on. We use the
            # control plane (K8S_API) because it's the same host that
            # owns the kubectl config. The image has been ctr-imported
            # to every node by the Distribute stage, so this would
            # work on any node — but K8S_API is the most predictable.
            ssh ${SSH_USER}@${K8S_API} \
              "sudo -n ctr -n k8s.io run --rm \
                 --net-host \
                 ${REF} ${REF} \
                 sh -c 'sleep 4 && curl -fsS http://127.0.0.1:8000/healthz && echo'"
          '''
        }
      }
    }

    stage('Deploy') {
      steps {
        sshagent([SSH_CRED_ID]) {
          sh '''#!/bin/bash
            set -euo pipefail
            # Jenkins is running against a freshly-cloned workspace
            # (see JENKINS_SETUP.md section 5/6). The k8s/ manifests
            # exist on the Jenkins agent, not on the control plane, so
            # we scp them across before invoking kubectl there.
            #
            # Three gotchas this stage used to get wrong (and that this
            # rewrite fixes):
            #
            #   (1) The remote control-plane's /bin/sh is dash, which
            #       does NOT support process substitution `<(...)`.
            #       The previous form `kubectl apply -f <(envsubst < …)`
            #       therefore crashed silently (the `|| true` later in
            #       the loop swallowed the error), the deployment never
            #       got its image tag, and the pods sat in
            #       InvalidImageName for ~4 minutes. We now write
            #       envsubst's output to a temp file on the remote and
            #       `kubectl apply -f` it.
            #
            #   (2) envsubst with no args substitutes every ${VAR} in
            #       the yaml and treats unset vars as empty, which would
            #       clobber any other $ in the file. The restricted
            #       form `envsubst '${TAG}'` substitutes ONLY $TAG and
            #       leaves everything else (ConfigMap data, kustomize
            #       patches, etc.) alone.
            #
            #   (3) The remote ssh shell has no $TAG in its env. We
            #       can't just prepend `TAG=…` to the remote command,
            #       because OpenSSH strips non-LC_* env vars on the
            #       server side (AcceptEnv default). We pipe the tag
            #       over ssh's stdin (which always passes through) and
            #       `read` + `export` it on the remote before calling
            #       envsubst. envsubst only sees exported variables.
            #
            #   (4) The previous loop ended with `|| true`, which
            #       swallowed any failure from the broken
            #       process-substitution form. We no longer swallow
            #       errors — a failure here is loud and aborts the
            #       stage, which is the right behaviour.

            # $IMAGE and $TAG below are expanded by the LOCAL shell
            # (the Jenkins agent's bash) before ssh runs, so they get
            # embedded in the remote command as literal characters.
            # No env propagation needed for the set image line.
            SSH_TARGET=${SSH_USER}@${K8S_API}
            REMOTE_K8S=/tmp/chatroom-k8s-${BUILD_NUMBER}
            ssh $SSH_TARGET "rm -rf $REMOTE_K8S && mkdir -p $REMOTE_K8S"
            scp -o StrictHostKeyChecking=no \
              k8s/00-namespace.yaml \
              k8s/20-configmap.yaml \
              k8s/40-deployment.yaml \
              k8s/50-service.yaml \
              $SSH_TARGET:$REMOTE_K8S/
            for f in 00-namespace.yaml 20-configmap.yaml 40-deployment.yaml 50-service.yaml; do
              ssh "pratic@${K8S_API}" '
                set -e
                # envsubst only sees exported variables, and OpenSSH
                # strips non-LC_* env vars on the server side (see the
                # AcceptEnv default). Workaround: pipe the tag over ssh
                # stdin (always passes through) and export it before
                # calling envsubst.
                IFS= read -r BUILD_TAG
                export TAG="$BUILD_TAG"
                # envsubst restricted form. Note: the single quotes
                # around ${TAG} are load-bearing — they prevent the
                # *local* shell (the one running this script) from
                # expanding ${TAG} before envsubst sees it. envsubst
                # needs the literal string "${TAG}" as its allowlist
                # arg, NOT the value of $TAG.
                envsubst '"'"'${TAG}'"'"' < '"$REMOTE_K8S"'/'"$f"' > '"$REMOTE_K8S"'/'"$f"'.sub
                mv '"$REMOTE_K8S"'/'"$f"'.sub '"$REMOTE_K8S"'/'"$f"'
                kubectl apply -n '"${NAMESPACE}"' -f '"$REMOTE_K8S"'/'"$f"'
              ' <<<"${TAG}"
            done
            # Reaffirm the image tag explicitly. This makes the deploy
            # idempotent — even if a previous build's apply left an old
            # tag, this overrides it. --record is deprecated but kept
            # so the kubernetes.io/change-cause annotation still gets
            # written for rollback discoverability.
            ssh $SSH_TARGET "
              kubectl -n ${NAMESPACE} set image deployment/chatroom-server \
                chatroom-server=docker.io/library/${IMAGE}:${TAG} --record=true
            "
            ssh $SSH_TARGET \
              "kubectl -n ${NAMESPACE} rollout status deployment/chatroom-server --timeout=180s"
            ssh $SSH_TARGET \
              "kubectl -n ${NAMESPACE} get deploy,pods,svc -o wide"
            ssh $SSH_TARGET "rm -rf $REMOTE_K8S"
          '''
        }
      }
    }

    stage('Verify') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          sleep 3
          echo "--- direct NodePort ---"
          curl -fsS --max-time 5 http://${K8S_API}:${APP_NODEPORT}/healthz && echo
          echo "--- via nginx (TLS terminated on Jenkins host) ---"
          curl -kfsS --max-time 5 https://localhost/healthz && echo
        '''
      }
    }
  }

  post {
    success {
      echo "Deployed ${env.IMAGE}:${env.TAG} to namespace ${env.NAMESPACE}."
      sh "rm -f ${env.TAR}"
    }
    failure {
      echo "Build failed; previous version of chatroom-server is still serving."
    }
    always {
      sh "rm -f /tmp/chatroom-server-*.tar || true"
    }
  }
}
