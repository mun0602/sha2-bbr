#!/bin/bash
# Script tự động cài đặt Shadowsocks với URI định dạng chính xác và hiệu suất tối ưu
# Sử dụng: chmod +x optimized_ss_installer.sh && sudo ./optimized_ss_installer.sh

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
systemctl stop shadowsocks-libev ss-server 2>/dev/null
systemctl disable shadowsocks-libev ss-server 2>/dev/null
rm -f /etc/systemd/system/ss-server.service 2>/dev/null
systemctl daemon-reload

# Cập nhật repository
log "info" "Đang cập nhật danh sách package..."
apt-get update -y

# Cài đặt các gói cần thiết
log "info" "Đang cài đặt các gói cần thiết..."
apt-get install -y curl wget jq qrencode unzip iptables shadowsocks-libev monit

# Tạo port ngẫu nhiên (10000-60000) - tránh port thông dụng
server_port=$(shuf -i 10000-60000 -n 1)
log "success" "Đã tạo port ngẫu nhiên: ${server_port}"

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

# Hỏi tên cho cấu hình và đảm bảo luôn có giá trị
while true; do
  read -p "Nhập tên cho cấu hình (không được để trống, mặc định: myss): " config_name
  config_name=${config_name:-myss}
  
  # Loại bỏ khoảng trắng và ký tự đặc biệt để tránh lỗi URI
  config_name=$(echo "$config_name" | tr -cd '[:alnum:]-_')
  
  if [ -n "$config_name" ]; then
    break
  else
    log "error" "Tên cấu hình không được để trống!"
  fi
done

log "success" "Tên cấu hình: ${config_name}"

# Cấu hình shadowsocks-libev với các tham số tối ưu
log "info" "Đang cấu hình Shadowsocks..."
cat > /etc/shadowsocks-libev/config.json << EOF
{
    "server":"0.0.0.0",
    "server_port":${server_port},
    "password":"${password}",
    "timeout":300,
    "method":"${method}",
    "fast_open":true,
    "no_delay":true,
    "reuse_port":true,
    "nameserver":"8.8.8.8,1.1.1.1",
    "mode":"tcp_and_udp"
}
EOF

# Mở port trên tường lửa
log "info" "Đang cấu hình tường lửa..."
# UFW
if command -v ufw &> /dev/null; then
    ufw allow $server_port/tcp
    ufw allow $server_port/udp
    log "success" "Đã mở port ${server_port} trên UFW."
fi

# Iptables
iptables -I INPUT -p tcp --dport $server_port -j ACCEPT
iptables -I INPUT -p udp --dport $server_port -j ACCEPT
# Lưu quy tắc iptables để tồn tại sau khi khởi động lại
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules 2>/dev/null
fi
log "success" "Đã mở port ${server_port} trên iptables."

# Khởi động lại dịch vụ shadowsocks-libev
log "info" "Đang khởi động dịch vụ Shadowsocks..."
systemctl restart shadowsocks-libev
systemctl enable shadowsocks-libev
sleep 2

# Kiểm tra trạng thái dịch vụ
if systemctl is-active --quiet shadowsocks-libev; then
    log "success" "Dịch vụ Shadowsocks đã được khởi động thành công."
    service_name="shadowsocks-libev"
else
    log "warning" "Dịch vụ Shadowsocks không khởi động được. Đang thử phương pháp thay thế..."
    
    # Thử cài đặt và cấu hình lại bằng ss-server trực tiếp
    log "info" "Đang cấu hình ss-server trực tiếp..."
    cat > /etc/systemd/system/ss-server.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.json -u
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl start ss-server
    systemctl enable ss-server
    sleep 2
    
    if systemctl is-active --quiet ss-server; then
        log "success" "Dịch vụ ss-server đã được khởi động thành công."
        service_name="ss-server"
    else
        log "error" "Tất cả các phương pháp đều thất bại. Vui lòng kiểm tra logs để biết thêm chi tiết: journalctl -xe"
        exit 1
    fi
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
log "info" "Đang cấu hình Monit để giám sát Shadowsocks..."

# Tạo file cấu hình Monit cho Shadowsocks
cat > /etc/monit/conf.d/shadowsocks << EOF
check process $service_name with pidfile /var/run/$service_name.pid
  start program = "/usr/bin/systemctl start $service_name"
  stop program = "/usr/bin/systemctl stop $service_name"
  if failed port $server_port for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
  if changed pid then alert
EOF

# Nếu file PID không tồn tại, thử cách khác
if [ ! -f "/var/run/$service_name.pid" ]; then
  log "warning" "File PID không tồn tại, sử dụng phương pháp thay thế..."
  cat > /etc/monit/conf.d/shadowsocks << EOF
check process $service_name matching "ss-server|ss-local|ss-redir|ss-tunnel"
  start program = "/usr/bin/systemctl start $service_name"
  stop program = "/usr/bin/systemctl stop $service_name"
  if failed port $server_port for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF
fi

# Cho phép truy cập Monit từ localhost
sed -i 's/use address localhost/use address localhost/g' /etc/monit/monitrc
sed -i 's/allow localhost/allow localhost/g' /etc/monit/monitrc

# Khởi động lại Monit
systemctl restart monit
systemctl enable monit

log "success" "Đã cấu hình Monit để giám sát Shadowsocks thành công!"
log "success" "Monit sẽ tự động khởi động lại dịch vụ nếu nó không phản hồi."

# 4. Tạo script để kiểm tra và khởi động lại dịch vụ (hữu ích cho cronjob)
cat > /usr/local/bin/check_shadowsocks.sh << EOF
#!/bin/bash
# Script kiểm tra và khởi động lại Shadowsocks nếu cần

