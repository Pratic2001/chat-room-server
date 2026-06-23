#!/usr/bin/env bash
# scripts/update_mysql_host.sh
# Utility to manually set or update the MySQL container's clusterIP in
# app/.env.runtime. This is useful when deploying to a Kubernetes cluster
# where the internal service DNS / clusterIP may differ from the default.

set -euo pipefail

# Path to the runtime env file (gitignored)
ENV_FILE="app/.env.runtime"

# Verify the env file exists
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Ensure you have run ./scripts/build_images.sh first."
  exit 1
fi

# Prompt the user for the MySQL cluster IP
read -rp "Enter the MySQL container's cluster IP (e.g., 10.0.0.5): " MYSQL_HOST
if [[ -z "$MYSQL_HOST" ]]; then
  echo "Error: The IP address cannot be empty."
  exit 1
fi

# Check if MYSQL_HOST is already defined in the file
if grep -q "^MYSQL_HOST=" "$ENV_FILE"; then
  # Replace the existing line
  echo "Updating existing MYSQL_HOST entry..."
  sed -i "s/^MYSQL_HOST=.*/MYSQL_HOST=$MYSQL_HOST/" "$ENV_FILE"
else
  # Append the variable at the end of the file
  echo "Adding new MYSQL_HOST entry..."
  echo "MYSQL_HOST=$MYSQL_HOST" >> "$ENV_FILE"
fi

# Confirm the change
echo "Successfully updated $ENV_FILE:"
grep "^MYSQL_HOST=" "$ENV_FILE" || echo " (not found after update)"
echo "You can now re-run ./scripts/deploy_k8s.sh to apply the change."