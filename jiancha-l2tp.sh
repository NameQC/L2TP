#!/bin/bash
# install.sh (CentOS L2TP) 无法连接时，在服务器上 root 运行此脚本进行诊断与修复

echo "=============================================="
echo "  L2TP 连接诊断（install.sh 版）"
echo "=============================================="

# 检测是否 root
[ "$(id -u)" -ne 0 ] && echo "请用 root 执行此脚本" && exit 1

# 1) 当前公网 IP
echo ""
echo "【1】本机公网 IP"
PUBLIC_IP=$(curl -s --connect-timeout 3 ipv4.icanhazip.com 2>/dev/null || curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || curl -s --connect-timeout 3 ip.sb 2>/dev/null)
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -vE '^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\.' | head -1)
fi
echo "  当前公网/出口 IP: ${PUBLIC_IP:-无法获取}"

# 2) leftid 是否正确（常见连不上原因）
echo ""
echo "【2】ipsec.conf 中 leftid（必须等于服务器公网 IP）"
if [ -f /etc/ipsec.conf ]; then
  CURRENT_LEFTID=$(grep -E '^\s*leftid=' /etc/ipsec.conf | sed 's/.*leftid=\s*//;s/\s*$//')
  echo "  当前 leftid: $CURRENT_LEFTID"
  if [ -n "$PUBLIC_IP" ]; then
    if [ "$CURRENT_LEFTID" != "$PUBLIC_IP" ]; then
      echo "  >>> 与公网 IP 不一致，会导致连接失败，正在自动修正..."
      sed -i "s/^[[:space:]]*leftid=.*/    leftid=${PUBLIC_IP}/" /etc/ipsec.conf
      echo "  已改为: $PUBLIC_IP"
    else
      echo "  >>> 正确"
    fi
  fi
else
  echo "  未找到 /etc/ipsec.conf"
fi

# 3) 服务状态（兼容 CentOS 6 service 与 CentOS 7+ systemctl）
echo ""
echo "【3】服务状态"
for svc in ipsec xl2tpd; do
  if systemctl status "$svc" &>/dev/null; then
    systemctl is-active --quiet "$svc" && echo "  $svc: 运行中" || echo "  $svc: 未运行"
  else
    service "$svc" status &>/dev/null && echo "  $svc: 运行中" || echo "  $svc: 未运行或未安装"
  fi
done

# 4) 端口是否在监听
echo ""
echo "【4】UDP 500 / 4500 / 1701 是否在监听（必须全是 LISTEN）"
if command -v ss &>/dev/null; then
  ss -ulnp 2>/dev/null | grep -E ':500\s|:4500\s|:1701\s' || echo "  未检测到监听，请检查 ipsec 与 xl2tpd 是否启动"
else
  netstat -ulnp 2>/dev/null | grep -E ':500\s|:4500\s|:1701\s' || echo "  未检测到监听"
fi

# 5) 防火墙（firewalld 或 iptables）
echo ""
echo "【5】防火墙"
if systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "  firewalld 运行中，已放行端口："
  firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -E '500|4500|1701' | sed 's/^/    /'
  firewall-cmd --list-ports 2>/dev/null | grep -qE '500|4500|1701' || echo "    >>> 未看到 500/4500/1701，需执行："
  firewall-cmd --list-ports 2>/dev/null | grep -qE '500|4500|1701' || echo "    firewall-cmd --permanent --add-port=500/udp --add-port=4500/udp --add-port=1701/udp && firewall-cmd --reload"
else
  echo "  firewalld 未运行，检查 iptables INPUT UDP："
  iptables -L INPUT -n -v 2>/dev/null | grep -E 'udp.*50[00]|udp.*4500|udp.*1701' | head -5 || echo "    未找到放行规则，需放行 UDP 500,4500,1701"
fi

# 6) ip_forward
echo ""
echo "【6】IP 转发"
echo "  net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ] && echo "  >>> 应为 1，请在 /etc/sysctl.conf 设置 net.ipv4.ip_forward=1 后执行 sysctl -p"

# 7) ipsec verify
echo ""
echo "【7】ipsec verify"
if command -v ipsec &>/dev/null; then
  ipsec verify 2>&1 | sed 's/^/  /'
else
  echo "  未找到 ipsec 命令（可能装在 /usr/local/sbin/ipsec）"
  /usr/local/sbin/ipsec verify 2>&1 | sed 's/^/  /'
fi

# 8) 客户端连接信息
echo ""
echo "【8】客户端应填写的连接信息"
echo "  服务器地址: ${PUBLIC_IP:-你的服务器公网IP}"
[ -f /etc/ipsec.secrets ] && echo "  PSK: $(grep -oP 'PSK\s*"\K[^"]+' /etc/ipsec.secrets 2>/dev/null | head -1)"
[ -f /etc/ppp/chap-secrets ] && echo "  用户名/密码: $(grep -v '^#' /etc/ppp/chap-secrets | awk '{print $1"/"$3}' | head -1)"

# 9) 云安全组提醒
echo ""
echo "【9】若在云服务器（阿里云/腾讯云/AWS 等）"
echo "  请在控制台「安全组」放行入方向：UDP 500、UDP 4500、UDP 1701"

# 10) 若修改了 leftid，建议重启服务
if [ -f /etc/ipsec.conf ] && [ -n "$PUBLIC_IP" ] && [ "$CURRENT_LEFTID" != "$PUBLIC_IP" ]; then
  echo ""
  echo "【10】已修正 leftid，正在重启 ipsec 与 xl2tpd..."
  (systemctl restart ipsec 2>/dev/null || service ipsec restart 2>/dev/null)
  (systemctl restart xl2tpd 2>/dev/null || service xl2tpd restart 2>/dev/null)
  echo "  重启完成，请再次尝试连接。"
fi

echo ""
echo "=============================================="
echo "  诊断结束。若仍无法连接，把本脚本完整输出发出来继续排查。"
echo "=============================================="
