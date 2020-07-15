#!/bin/bash
set -e
PRIMEHUB_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
cd $PRIMEHUB_ROOT

export PRIMEHUB_MODE=${PRIMEHUB_MODE:-ce}
export PRIMEHUB_DOMAIN=hub.ci-e2e.dev.primehub.io
export PRIMEHUB_PASSWORD=${PH_PASSWORD}
export PRIMEHUB_PORT=${PRIMEHUB_PORT:-8080}
export KEYCLOAK_DOMAIN=id.ci-e2e.dev.primehub.io
export KEYCLOAK_PASSWORD=$(openssl rand -hex 16)
export STORAGE_CLASS=local-path
export GRAPHQL_SECRET_KEY=$(openssl rand -hex 32)
export HUB_AUTH_STATE_CRYPTO_KEY=$(openssl rand -hex 32)
export HUB_PROXY_SECRET_TOKEN=$(openssl rand -hex 32)

echo "apply metacontroller yaml"
# Create metacontroller namespace.
kubectl create namespace metacontroller
# Create metacontroller service account and role/binding.
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/metacontroller/master/manifests/metacontroller-rbac.yaml
# Create CRDs for Metacontroller APIs, and the Metacontroller StatefulSet.
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/metacontroller/master/manifests/metacontroller.yaml

cd ../chart
helm dependency update
helm dependency list
cd -

echo "install primehub chart"
cat <<EOF > primehub-values.yaml
primehub:
  mode: ${PRIMEHUB_MODE}
  scheme: http
  domain: ${PRIMEHUB_DOMAIN}
  port: ${PRIMEHUB_PORT}
  keycloak:
    scheme: http
    domain: ${KEYCLOAK_DOMAIN}
    username: keycloak
    password: ${KEYCLOAK_PASSWORD}
    port: ${PRIMEHUB_PORT}
keycloak:
  keycloak:
    password: ${KEYCLOAK_PASSWORD}
    extraArgs: -Dkeycloak.ssl-required=none
    ingress:
      enabled: true
      hosts:
      - ${KEYCLOAK_DOMAIN}
bootstrap:
  usernmae: phadmin
  password: ${PRIMEHUB_PASSWORD}
graphql:
  sharedGraphqlSecret: ${GRAPHQL_SECRET_KEY}
groupvolume:
  storageClass: ${STORAGE_CLASS}
ingress:
  annotations:
    kubernetes.io/ingress.allow-http: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
  hosts:
  - ${PRIMEHUB_DOMAIN}
jupyterhub:
  auth:
    state:
      cryptoKey: ${GRAPHQL_SECRET_KEY}
  hub:
    db:
      pvc:
        storageClassName: ${STORAGE_CLASS}
  proxy:
    secretToken: ${HUB_PROXY_SECRET_TOKEN}
  singleuser:
    storage:
      dynamic:
        storageClass: ${STORAGE_CLASS}
EOF

if [[ "${PRIMEHUB_MODE}" == "ee" ]]; then
  cat <<EOF >> primehub-values.yaml

customImage:
  enabled: true

jobSubmission:
  enabled: true

adminNotebook:
  enabled: false
EOF
fi

helm upgrade \
  primehub ../chart \
  --install \
  --create-namespace \
  --namespace hub  \
  --values primehub-values.yaml \
  --values k3d/primehub-override.yaml

# change requests.cpu to 0.1 to make sure shared runner can have enough resource
kubectl -n hub patch instancetype cpu-1 -p '{"spec":{"requests.cpu":0.1}}' --type merge || true
