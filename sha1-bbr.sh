#!/bin/bash
# Script tự động cài đặt Shadowsocks với URI định dạng chính xác
# Sử dụng: chmod +x correct_ss_format.sh && sudo ./correct_ss_format.sh

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

# Xóa cài đặt cũ nếu có
echo -e "${YELLOW}Kiểm tra và xóa cài đặt cũ nếu tồn tại...${NC}"
systemctl stop shadowsocks-libev ss-server 2>/dev/null
systemctl disable shadowsocks-libev ss-server 2>/dev/null
rm -f /etc/systemd/system/ss-server.service 2>/dev/null
systemctl daemon-reload

# Cập nhật repository
echo -e "${BLUE}Đang cập nhật danh sách package...${NC}"
apt-get update -y

# Cài đặt các gói cần thiết
echo -e "${BLUE}Đang cài đặt các gói cần thiết...${NC}"
apt-get install -y curl wget jq qrencode unzip iptables shadowsocks-libev monit

# Tạo port ngẫu nhiên (1024-65535)
server_port=$(shuf -i 10000-60000 -n 1)
echo -e "${GREEN}Đã tạo port ngẫu nhiên: ${server_port}${NC}"

# Tạo mật khẩu ngẫu nhiên
password=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
echo -e "${GREEN}Đã tạo mật khẩu ngẫu nhiên: ${password}${NC}"

# Sử dụng phương thức mã hóa
method="chacha20-ietf-poly1305"

