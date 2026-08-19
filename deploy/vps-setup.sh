#!/usr/bin/env bash
# =============================================================================
# vps-setup.sh — One-shot setup de OpenWA (fork nilsenm/openwa, rama lesotur)
# Correr como root en el VPS (Ubuntu/Debian). Requisitos previos:
#   - DNS A:  wat.lesotur.com  ->  <IP del VPS>  (161.132.4.182)
#   - Puertos 80/443/2222 abiertos en el firewall del proveedor
# El script instala Docker, nginx, certbot; clona; levanta OpenWA en 2785;
# proxy-pasea wat.lesotur.com -> 127.0.0.1:2785 con TLS (certbot).
# =============================================================================
set -euo pipefail

DOMAIN="wat.lesotur.com"
CERTBOT_EMAIL="admin@lesotur.com"
REPO="https://github.com/nilsenm/openwa.git"
BRANCH="lesotur"
INSTALL_DIR="/opt/openwa"

# API key fuerte (>=32 chars, exigible en produccion). Se imprime al final: GUARDALA.
API_MASTER_KEY="$(openssl rand -hex 24)"
# Clave fuerte para el Postgres integrado (exigible en produccion).
DATABASE_PASSWORD="$(openssl rand -hex 24)"

echo "== 1/8 Actualizando sistema =="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl ca-certificates gnupg lsb-release nginx certbot python3-certbot-nginx ufw

echo "== 2/8 Instalando Docker =="
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

echo "== 3/8 Clonando OpenWA ($BRANCH) =="
rm -rf "$INSTALL_DIR"
git clone --branch "$BRANCH" "$REPO" "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "== 4/8 Creando .env de produccion =="
cp .env.example .env
grep -q '^NODE_ENV=' .env || echo 'NODE_ENV=production' >> .env
sed -i 's/^NODE_ENV=.*/NODE_ENV=production/' .env
# Cierra el puerto 2785 al localhost unicamente (defense-in-depth)
sed -i "s|^        - '2785'|        # - '2785'  # bloqueado: solo 127.0.0.1 via API_PORT|" docker-compose.yml
echo "API_MASTER_KEY=$API_MASTER_KEY" >> .env
echo "ALLOW_DEV_API_KEY=false" >> .env
echo "CORS_ORIGINS=https://$DOMAIN" >> .env
echo "ENGINE_TYPE=baileys" >> .env
echo "DATABASE_TYPE=postgres" >> .env
echo "POSTGRES_BUILTIN=true" >> .env
echo "DATABASE_NAME=openwa" >> .env
echo "DATABASE_USERNAME=openwa" >> .env
echo "DATABASE_PASSWORD=$DATABASE_PASSWORD" >> .env
echo "DATABASE_SYNCHRONIZE=false" >> .env
echo "TRUSTED_PROXIES=127.0.0.1" >> .env

# --- Rate limiting anti-ban (OTP) ---
echo "SEND_PACING_ENABLED=true" >> .env
echo "SEND_PACING_WARMUP_SCHEDULE=20,40,80,160,320,640,1000" >> .env
echo "SEND_PACING_COLD_DAILY_CAP=5,10,20,40,60,80,100" >> .env
echo "SEND_PACING_BREAKER_THRESHOLD=5" >> .env
echo "SEND_PACING_BREAKER_COOLDOWN_MS=900000" >> .env
echo "BAILEYS_MARK_ONLINE_ON_CONNECT=false" >> .env

echo "== 5/8 Levantando OpenWA (con Postgres integrado) =="
docker compose --profile postgres up -d
sleep 5
docker compose ps

echo "== 6/8 nginx + proxy inverso =="
cat > "/etc/nginx/sites-available/$DOMAIN" <<NGINX
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:2785;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }
}
NGINX
ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t && systemctl reload nginx

echo "== 7/8 Certbot (Let's Encrypt) =="
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect

echo "== 8/8 Firewall =="
ufw allow 2222/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo ""
echo "====================== LISTO ======================"
echo "Dashboard : https://$DOMAIN"
echo "API       : https://$DOMAIN/api   (Swagger en /api/docs)"
echo "X-API-Key : $API_MASTER_KEY"
echo "GUARDA EL API_MASTER_KEY EN UN SECRETO SEGURO."
echo "Luego en el dashboard crea la sesion de WhatsApp y escanea el QR."
echo "Backend LESOTUR: setea WHATSAPP_SERVICE_URL=https://$DOMAIN/api y OPENWA_API_KEY=<arriba>"
echo "==================================================="