# Kiểm tra xem dịch vụ có đang chạy không
if ! systemctl is-active --quiet $service_name; then
  systemctl restart $service_name
  echo "[\$(date)] Đã khởi động lại $service_name" >> /var/log/shadowsocks_monitor.log
fi

# Kiểm tra xem port có đang lắng nghe không
if ! ss -tuln | grep -q ":$server_port "; then
  systemctl restart $service_name
  echo "[\$(date)] Đã khởi động lại $service_name vì port $server_port không hoạt động" >> /var/log/shadowsocks_monitor.log
fi

# Kiểm tra kết nối internet
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
  echo "[\$(date)] Mất kết nối internet" >> /var/log/shadowsocks_monitor.log
  # Thử khởi động lại dịch vụ mạng
  systemctl restart networking
  systemctl restart NetworkManager 2>/dev/null
fi
EOF

chmod +x /usr/local/bin/check_shadowsocks.sh

# Thêm cronjob để chạy script kiểm tra mỗi 5 phút
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/check_shadowsocks.sh") | crontab -

log "success" "Đã tạo script kiểm tra và cronjob để giám sát Shadowsocks mỗi 5 phút!"

# Tạo URI đúng định dạng (ĐẢM BẢO CÓ TÊN)
# Chuỗi để mã hóa: method:password
auth_string="${method}:${password}"
# Mã hóa base64 (không xuống dòng)
auth_base64=$(echo -n "${auth_string}" | base64 -w 0)
# Tạo URI Shadowsocks theo đúng định dạng
ss_link="ss://${auth_base64}@${server_ip}:${server_port}"

# ĐẢM BẢO có phần tên trong URI
if [ -n "$config_name" ]; then
  ss_link="${ss_link}#${config_name}"
else
  # Nếu không có tên, tạo tên mặc định từ thông tin server
  config_name="SS-${server_ip}-$(date +%Y%m%d)"
  ss_link="${ss_link}#${config_name}"
fi

# In thông tin
log "success" "==================================="
log "success" "Cài đặt, tối ưu và giám sát hoàn tất!"
log "success" "==================================="
echo -e "${YELLOW}Thông tin kết nối Shadowsocks:${NC}"
echo -e "Server IP: ${server_ip}"
echo -e "Server Port: ${server_port}"
echo -e "Password: ${password}"
echo -e "Method: ${method}"
echo -e "Tên cấu hình: ${config_name}"
log "success" "==================================="
echo -e "${YELLOW}Shadowsocks Link:${NC} ${ss_link}"
log "success" "==================================="
echo -e "${YELLOW}Shadowsocks QR Code:${NC}"
echo -n "${ss_link}" | qrencode -t UTF8
log "success" "==================================="

# Kiểm tra kết nối
log "info" "Đang kiểm tra kết nối..."
if ss -tuln | grep -q ":$server_port "; then
    log "success" "Cổng ${server_port} đang mở và lắng nghe kết nối."
else
    log "error" "Cổng ${server_port} không mở. Vui lòng kiểm tra cấu hình tường lửa."
fi

# Hiển thị trạng thái tối ưu hóa
log "info" "=== Trạng thái tối ưu hóa ==="
log "success" "BBR congestion control: $(sysctl net.ipv4.tcp_congestion_control | grep -q bbr && echo "Bật" || echo "Tắt")"
log "success" "Tối ưu hóa kernel: Đã áp dụng"
log "success" "Giám sát Monit: Đã cấu hình"
log "success" "Cronjob kiểm tra: Mỗi 5 phút"

# Lưu thông tin vào file
cat > shadowsocks_info.txt << EOF
=== THÔNG TIN KẾT NỐI SHADOWSOCKS ===
Server: ${server_ip}
Port: ${server_port}
Password: ${password}
Method: ${method}
Remarks: ${config_name}

Shadowsocks Link: ${ss_link}

=== THÔNG TIN TỐI ƯU HÓA ===
BBR: $(sysctl net.ipv4.tcp_congestion_control | grep -q bbr && echo "Bật" || echo "Tắt")
Tối ưu kernel: Đã áp dụng
Giám sát: Monit + Cronjob (5 phút)
EOF

log "success" "Thông tin kết nối và tối ưu hóa đã được lưu vào file shadowsocks_info.txt"

# Hướng dẫn khắc phục sự cố
echo -e "${YELLOW}"
echo "HƯỚNG DẪN KHẮC PHỤC SỰ CỐ:"
echo "1. Kiểm tra log: sudo journalctl -u $service_name -f"
echo "2. Kiểm tra cổng đã mở: sudo lsof -i :$server_port"
echo "3. Kiểm tra tường lửa: sudo iptables -L | grep $server_port"
echo "4. Khởi động lại dịch vụ: sudo systemctl restart $service_name"
echo "5. Kiểm tra trạng thái Monit: sudo monit status"
echo "6. Xem log giám sát: cat /var/log/shadowsocks_monitor.log"
echo -e "${NC}"

log "success" "Cài đặt hoàn tất! Shadowsocks của bạn đã được:"
echo -e "  ${GREEN}- Cài đặt với cấu hình tối ưu${NC}"
echo -e "  ${GREEN}- Tạo URI đúng định dạng với TÊN đã đảm bảo${NC}"
echo -e "  ${GREEN}- Tăng hiệu suất với BBR và các tham số kernel tối ưu${NC}"
echo -e "  ${GREEN}- Được bảo vệ bằng hệ thống giám sát ba lớp${NC}"
echo -e "  ${GREEN}- Tự động khởi động lại nếu gặp sự cố${NC}"