# Lấy địa chỉ IP public
echo -e "${BLUE}Đang lấy địa chỉ IP public...${NC}"
server_ip=$(curl -s https://api.ipify.org)
if [ -z "$server_ip" ]; then
  server_ip=$(curl -s http://ifconfig.me)
fi

if [ -z "$server_ip" ]; then
  echo -e "${YELLOW}Không thể tự động lấy IP. Đang thử phương pháp khác...${NC}"
  server_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
fi

if [ -z "$server_ip" ]; then
  read -p "Không thể tự động lấy IP. Vui lòng nhập IP của server: " server_ip
fi

echo -e "${GREEN}Địa chỉ IP của server: ${server_ip}${NC}"

# Hỏi tên cho cấu hình
read -p "Nhập tên cho cấu hình (mặc định: myss): " config_name
config_name=${config_name:-myss}

# Cấu hình shadowsocks-libev
echo -e "${BLUE}Đang cấu hình Shadowsocks...${NC}"
cat > /etc/shadowsocks-libev/config.json << EOF
{
    "server":"0.0.0.0",
    "server_port":${server_port},
    "password":"${password}",
    "timeout":300,
    "method":"${method}",
    "fast_open":true,
    "nameserver":"8.8.8.8",
    "mode":"tcp_and_udp"
}
EOF

# Mở port trên tường lửa
echo -e "${BLUE}Đang cấu hình tường lửa...${NC}"
# UFW
if command -v ufw &> /dev/null; then
    ufw allow $server_port/tcp
    ufw allow $server_port/udp
    echo -e "${GREEN}Đã mở port ${server_port} trên UFW.${NC}"
fi

# Iptables
iptables -I INPUT -p tcp --dport $server_port -j ACCEPT
iptables -I INPUT -p udp --dport $server_port -j ACCEPT
echo -e "${GREEN}Đã mở port ${server_port} trên iptables.${NC}"

# Khởi động lại dịch vụ shadowsocks-libev
echo -e "${BLUE}Đang khởi động dịch vụ Shadowsocks...${NC}"
systemctl restart shadowsocks-libev
systemctl enable shadowsocks-libev
sleep 2

# Kiểm tra trạng thái dịch vụ
if systemctl is-active --quiet shadowsocks-libev; then
    echo -e "${GREEN}Dịch vụ Shadowsocks đã được khởi động thành công.${NC}"
    service_name="shadowsocks-libev"
else
    echo -e "${RED}Dịch vụ Shadowsocks không khởi động được. Đang thử phương pháp thay thế...${NC}"
    
    # Thử cài đặt và cấu hình lại bằng ss-server trực tiếp
    echo -e "${BLUE}Đang cấu hình ss-server trực tiếp...${NC}"
    cat > /etc/systemd/system/ss-server.service << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.json -u
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl start ss-server
    systemctl enable ss-server
    sleep 2
    
    if systemctl is-active --quiet ss-server; then
        echo -e "${GREEN}Dịch vụ ss-server đã được khởi động thành công.${NC}"
        service_name="ss-server"
    else
        echo -e "${RED}Tất cả các phương pháp đều thất bại. Vui lòng kiểm tra logs để biết thêm chi tiết.${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}=== BẮT ĐẦU TỐI ƯU HIỆU SUẤT VÀ CÀI ĐẶT GIÁM SÁT ===${NC}"

# 1. Bật BBR congestion control
echo -e "${BLUE}Đang bật BBR congestion control...${NC}"

# Kiểm tra phiên bản kernel
kernel_version=$(uname -r | cut -d. -f1)
if [ "$kernel_version" -lt 4 ]; then
  echo -e "${YELLOW}Phiên bản kernel của bạn ($kernel_version) có thể không hỗ trợ BBR. BBR yêu cầu kernel 4.9+${NC}"
  
  read -p "Bạn có muốn cập nhật kernel? (y/n, mặc định: n): " update_kernel
  update_kernel=${update_kernel:-n}
  
  if [[ "$update_kernel" == "y" || "$update_kernel" == "Y" ]]; then
    echo -e "${BLUE}Đang cập nhật kernel...${NC}"
    apt-get install -y linux-generic-hwe-$(lsb_release -rs)
    echo -e "${GREEN}Kernel đã được cập nhật. Vui lòng khởi động lại hệ thống và chạy lại script này.${NC}"
    exit 0
  else
    echo -e "${YELLOW}Bỏ qua cập nhật kernel. BBR có thể không hoạt động.${NC}"
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
  echo -e "${GREEN}BBR đã được bật thành công!${NC}"
else
  echo -e "${RED}Không thể bật BBR. Vui lòng kiểm tra phiên bản kernel của bạn.${NC}"
fi

# 2. Tối ưu hóa các tham số kernel cho độ trễ thấp và thông lượng cao
echo -e "${BLUE}Đang tối ưu hóa các tham số kernel...${NC}"

cat >> /etc/sysctl.conf << EOF
# Tối ưu hóa TCP/IP
fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
EOF

# Áp dụng cấu hình sysctl
sysctl -p

echo -e "${GREEN}Đã tối ưu hóa tham số kernel thành công!${NC}"

# 3. Cài đặt và cấu hình giám sát với Monit
echo -e "${BLUE}Đang cấu hình Monit để giám sát Shadowsocks...${NC}"

# Tạo file cấu hình Monit cho Shadowsocks
cat > /etc/monit/conf.d/shadowsocks << EOF
check process $service_name with pidfile /var/run/$service_name.pid
  start program = "/usr/bin/systemctl start $service_name"
  stop program = "/usr/bin/systemctl stop $service_name"
  if failed port $server_port for 3 cycles then restart
  if 5 restarts within 5 cycles then timeout
EOF

# Nếu file PID không tồn tại, thử cách khác
if [ ! -f "/var/run/$service_name.pid" ]; then
  echo -e "${YELLOW}File PID không tồn tại, sử dụng phương pháp thay thế...${NC}"
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

echo -e "${GREEN}Đã cấu hình Monit để giám sát Shadowsocks thành công!${NC}"
echo -e "${GREEN}Monit sẽ tự động khởi động lại dịch vụ nếu nó không phản hồi.${NC}"

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
EOF

chmod +x /usr/local/bin/check_shadowsocks.sh

# Thêm cronjob để chạy script kiểm tra mỗi 5 phút
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/check_shadowsocks.sh") | crontab -

echo -e "${GREEN}Đã tạo script kiểm tra và cronjob để giám sát Shadowsocks mỗi 5 phút!${NC}"

# Tạo URI đúng định dạng
# Chuỗi để mã hóa: method:password
auth_string="${method}:${password}"
# Mã hóa base64 (không xuống dòng)
auth_base64=$(echo -n "${auth_string}" | base64 -w 0)
# Tạo URI Shadowsocks theo đúng định dạng
ss_link="ss://${auth_base64}@${server_ip}:${server_port}#${config_name}"

# In thông tin
echo -e "${GREEN}===================================${NC}"
echo -e "${GREEN}Cài đặt, tối ưu và giám sát hoàn tất!${NC}"
echo -e "${GREEN}===================================${NC}"
echo -e "${YELLOW}Thông tin kết nối Shadowsocks:${NC}"
echo -e "Server IP: ${server_ip}"
echo -e "Server Port: ${server_port}"
echo -e "Password: ${password}"
echo -e "Method: ${method}"
echo -e "${GREEN}===================================${NC}"
echo -e "${YELLOW}Shadowsocks Link:${NC} ${ss_link}"
echo -e "${GREEN}===================================${NC}"
echo -e "${YELLOW}Shadowsocks QR Code:${NC}"
echo -n "${ss_link}" | qrencode -t UTF8
echo -e "${GREEN}===================================${NC}"

# Kiểm tra kết nối
echo -e "${BLUE}Đang kiểm tra kết nối...${NC}"
if ss -tuln | grep -q ":$server_port "; then
    echo -e "${GREEN}Cổng ${server_port} đang mở và lắng nghe kết nối.${NC}"
else
    echo -e "${RED}Cổng ${server_port} không mở. Vui lòng kiểm tra cấu hình tường lửa.${NC}"
fi

# Hiển thị trạng thái tối ưu hóa
echo -e "${BLUE}=== Trạng thái tối ưu hóa ===${NC}"
echo -e "${GREEN}BBR congestion control: $(sysctl net.ipv4.tcp_congestion_control | grep -q bbr && echo "Bật" || echo "Tắt")${NC}"
echo -e "${GREEN}Tối ưu hóa kernel: Đã áp dụng${NC}"
echo -e "${GREEN}Giám sát Monit: Đã cấu hình${NC}"
echo -e "${GREEN}Cronjob kiểm tra: Mỗi 5 phút${NC}"

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

echo -e "${GREEN}Thông tin kết nối và tối ưu hóa đã được lưu vào file shadowsocks_info.txt${NC}"

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

echo -e "${GREEN}Cài đặt hoàn tất! Shadowsocks của bạn đã được:${NC}"
echo -e "  ${GREEN}- Cài đặt với cấu hình tối ưu${NC}"
echo -e "  ${GREEN}- Tạo URI đúng định dạng ss://<base64>@<ip>:<port>#<name>${NC}"
echo -e "  ${GREEN}- Tăng hiệu suất với BBR${NC}"
echo -e "  ${GREEN}- Được bảo vệ bằng hệ thống giám sát hai lớp${NC}"
echo -e "  ${GREEN}- Tự động khởi động lại nếu gặp sự cố${NC}"
