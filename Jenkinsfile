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
        sh '''
          set -e
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
        sh '''
          set -e
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
          sh '''
            set -e
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
          sh '''
            set -e
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
          sh '''
            set -e
            # Jenkins is running against a freshly-cloned workspace
            # (see JENKINS_SETUP.md section 5/6). The k8s/ manifests
            # exist on the Jenkins agent, not on the control plane, so
            # we scp them across before invoking kubectl there.
            export TAG=${TAG}
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
              ssh $SSH_TARGET "kubectl apply -n ${NAMESPACE} -f <(envsubst < $REMOTE_K8S/$f)" || true
            done
            # The chatroom-secrets Secret is created by bootstrap.sh;
            # don't try to apply 10-secret.yaml (it would clobber real
            # values with the CHANGE_ME template).
            ssh $SSH_TARGET \
              "kubectl -n ${NAMESPACE} set image deployment/chatroom-server \
                 chatroom-server=docker.io/library/${IMAGE}:${TAG} --record"
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
        sh '''
          set -e
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
