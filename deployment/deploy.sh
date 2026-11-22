#!/usr/bin/env bash
# ==============================================================================
# Script: deploy.sh (nextops-dashboard)
# Deploys built frontend SPA to Azure VM Nginx
# ==============================================================================
set -euo pipefail

ENVIRONMENT="${1:-Preprod}"

if [ "$ENVIRONMENT" = "Production" ]; then
    RESOURCE_GROUP="${RESOURCE_GROUP:-prod_rg}"
    VM_NAME="${VM_NAME:-axionbackendvm-prod}"
else
    RESOURCE_GROUP="${RESOURCE_GROUP:-dev_rg}"
    VM_NAME="${VM_NAME:-axionbackendvm}"
fi

echo "======================================================================"
echo "🌐 [nextops-dashboard] Deploying Dashboard to VM: $VM_NAME ($ENVIRONMENT)"
echo "======================================================================"

if [ ! -d "dist" ]; then
    echo "❌ Error: 'dist' folder not found. Please run 'npm run build' first."
    exit 1
fi

echo "📦 Packaging built dashboard assets..."
tar -czf dist.tar.gz -C dist .
DIST_B64=$(cat dist.tar.gz | base64 -w 0)
NGINX_CONF_B64=$(cat nginx.conf | base64 -w 0)

REMOTE_SCRIPT=$(cat << EOF
#!/bin/bash
set -euo pipefail

echo "==> Configuring Frontend on VM..."
mkdir -p /var/www/nextops-dashboard /opt/nextops/backups

# Install Nginx if missing
if ! command -v nginx &>/dev/null; then
    apt-get update -y && apt-get install -y nginx curl
fi

# Backup previous frontend release
if [ -d "/var/www/nextops-dashboard" ] && [ "\$(ls -A /var/www/nextops-dashboard)" ]; then
    tar -czf /opt/nextops/backups/dashboard-backup.tar.gz -C /var/www/nextops-dashboard . 2>/dev/null || true
fi

# Unpack new assets
rm -rf /var/www/nextops-dashboard/*
echo "$DIST_B64" | base64 -d | tar -xz -C /var/www/nextops-dashboard/

# Configure Nginx
echo "$NGINX_CONF_B64" | base64 -d > /etc/nginx/sites-available/nextops.conf
sed -i 's|root /usr/share/nginx/html;|root /var/www/nextops-dashboard;|g' /etc/nginx/sites-available/nextops.conf

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/nextops.conf /etc/nginx/sites-enabled/nextops.conf

# Test and restart Nginx
nginx -t
systemctl enable nginx
systemctl restart nginx

# Verify health
sleep 3
if curl -s -f http://127.0.0.1/health >/dev/null || curl -s -f http://127.0.0.1/ >/dev/null; then
    echo "✓ NextOps Dashboard is healthy and responding on port 80!"
    exit 0
else
    echo "❌ Frontend health check failed on local port 80!"
    systemctl status nginx --no-pager
    exit 1
fi
EOF
)

echo "📡 Invoking frontend deployment on $VM_NAME via Azure VM Run Command..."
az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "$REMOTE_SCRIPT" \
    --output json

rm -f dist.tar.gz
echo "✅ [nextops-dashboard] Deployment succeeded on $VM_NAME!"
