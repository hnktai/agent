#!/usr/bin/env bash
# ==============================================================================
# Setup Script for GoClaw on VPS with Domain agent.hnkt.vn
# Repository: https://github.com/hnktai/agent
# ==============================================================================

set -euo pipefail

DOMAIN="agent.hnkt.vn"
APP_DIR="/opt/goclaw"
REPO_URL="https://github.com/hnktai/agent.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}   Bắt đầu Cài đặt & Triển khai GoClaw trên VPS       ${NC}"
echo -e "${GREEN}   Domain: ${DOMAIN}                                  ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[LỖI] Vui lòng chạy script này với quyền root: sudo bash setup-vps.sh${NC}"
  exit 1
fi

# 2. Cập nhật hệ thống và cài đặt các công cụ cơ bản
echo -e "\n${YELLOW}>>> [1/7] Cập nhật hệ thống & cài đặt công cụ cơ bản...${NC}"
apt-get update -qq
apt-get install -y -qq curl wget git ufw software-properties-common ca-certificates gnupg lsb-release

# 3. Cài đặt Docker & Docker Compose
echo -e "\n${YELLOW}>>> [2/7] Cài đặt Docker & Docker Compose...${NC}"
if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}[OK] Docker đã được cài đặt thành công.${NC}"
else
    echo -e "${GREEN}[OK] Docker đã tồn tại trên hệ thống.${NC}"
fi

# 4. Cài đặt Nginx & Certbot
echo -e "\n${YELLOW}>>> [3/7] Cài đặt Nginx & Certbot (SSL Let's Encrypt)...${NC}"
apt-get install -y -qq nginx certbot python3-certbot-nginx
systemctl enable nginx
systemctl start nginx

# Mở Firewall UFW nếu đang bật
if ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}Cấu hình UFW firewall...${NC}"
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
fi

# 5. Clone hoặc cập nhật mã nguồn GoClaw từ repo hnktai/agent
echo -e "\n${YELLOW}>>> [4/7] Chuẩn bị mã nguồn tại ${APP_DIR}...${NC}"
if [ -d "${APP_DIR}/.git" ]; then
    echo "Thư mục ${APP_DIR} đã tồn tại, đang cập nhật mã nguồn mới nhất..."
    cd "${APP_DIR}"
    git pull origin main || true
else
    echo "Đang clone repository ${REPO_URL} vào ${APP_DIR}..."
    git clone "${REPO_URL}" "${APP_DIR}"
    cd "${APP_DIR}"
fi

# 6. Khởi tạo cấu hình biến môi trường .env
echo -e "\n${YELLOW}>>> [5/7] Khởi tạo tệp cấu hình bảo mật .env...${NC}"
chmod +x prepare-env.sh
./prepare-env.sh

# Đảm bảo có mật khẩu PostgreSQL an toàn
if ! grep -q "^POSTGRES_PASSWORD=" .env || grep -q "^POSTGRES_PASSWORD=$" .env; then
    GEN_PG_PASS=$(openssl rand -hex 16)
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${GEN_PG_PASS}|" .env
    echo -e "${GREEN}[OK] Đã tạo ngẫu nhiên mật khẩu PostgreSQL an toàn.${NC}"
fi

# Đọc token quản trị để thông báo cho người dùng
GATEWAY_TOKEN=$(grep -E "^GOCLAW_GATEWAY_TOKEN=" .env | cut -d'=' -f2-)

# 7. Cấu hình Nginx & Cấp chứng chỉ SSL
echo -e "\n${YELLOW}>>> [6/7] Cấu hình Nginx Reverse Proxy và SSL...${NC}"

# Tạo thư mục webroot certbot
mkdir -p /var/www/certbot

# Kiểm tra xem chứng chỉ SSL đã có chưa
if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    echo "Chưa có chứng chỉ SSL cho ${DOMAIN}. Tiến hành cấu hình tạm thời cổng 80 để xin chứng chỉ..."
    
    cat > "/etc/nginx/sites-available/${DOMAIN}" << 'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name agent.hnkt.vn;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:18790;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl reload nginx

    echo "Đang yêu cầu chứng chỉ SSL từ Let's Encrypt cho domain ${DOMAIN}..."
    certbot certonly --webroot -w /var/www/certbot -d "${DOMAIN}" --non-interactive --agree-tos --register-unsafely-without-email || {
        echo -e "${RED}[CẢNH BÁO] Không thể cấp chứng chỉ SSL tự động.${NC}"
        echo -e "${YELLOW}Vui lòng đảm bảo bản ghi DNS của domain ${DOMAIN} đã trỏ chính xác về IP VPS này.${NC}"
    }
fi

# Áp dụng cấu hình Nginx đầy đủ (SSL + WebSocket + API)
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    cp "${APP_DIR}/deploy/nginx/agent.hnkt.vn.conf" "/etc/nginx/sites-available/${DOMAIN}"
    ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl reload nginx
    echo -e "${GREEN}[OK] Cấu hình Nginx SSL hoàn tất.${NC}"
fi

# 8. Khởi chạy GoClaw & PostgreSQL bằng Docker Compose
echo -e "\n${YELLOW}>>> [7/7] Khởi chạy các container GoClaw & PostgreSQL...${NC}"
cd "${APP_DIR}"

# Tải image và khởi chạy nền
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d --pull always

# Chạy database migrations
echo "Đang áp dụng migrations cơ sở dữ liệu PostgreSQL..."
docker compose -f docker-compose.yml -f docker-compose.postgres.yml -f docker-compose.upgrade.yml run --rm upgrade || true

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${GREEN}     CÀI ĐẶT THÀNH CÔNG GOCLAW TRÊN VPS!              ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo -e "Trang quản trị GoClaw: ${GREEN}https://${DOMAIN}${NC}"
echo -e "Thông tin đăng nhập ban đầu:"
echo -e "  - Phương thức xác thực: ${YELLOW}Token${NC}"
echo -e "  - User ID:              ${YELLOW}system${NC}"
echo -e "  - Gateway Token:        ${GREEN}${GATEWAY_TOKEN}${NC}"
echo -e "------------------------------------------------------"
echo -e "File cấu hình lưu tại:    ${APP_DIR}/.env"
echo -e "Lệnh xem logs container:  cd ${APP_DIR} && docker compose logs -f goclaw"
echo -e "${BLUE}======================================================${NC}"
