#!/bin/bash

set -e

### CONFIG ###########################################################

APP_DIR="/opt/voicer-platform"
ENV_PATH="/home/ubuntu/miniconda3/envs/voicer-env"
PYTHON_PATH="$ENV_PATH/bin/python"
PIP_PATH="$ENV_PATH/bin/pip"

# All services in the platform (canonical list)
ALL_SERVICES=(
    "voicer-main"
    "voicer-ar"
    "voicer-stats"
    "voicer-anno"
    "voicer-prev"
)

# File to remember last deployed commit
LAST_DEPLOY_FILE="$APP_DIR/.last_deploy_commit"

######################################################################

echo "🚀 Starting Voicer platform deployment..."
cd "$APP_DIR"

### 0. Decide which services to deploy ################################

if [ "$#" -gt 0 ]; then
    # User passed service names as arguments
    SERVICES=("$@")
    echo "🧩 Selected services to deploy (from arguments): ${SERVICES[*]}"
else
    # No args → deploy all services
    SERVICES=("${ALL_SERVICES[@]}")
    echo "🧩 No services specified, deploying ALL: ${SERVICES[*]}"
fi

echo

### 1. Detect previous commit #########################################

if git rev-parse HEAD >/dev/null 2>&1; then
    PREV_COMMIT="$(git rev-parse HEAD)"
else
    PREV_COMMIT=""
fi

echo "🔎 Previous commit: ${PREV_COMMIT:-<none>}"

### 2. Pull latest code from origin/main ##############################

echo "📥 Pulling latest code from GitHub (reset to origin/main)..."
git fetch --all
git reset --hard origin/main

CURRENT_COMMIT="$(git rev-parse HEAD)"
echo "🧾 Current commit:  $CURRENT_COMMIT"

# If nothing changed, bail out early
if [ -n "$PREV_COMMIT" ] && [ "$PREV_COMMIT" = "$CURRENT_COMMIT" ]; then
    echo "✅ No new commits on origin/main. Skipping dependency install and service restarts."
    echo "$CURRENT_COMMIT" > "$LAST_DEPLOY_FILE"
    exit 0
fi

### 2.5 Show changed files ###########################################

if [ -n "$PREV_COMMIT" ]; then
    echo "📂 Files changed since last deploy:"
    CHANGED_FILES=$(git diff --name-only "$PREV_COMMIT" "$CURRENT_COMMIT" || true)
    echo "$CHANGED_FILES"
else
    echo "📂 Initial deploy or no previous commit recorded. Treating as fresh deployment."
    CHANGED_FILES=$(git ls-files)
    echo "$CHANGED_FILES"
fi
echo

### 3. Install dependencies (only if requirements.txt changed) ########

if echo "$CHANGED_FILES" | grep -q '^requirements.txt$'; then
    echo "📦 requirements.txt changed → updating Python dependencies in conda env..."
    "$PIP_PATH" install -r requirements.txt --upgrade
else
    echo "📦 requirements.txt unchanged → skipping pip install."
fi

### 4. Reload systemd units ###########################################

echo "🔁 Reloading systemd units (daemon-reload)..."
sudo systemctl daemon-reload

### 5. Restart only the selected services #############################

echo "🔄 Restarting selected services: ${SERVICES[*]}"

for svc in "${SERVICES[@]}"; do
    # Optional: sanity check it's in the known list
    if [[ ! " ${ALL_SERVICES[*]} " =~ " ${svc} " ]]; then
        echo "   ⚠️  Warning: $svc is not in ALL_SERVICES list. Trying to restart anyway..."
    fi

    echo "   ↻ Restarting $svc..."
    sudo systemctl restart "$svc" || {
        echo "   ❌ Failed to restart $svc"
        sudo systemctl status "$svc" --no-pager || true
        exit 1
    }
    sleep 1
done

### 6. Verify selected services #######################################

echo "🩺 Checking service statuses..."
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        echo "   ✅ $svc is running"
    else
        echo "   ❌ $svc FAILED to start!"
        sudo systemctl status "$svc" --no-pager
        exit 1
    fi
done

### 7. Log deployment & remember commit ###############################

echo "📘 Logging deployment timestamp..."
mkdir -p /home/ubuntu/.voicer
echo "$(date): Deployment completed successfully (commit $CURRENT_COMMIT) [services: ${SERVICES[*]}]" >> /home/ubuntu/.voicer/deploy.log

echo "$CURRENT_COMMIT" > "$LAST_DEPLOY_FILE"

echo "🎉 Deployment finished successfully!"
