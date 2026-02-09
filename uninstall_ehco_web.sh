#!/bin/bash

# ==========================================
# 颜色定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# ==========================================
# 权限检查
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在开始卸载 Ehco 网页管理端...${PLAIN}"

# ==========================================
# 1. 停止并移除 Web 服务
# ==========================================
if systemctl list-units --full -all | grep -q "ehco-web.service"; then
    echo -e "正在停止 ehco-web 服务..."
    systemctl stop ehco-web
    systemctl disable ehco-web
    rm -f /etc/systemd/system/ehco-web.service
    systemctl daemon-reload
    echo -e "${GREEN}服务已移除。${PLAIN}"
else
    echo -e "${YELLOW}未检测到 ehco-web 服务，跳过。${PLAIN}"
fi

# ==========================================
# 2. 删除网页文件
# ==========================================
if [ -d "/opt/ehco-web" ]; then
    echo -e "正在删除网页文件 (/opt/ehco-web)..."
    rm -rf /opt/ehco-web
    echo -e "${GREEN}文件已删除。${PLAIN}"
else
    echo -e "${YELLOW}目录 /opt/ehco-web 不存在，跳过。${PLAIN}"
fi

echo -e "${GREEN}网页管理端已卸载完成！${PLAIN}"

# ==========================================
# 3. 询问是否卸载 Ehco 核心程序
# ==========================================
echo -e "------------------------------------------------"
echo -e "${YELLOW}注意: 上述步骤仅卸载了网页面板。${PLAIN}"
echo -e "${SKYBLUE}Ehco 核心程序 (转发服务) 可能仍在运行。${PLAIN}"
read -p "是否同时卸载 Ehco 核心程序及所有配置文件? (y/n): " uninstall_core

if [[ "$uninstall_core" == "y" || "$uninstall_core" == "Y" ]]; then
    echo -e "正在卸载 Ehco 核心..."
    
    # 停止核心服务
    systemctl stop ehco
    systemctl disable ehco
    rm -f /etc/systemd/system/ehco.service
    systemctl daemon-reload
    
    # 删除二进制文件
    rm -f /usr/local/bin/ehco
    
    # 删除配置文件
    rm -rf /etc/ehco
    
    echo -e "${GREEN}Ehco 核心程序已彻底卸载。${PLAIN}"
else
    echo -e "${GREEN}保留 Ehco 核心程序，仅卸载了网页 UI。${PLAIN}"
fi

echo -e "${GREEN}所有操作完成。${PLAIN}"
