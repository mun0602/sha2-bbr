#!/bin/bash
# Script tự động cài đặt Shadowsocks với Cloak plugin và DNS server trên VPS
# Sử dụng: chmod +x shadowsocks_cloak_dns_installer.sh && sudo ./shadowsocks_cloak_dns_installer.sh
# Cập nhật: 2025-05-09 - Thêm chức năng DNS server

# Màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Vui lòng chạy script với quyền sudo!${NC}"
  exit 1
fi

# Lấy thông tin thời gian
CURRENT_DATE=$(date "+%Y-%m-%d")
CURRENT_USER="mun0602"

# Hỏi tên cho cấu hình ngay từ đầu
while true; do
  read -p "Nhập tên cho cấu hình (không được để trống, mặc định: myss): " config_name
  config_name=${config_name:-myss}
  
  # Loại bỏ khoảng trắng và ký tự đặc biệt để tránh lỗi URI
  config_name=$(echo "$config_name" | tr -cd '[:alnum:]-_')
  
  if [ -n "$config_name" ]; then
    break
  else
    echo -e "${RED}Tên cấu hình không được để trống!${NC}"
  fi
done

echo -e "${GREEN}Đã đặt tên cấu hình: ${config_name}${NC}"

# Function để ghi log
log() {
  local type=$1
  local message=$2
  case $type in
    "info") echo -e "${BLUE}[INFO] ${message}${NC}" ;;
    "success") echo -e "${GREEN}[SUCCESS] ${message}${NC}" ;;
    "warning") echo -e "${YELLOW}[WARNING] ${message}${NC}" ;;
    "error") echo -e "${RED}[ERROR] ${message}${NC}" ;;
  esac
}

# Xóa cài đặt cũ nếu có
log "info" "Kiểm tra và xóa cài đặt cũ nếu tồn tại..."
systemctl stop shadowsocks-libev ss-server cloak-server unbound 2>/dev/null
systemctl disable shadowsocks-libev ss-server cloak-server unbound 2>/dev/null
rm -f /etc/systemd/system/ss-server.service /etc/systemd/system/cloak-server.service 2>/dev/null
systemctl daemon-reload

# Cập nhật repository
log "info" "Đang cập nhật danh sách package..."
apt-get update -y

# Cài đặt các gói cần thiết
log "info" "Đang cài đặt các gói cần thiết..."
apt-get install -y curl wget jq qrencode unzip iptables shadowsocks-libev monit lsof git golang unbound bc

# Sử dụng port 443 (HTTPS) để ẩn danh tốt hơn
server_port=443

# Kiểm tra xem port 443 đã được sử dụng chưa
if lsof -i :443 > /dev/null 2>&1; then
    log "warning" "Port 443 đã được sử dụng bởi một dịch vụ khác. Kiểm tra xem có phải là web server không..."
    
    # Kiểm tra nếu là Nginx/Apache đang chạy
    if systemctl is-active --quiet nginx || systemctl is-active --quiet apache2; then
        log "error" "Máy chủ web (Nginx/Apache) đang chạy trên port 443. Vui lòng dừng hoặc cấu hình lại trước khi tiếp tục."
        read -p "Bạn muốn tiếp tục với port ngẫu nhiên khác? (y/n): " choose_random_port
        if [[ "$choose_random_port" == "y" || "$choose_random_port" == "Y" ]]; then
            server_port=$(shuf -i 10000-60000 -n 1)
            log "info" "Đã chọn port ngẫu nhiên: ${server_port}"
        else
            exit 1
        fi
    else
        read -p "Port 443 đã được sử dụng. Bạn muốn dừng dịch vụ đang sử dụng và tiếp tục? (y/n): " stop_service
        if [[ "$stop_service" == "y" || "$stop_service" == "Y" ]]; then
            log "info" "Đang cố gắng giải phóng port 443..."
            fuser -k 443/tcp
            sleep 2
            if lsof -i :443 > /dev/null 2>&1; then
                log "error" "Không thể giải phóng port 443. Sử dụng port ngẫu nhiên..."
                server_port=$(shuf -i 10000-60000 -n 1)
            else
                log "success" "Đã giải phóng port 443 thành công."
            fi
        else
            server_port=$(shuf -i 10000-60000 -n 1)
            log "info" "Đã chọn port ngẫu nhiên: ${server_port}"
        fi
    fi
