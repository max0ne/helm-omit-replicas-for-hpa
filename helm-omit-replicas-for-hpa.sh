#!/bin/bash
set -euo pipefail

function usage() {
  cat <<-EOF
	Usage: $0 --namespace <namespace> --helm-release <release-name> --deployment <deployment-name>
	EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE=$2
      shift 2
      ;;
    --helm-release)
      RELEASE_NAME=$2
      shift 2
      ;;
    --deployment)
      DEPLOYMENT_NAME=$2
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ -z "$NAMESPACE" ] || [ -z "$RELEASE_NAME" ] || [ -z "$DEPLOYMENT_NAME" ]; then
  usage
  exit 1
fi

echo "Preparing helm history for HPA in namespace: $NAMESPACE, release: $RELEASE_NAME, deployment: $DEPLOYMENT_NAME"

# Fetch the Helm history secret for the given release
SECRET_NAME=$(kubectl get secrets -l "owner=helm,name=$RELEASE_NAME,status=deployed" --no-headers | awk "{print \$1}")

if [ -z "$SECRET_NAME" ]; then
    echo "Helm history secret not found for release: $RELEASE_NAME in namespace: $NAMESPACE"
    exit 1
fi

echo "Found Helm history secret: $SECRET_NAME, removing replicas from its manifest"

# Extract the manifest, decode, and process it
HELM_HISTORY="$(
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.release}" | \
    base64 -d | \
    base64 -d | \
    gzip -d
)"

MANIFEST_OLD="$(<<<"$HELM_HISTORY" jq .manifest -rc | yq e -)"

# Remove the replicas field from the Deployment manifest
MANIFEST_NEW="$(
  echo "$MANIFEST_OLD" | yq e '(select(.kind == "Deployment" and .metadata.name == "'${DEPLOYMENT_NAME}'") | del(.spec.replicas)) // .'
)"

printf "\n\nHelm manifest before patch:\n"
<<<"$MANIFEST_OLD" awk '{print "\t" $0}'

printf "\n\nHelm manifest after patch:\n"
<<<"$MANIFEST_NEW" awk '{print "\t" $0}'

printf "\n\nHelm manifest diff:\n"
DIFF="$(diff <(echo "$MANIFEST_OLD") <(echo "$MANIFEST_NEW") || true)"
if [ -z "$DIFF" ]; then
  echo "No changes detected"
  exit 0
fi

echo "$DIFF" | awk '{print "\t" $0}'
printf "\n\n"

# Let the user confirm the changes, with new line
read -p "Do you want to apply the changes? [y/N] "
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted"
  exit 0
fi

# Commit the updated manifest back to the Helm history secret
<<<"$HELM_HISTORY" jq --arg MANIFEST_NEW "$MANIFEST_NEW" '.manifest = $MANIFEST_NEW' | \
  gzip | \
  base64 | \
  base64 | \
  kubectl patch secret "$SECRET_NAME" -n "$NAMESPACE" -p '{"data":{"release":"'"$(cat)"'"}}'
