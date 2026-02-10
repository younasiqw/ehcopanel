#!/bin/bash

# ==========================================
# Ehco 集群版 (Cluster) 专用卸载脚本
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

echo -e "${YELLOW}正在开始卸载 Ehco 集群中控面板...${PLAIN}"

# ==========================================
# 1. 停止并移除 中控 Web 服务
# ==========================================
# 检测 ehco-cluster 服务 (集群版专用名称)
if systemctl list-units --full -all | grep -q "ehco-cluster.service"; then
    echo -e "正在停止 ehco-cluster 服务..."
    systemctl stop ehco-cluster
    systemctl disable ehco-cluster
    rm -f /etc/systemd/system/ehco-cluster.service
    systemctl daemon-reload
    echo -e "${GREEN}中控服务已移除。${PLAIN}"
else
    echo -e "${YELLOW}未检测到 ehco-cluster 服务，跳过。${PLAIN}"
fi

# ==========================================
# 2. 删除中控网页文件
# ==========================================
# 检测 /opt/ehco-cluster (集群版专用目录)
if [ -d "/opt/ehco-cluster" ]; then
    echo -e "正在删除中控面板文件 (/opt/ehco-cluster)..."
    rm -rf /opt/ehco-cluster
    echo -e "${GREEN}文件已删除。${PLAIN}"
else
    echo -e "${YELLOW}目录 /opt/ehco-cluster 不存在，跳过。${PLAIN}"
fi

echo -e "${GREEN}Ehco 集群中控面板已卸载完成！${PLAIN}"

# ==========================================
# 3. 询问是否卸载 本机 Ehco 核心
# ==========================================
echo -e "------------------------------------------------"
echo -e "${YELLOW}注意: 上述步骤仅卸载了【中控面板】。${PLAIN}"
echo -e "${YELLOW}注意: 被控服务器上的 Ehco 依然在运行，不会受影响。${PLAIN}"
echo -e "------------------------------------------------"
echo -e "${SKYBLUE}如果本机也安装了 Ehco 核心用于转发，是否需要一起卸载?${PLAIN}"
read -p "是否卸载本机的 Ehco 核心程序及配置? (y/n): " uninstall_core

if [[ "$uninstall_core" == "y" || "$uninstall_core" == "Y" ]]; then
    echo -e "正在卸载本机 Ehco 核心..."
    
    # 停止核心服务
    systemctl stop ehco
    systemctl disable ehco
    rm -f /etc/systemd/system/ehco.service
    systemctl daemon-reload
    
    # 删除二进制文件
    rm -f /usr/local/bin/ehco
    
    # 删除配置文件
    rm -rf /etc/ehco
    
    echo -e "${GREEN}本机 Ehco 核心程序已彻底卸载。${PLAIN}"
else
    echo -e "${GREEN}保留本机 Ehco 核心程序 (如果有的话)。${PLAIN}"
fi

echo -e "${GREEN}卸载操作全部完成。${PLAIN}"