else
    log "success" "Port 443 khả dụng và sẽ được sử dụng cho Shadowsocks với Cloak."
fi

log "success" "Đã cấu hình port: ${server_port}"

# Chọn port Shadowsocks nội bộ (khác với port công khai)
ss_port=$(shuf -i 10000-60000 -n 1)

# Chọn port DNS (53 là mặc định)
dns_port=53

# Tạo mật khẩu ngẫu nhiên mạnh (16 ký tự với cả chữ, số, ký tự đặc biệt)
password=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+' </dev/urandom | head -c 16)
log "success" "Đã tạo mật khẩu ngẫu nhiên: ${password}"

# Sử dụng phương thức mã hóa mạnh nhất
method="chacha20-ietf-poly1305"

# Lấy địa chỉ IP public - sử dụng nhiều nguồn để đảm bảo
log "info" "Đang lấy địa chỉ IP public..."
server_ip=""
for ip_service in "https://api.ipify.org" "http://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
  if [ -z "$server_ip" ]; then
    server_ip=$(curl -s $ip_service)
    if [[ $server_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      break
    else
      server_ip=""
    fi
  fi
done

if [ -z "$server_ip" ]; then
  log "warning" "Không thể tự động lấy IP. Đang thử phương pháp khác..."
  server_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
fi

if [ -z "$server_ip" ]; then
  read -p "Không thể tự động lấy IP. Vui lòng nhập IP của server: " server_ip
  # Kiểm tra định dạng IP hợp lệ
  if ! [[ $server_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "error" "Địa chỉ IP không hợp lệ!"
    exit 1
  fi
fi

log "success" "Địa chỉ IP của server: ${server_ip}"

# Cài đặt và cấu hình DNS server (Unbound)
log "info" "Đang cài đặt và cấu hình DNS server (Unbound)..."

# Tạo thư mục cấu hình nếu cần
mkdir -p /var/lib/unbound/

# Tải root hints
wget -O /var/lib/unbound/root.hints https://www.internic.net/domain/named.root
chmod 644 /var/lib/unbound/root.hints

# Tạo file cấu hình unbound
cat > /etc/unbound/unbound.conf << EOF
server:
    # Các cấu hình cơ bản
    verbosity: 1
    interface: 0.0.0.0
    port: ${dns_port}
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    
    # Bảo mật
    access-control: 0.0.0.0/0 allow
    root-hints: "/var/lib/unbound/root.hints"
    hide-identity: yes
    hide-version: yes
    
    # Tối ưu hóa
    prefetch: yes
    prefetch-key: yes
    minimal-responses: yes
    serve-expired: yes
    
    # Cache
    cache-min-ttl: 60
    cache-max-ttl: 86400
    rrset-roundrobin: yes
    
    # Giới hạn tài nguyên
    so-rcvbuf: 4m
    msg-cache-size: 64m
    rrset-cache-size: 128m
    
    # Các tùy chọn khác
    do-not-query-localhost: no
    
# Chuyển tiếp đến DNS servers công cộng
forward-zone:
    name: "."
    forward-addr: 1.1.1.1@53       # Cloudflare
    forward-addr: 8.8.8.8@53       # Google
    forward-addr: 9.9.9.9@53       # Quad9
EOF

# Mở port DNS
log "info" "Mở port DNS (53) trên tường lửa..."
# UFW
if command -v ufw &> /dev/null; then
    ufw allow ${dns_port}/tcp
    ufw allow ${dns_port}/udp
    log "success" "Đã mở port ${dns_port} (DNS) trên UFW."
fi

# Iptables
iptables -I INPUT -p tcp --dport ${dns_port} -j ACCEPT
iptables -I INPUT -p udp --dport ${dns_port} -j ACCEPT

# Khởi động Unbound
systemctl restart unbound
systemctl enable unbound

# Kiểm tra Unbound đã hoạt động chưa
sleep 2
if systemctl is-active --quiet unbound; then
    log "success" "DNS server (Unbound) đã được khởi động thành công trên port ${dns_port}."
    
    # Kiểm tra DNS hoạt động
    if dig @127.0.0.1 -p ${dns_port} google.com +short > /dev/null 2>&1; then
        log "success" "DNS server hoạt động tốt và có thể phân giải tên miền."
    else
        log "warning" "DNS server đã khởi động nhưng dường như không thể phân giải tên miền."
    fi
else
    log "error" "DNS server (Unbound) không thể khởi động. Vui lòng kiểm tra logs: journalctl -u unbound"
fi

# Cài đặt Cloak
log "info" "Đang cài đặt Cloak để thay thế plugin obfs..."

# Tạo thư mục để cài đặt Cloak
mkdir -p /opt/cloak
cd /opt/cloak

# Kiểm tra phiên bản Go
go_version=$(go version 2>/dev/null | grep -oP "go\d+\.\d+" | grep -oP "\d+\.\d+")
if [ -z "$go_version" ] || [ "$(echo "$go_version < 1.14" | bc -l)" -eq 1 ]; then
  log "warning" "Phiên bản Go không đủ hoặc không được cài đặt. Đang tải phiên bản mới nhất của Cloak..."
  
  # Tải phiên bản binary mới nhất của Cloak
  latest_release=$(curl -s https://api.github.com/repos/cbeuw/Cloak/releases/latest | grep "tag_name" | cut -d'"' -f4)
  arch=$(uname -m)
  
  if [ "$arch" = "x86_64" ]; then
    download_url="https://github.com/cbeuw/Cloak/releases/download/$latest_release/ck-server-linux-amd64-$latest_release"
    curl -L -o ck-server "$download_url"
  elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
    download_url="https://github.com/cbeuw/Cloak/releases/download/$latest_release/ck-server-linux-arm64-$latest_release"
    curl -L -o ck-server "$download_url"
  else
    log "error" "Không hỗ trợ kiến trúc $arch. Vui lòng cài đặt Cloak thủ công."
    exit 1
  fi
else
  log "info" "Go đã được cài đặt, đang tải và biên dịch Cloak từ nguồn..."
  
  # Clone Cloak repo
  git clone https://github.com/cbeuw/Cloak.git
  cd Cloak
  
  # Build Cloak
  go build -o ck-server ./cmd/ck-server
  cp ck-server ../.
  cd ..
  rm -rf Cloak
fi

chmod +x ck-server
mv ck-server /usr/local/bin/

# Tạo UID và secret keys cho Cloak
log "info" "Đang tạo các khóa cho Cloak..."
# Di chuyển đến thư mục làm việc
cd /opt/cloak

# Tạo khóa công khai và khóa bí mật cho Cloak
ck_private_key=$(openssl ecparam -genkey -name prime256v1 | openssl ec -out /dev/stdout -noout)
ck_public_key=$(echo "$ck_private_key" | openssl ec -pubout -outform PEM | tail -n +2 | head -n -1 | tr -d '\n')

# Tạo UID và mật khẩu cho Cloak client
ck_uid=$(cat /proc/sys/kernel/random/uuid)
ck_client_password=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

# Tạo file cấu hình cho Cloak server
log "info" "Đang cấu hình Cloak..."
cat > /opt/cloak/ck-server.json << EOF
{
  "ProxyBook": {
    "shadowsocks": [
      "tcp",
      "127.0.0.1:${ss_port}"
    ]
  },
  "BindAddr": [
    ":${server_port}"
  ],
  "BypassUID": [],
  "RedirAddr": "bing.cn",
  "PrivateKey": "${ck_private_key//\\/\\\\}",
  "AdminUID": "${ck_uid}",
  "DatabasePath": "/opt/cloak/userinfo.db",
  "StreamTimeout": 300
}
EOF

# Sử dụng ck-server để thêm người dùng
/usr/local/bin/ck-server -c /opt/cloak/ck-server.json -u ${ck_uid} -k ${ck_client_password}

# Tạo file cấu hình Shadowsocks
log "info" "Đang cấu hình Shadowsocks để làm việc với Cloak..."
cat > /etc/shadowsocks-libev/config.json << EOF
{
    "server":"127.0.0.1",
    "server_port":${ss_port},
    "password":"${password}",
    "timeout":300,
    "method":"${method}",
    "fast_open":true,
    "no_delay":true,
    "reuse_port":true,
    "nameserver":"127.0.0.1",
    "mode":"tcp_and_udp"
}
EOF

# Tạo systemd service cho Cloak
log "info" "Đang tạo service cho Cloak..."
cat > /etc/systemd/system/cloak-server.service << EOF
[Unit]
Description=Cloak Server Service
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/ck-server -c /opt/cloak/ck-server.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# Mở port trên tường lửa
log "info" "Đang cấu hình tường lửa..."
# UFW
if command -v ufw &> /dev/null; then
    ufw allow $server_port/tcp
    log "success" "Đã mở port ${server_port} trên UFW."
fi

# Iptables
iptables -I INPUT -p tcp --dport $server_port -j ACCEPT
# Lưu quy tắc iptables để tồn tại sau khi khởi động lại
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules 2>/dev/null
fi
log "success" "Đã mở port ${server_port} trên iptables."

# Khởi động dịch vụ Cloak và Shadowsocks
log "info" "Đang khởi động các dịch vụ..."
systemctl daemon-reload
systemctl start cloak-server
systemctl enable cloak-server
sleep 2

systemctl restart shadowsocks-libev
systemctl enable shadowsocks-libev
sleep 2

# Kiểm tra trạng thái dịch vụ
if systemctl is-active --quiet cloak-server && systemctl is-active --quiet shadowsocks-libev; then
    log "success" "Cả Cloak và Shadowsocks đã được khởi động thành công."
else
    log "error" "Có lỗi khi khởi động dịch vụ. Vui lòng kiểm tra logs để biết thêm chi tiết:"
    echo "journalctl -u cloak-server -n 50"
    echo "journalctl -u shadowsocks-libev -n 50"
fi

log "info" "=== BẮT ĐẦU TỐI ƯU HIỆU SUẤT VÀ CÀI ĐẶT GIÁM SÁT ==="

# 1. Bật BBR congestion control
log "info" "Đang bật BBR congestion control..."

# Kiểm tra phiên bản kernel
kernel_version=$(uname -r | cut -d. -f1)
if [ "$kernel_version" -lt 4 ]; then
  log "warning" "Phiên bản kernel của bạn ($kernel_version) có thể không hỗ trợ BBR. BBR yêu cầu kernel 4.9+"
  
  read -p "Bạn có muốn cập nhật kernel? (y/n, mặc định: n): " update_kernel
  update_kernel=${update_kernel:-n}
  
  if [[ "$update_kernel" == "y" || "$update_kernel" == "Y" ]]; then
    log "info" "Đang cập nhật kernel..."
    apt-get install -y linux-generic-hwe-$(lsb_release -rs)
    log "success" "Kernel đã được cập nhật. Vui lòng khởi động lại hệ thống và chạy lại script này."
    exit 0
  else
    log "warning" "Bỏ qua cập nhật kernel. BBR có thể không hoạt động."
  fi
fi

# Bật BBR
cat >> /etc/sysctl.conf << EOF
# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

# Áp dụng cấu hình sysctl
sysctl -p

# Kiểm tra xem BBR đã được bật chưa
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  log "success" "BBR đã được bật thành công!"
else
  log "error" "Không thể bật BBR. Vui lòng kiểm tra phiên bản kernel của bạn."
fi

# 2. Tối ưu hóa các tham số kernel cho độ trễ thấp và thông lượng cao
log "info" "Đang tối ưu hóa các tham số kernel..."

cat >> /etc/sysctl.conf << EOF
# Tối ưu hóa TCP/IP
fs.file-max = 1000000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

# Áp dụng cấu hình sysctl
sysctl -p

log "success" "Đã tối ưu hóa tham số kernel thành công!"

# 3. Cài đặt và cấu hình giám sát với Monit
log "info" "Đang cấu hình Monit để giám sát các dịch vụ..."

# Tạo file cấu hình Monit cho Shadowsocks và Cloak
cat > /etc/monit/conf.d/shadowsocks << EOF
check process shadowsocks-libev with pidfile /var/run/shadowsocks-libev.pid
  start program = "/usr/bin/systemctl start shadowsocks-libev"
  stop program = "/usr/bin/systemctl stop shadowsocks-libev"
  if failed port ${ss_port} for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF

cat > /etc/monit/conf.d/cloak << EOF
check process cloak-server with pidfile /var/run/cloak-server.pid
  start program = "/usr/bin/systemctl start cloak-server"
  stop program = "/usr/bin/systemctl stop cloak-server"
  if failed port ${server_port} for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF

cat > /etc/monit/conf.d/unbound << EOF
check process unbound with pidfile /var/run/unbound/unbound.pid
  start program = "/usr/bin/systemctl start unbound"
  stop program = "/usr/bin/systemctl stop unbound"
  if failed port ${dns_port} for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF

# Nếu file PID không tồn tại, thử cách khác
if [ ! -f "/var/run/cloak-server.pid" ]; then
  log "warning" "File PID không tồn tại, sử dụng phương pháp thay thế..."
  cat > /etc/monit/conf.d/cloak << EOF
check process cloak-server matching "ck-server"
  start program = "/usr/bin/systemctl start cloak-server"
  stop program = "/usr/bin/systemctl stop cloak-server"
  if failed port ${server_port} for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF
fi

if [ ! -f "/var/run/unbound/unbound.pid" ]; then
  cat > /etc/monit/conf.d/unbound << EOF
check process unbound matching "unbound"
  start program = "/usr/bin/systemctl start unbound"
  stop program = "/usr/bin/systemctl stop unbound"
  if failed port ${dns_port} for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF
fi

# Cho phép truy cập Monit từ localhost
sed -i 's/use address localhost/use address localhost/g' /etc/monit/monitrc
sed -i 's/allow localhost/allow localhost/g' /etc/monit/monitrc

# Khởi động lại Monit
systemctl restart monit
systemctl enable monit

log "success" "Đã cấu hình Monit để giám sát các dịch vụ thành công!"
log "success" "Monit sẽ tự động khởi động lại dịch vụ nếu nó không phản hồi."

# 4. Tạo script để kiểm tra và khởi động lại dịch vụ (hữu ích cho cronjob)
cat > /usr/local/bin/check_services.sh << EOF
#!/bin/bash
# Script kiểm tra và khởi động lại các dịch vụ nếu cần

# Kiểm tra xem dịch vụ có đang chạy không
if ! systemctl is-active --quiet shadowsocks-libev; then
  systemctl restart shadowsocks-libev
  echo "[\$(date)] Đã khởi động lại shadowsocks-libev" >> /var/log/services_monitor.log
fi

if ! systemctl is-active --quiet cloak-server; then
  systemctl restart cloak-server
  echo "[\$(date)] Đã khởi động lại cloak-server" >> /var/log/services_monitor.log
fi

if ! systemctl is-active --quiet unbound; then
  systemctl restart unbound
  echo "[\$(date)] Đã khởi động lại unbound" >> /var/log/services_monitor.log
fi

# Kiểm tra xem port có đang lắng nghe không
if ! ss -tuln | grep -q ":${server_port} "; then
  systemctl restart cloak-server
  echo "[\$(date)] Đã khởi động lại cloak-server vì port ${server_port} không hoạt động" >> /var/log/services_monitor.log
fi

if ! ss -tuln | grep -q ":${dns_port} "; then
  systemctl restart unbound
  echo "[\$(date)] Đã khởi động lại unbound vì port ${dns_port} không hoạt động" >> /var/log/services_monitor.log
fi

# Kiểm tra kết nối internet
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
  echo "[\$(date)] Mất kết nối internet" >> /var/log/services_monitor.log
  # Thử khởi động lại dịch vụ mạng
  systemctl restart networking
  systemctl restart NetworkManager 2>/dev/null
fi
EOF

chmod +x /usr/local/bin/check_services.sh

# Thêm cronjob để chạy script kiểm tra mỗi 5 phút
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/check_services.sh") | crontab -

log "success" "Đã tạo script kiểm tra và cronjob để giám sát các dịch vụ mỗi 5 phút!"

# Tạo cấu hình client cho Cloak
cloak_client_config=$(cat <<EOF
{
  "Transport": "direct",
  "ProxyMethod": "shadowsocks",
  "EncryptionMethod": "plain",
  "UID": "${ck_uid}",
  "PublicKey": "${ck_public_key}",
  "ServerName": "bing.cn",
  "ServerAddress": "${server_ip}:${server_port}",
  "NumConn": 4,
  "BrowserSig": "chrome",
  "StreamTimeout": 300
}
EOF
)

# Base64 encode config Cloak client
cloak_client_config_b64=$(echo "$cloak_client_config" | base64 -w 0)

# In thông tin
log "success" "==================================="
log "success" "Cài đặt, tối ưu và giám sát hoàn tất!"
log "success" "==================================="
echo -e "${YELLOW}Thông tin kết nối Shadowsocks + Cloak:${NC}"
echo -e "Server IP: ${server_ip}"
echo -e "Server Port: ${server_port} ${GREEN}(Port HTTPS chuẩn để ẩn danh tốt hơn)${NC}"
echo -e "Shadowsocks Password: ${password}"
echo -e "Shadowsocks Method: ${method}"
echo -e "Cloak UID: ${ck_uid}"
echo -e "Cloak Password: ${ck_client_password}"
echo -e "Cloak Public Key: ${ck_public_key}"
echo -e "Tên cấu hình: ${config_name}"
log "success" "==================================="
echo -e "${YELLOW}Thông tin DNS server:${NC}"
echo -e "DNS Server IP: ${server_ip}"
echo -e "DNS Server Port: ${dns_port}"
echo -e "Để sử dụng DNS này, hãy cấu hình DNS trong thiết bị của bạn với IP: ${server_ip}"
echo -e "${GREEN}Cách kiểm tra DNS server:${NC} nslookup google.com ${server_ip}"
log "success" "==================================="
echo -e "${YELLOW}HƯỚNG DẪN CẤU HÌNH CLOAK CLIENT:${NC}"
echo -e "1. Cài đặt plugin Cloak (ck-client) trên máy khách"
echo -e "2. Cấu hình Shadowsocks client như sau:"
echo -e "   Server: 127.0.0.1"
echo -e "   Port: 1080 (hoặc port do bạn chọn)"
echo -e "   Password: ${password}"
echo -e "   Method: ${method}"
echo -e "   Plugin: ck-client"
echo -e "   Plugin Config: ${cloak_client_config_b64}"
log "success" "==================================="
echo -e "${YELLOW}HOẶC TẢI FILE CẤU HÌNH CLOAK CLIENT:${NC}"

# Lưu cấu hình Cloak client vào file
cat > /opt/cloak/ck-client.json << EOF
${cloak_client_config}
EOF

echo -e "Cấu hình Cloak client đã được lưu vào file: /opt/cloak/ck-client.json"
log "success" "==================================="

# Lưu thông tin vào file
cat > shadowsocks_cloak_dns_info.txt << EOF
=== THÔNG TIN KẾT NỐI SHADOWSOCKS + CLOAK + DNS (Cập nhật: ${CURRENT_DATE}) ===
Server IP: ${server_ip}
Server Port: ${server_port}
Shadowsocks:
  - Password: ${password}
  - Method: ${method}
  - Local Port: ${ss_port}

Cloak:
  - UID: ${ck_uid}
  - Password: ${ck_client_password}
  - Public Key: ${ck_public_key}
  - Redirect Site: bing.cn

DNS Server:
  - IP: ${server_ip}
  - Port: ${dns_port}
  - Test command: nslookup google.com ${server_ip}

=== THÔNG TIN CẤU HÌNH CLOAK CLIENT ===
{
  "Transport": "direct",
  "ProxyMethod": "shadowsocks",
  "EncryptionMethod": "plain",
  "UID": "${ck_uid}",
  "PublicKey": "${ck_public_key}",
  "ServerName": "bing.cn",
  "ServerAddress": "${server_ip}:${server_port}",
  "NumConn": 4,
  "BrowserSig": "chrome",
  "StreamTimeout": 300
}

Base64 encoded config for plugin parameter: ${cloak_client_config_b64}

=== THÔNG TIN TỐI ƯU HÓA VÀ ẨN DANH ===
Port HTTPS (443): $([ $server_port -eq 443 ] && echo "Sử dụng" || echo "Không (sử dụng port $server_port)")
Cloak Plugin: Đã cài đặt và cấu hình
DNS Server: Đã cài đặt trên ${server_ip}:${dns_port}
BBR: $(sysctl net.ipv4.tcp_congestion_control | grep -q bbr && echo "Bật" || echo "Tắt")
Tối ưu kernel: Đã áp dụng
Giám sát: Monit + Cronjob (5 phút)

Được tạo bởi: ${CURRENT_USER} vào ${CURRENT_DATE}
EOF

log "success" "Thông tin kết nối, tối ưu hóa và ẩn danh đã được lưu vào file shadowsocks_cloak_dns_info.txt"

# Hướng dẫn khắc phục sự cố
echo -e "${YELLOW}"
echo "HƯỚNG DẪN KHẮC PHỤC SỰ CỐ:"
echo "1. Kiểm tra log các dịch vụ:"
echo "   - sudo journalctl -u shadowsocks-libev -f"
echo "   - sudo journalctl -u cloak-server -f"
echo "   - sudo journalctl -u unbound -f"
echo "2. Kiểm tra cổng đã mở:"
echo "   - sudo lsof -i :$server_port (Cloak)"
echo "   - sudo lsof -i :$dns_port (DNS)"
echo "3. Kiểm tra tường lửa:"
echo "   - sudo iptables -L"
echo "4. Khởi động lại dịch vụ:"
echo "   - sudo systemctl restart shadowsocks-libev"
echo "   - sudo systemctl restart cloak-server" 
echo "   - sudo systemctl restart unbound" 
echo "5. Kiểm tra trạng thái Monit: sudo monit status"
echo "6. Xem log giám sát: cat /var/log/services_monitor.log"
echo "7. Kiểm tra DNS server hoạt động: nslookup google.com ${server_ip}"
echo -e "${NC}"

log "success" "Cài đặt hoàn tất! Hệ thống của bạn đã được:"
echo -e "  ${GREEN}- Cài đặt Shadowsocks + Cloak với cấu hình tối ưu${NC}"
echo -e "  ${GREEN}- Cấu hình DNS server sử dụng IP VPS của bạn${NC}"
echo -e "  ${GREEN}- Sử dụng port 443 (HTTPS) để ngụy trang lưu lượng tốt hơn${NC}"
echo -e "  ${GREEN}- Cấu hình với Cloak để ẩn danh vượt trội${NC}"
echo -e "  ${GREEN}- Ngụy trang lưu lượng thành HTTPS đến bing.cn${NC}"
echo -e "  ${GREEN}- Có khả năng chống lại DPI (Deep Packet Inspection)${NC}"
echo -e "  ${GREEN}- Tăng hiệu suất với BBR và các tham số kernel tối ưu${NC}"
echo -e "  ${GREEN}- Được bảo vệ bằng hệ thống giám sát tự động${NC}"
echo -e "  ${GREEN}- Tự động khởi động lại nếu gặp sự cố${NC}"
