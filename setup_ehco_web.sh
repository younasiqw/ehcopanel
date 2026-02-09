#!/bin/bash

# ==========================================
# 颜色定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境检查与安装
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在安装 Python3 和相关依赖...${PLAIN}"
apt update -y
apt install -y python3 python3-pip python3-venv jq

# 创建目录结构
APP_DIR="/opt/ehco-web"
mkdir -p "$APP_DIR/templates"
mkdir -p "$APP_DIR/static"
mkdir -p "/etc/ehco"

# 创建虚拟环境
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install flask gunicorn

# ==========================================
# 2. 设置密码与端口
# ==========================================
echo -e "------------------------------------------------"
# 检查是否已存在密码文件，如果存在则跳过设置，避免覆盖
if [ -f "$APP_DIR/password.txt" ]; then
    echo -e "${GREEN}检测到已存在密码配置，保留原密码。${PLAIN}"
    read -p "请输入网页运行端口 (默认 5000): " WEB_PORT
    WEB_PORT=${WEB_PORT:-5000}
else
    read -p "请设置网页管理端的登录密码: " WEB_PASSWORD
    read -p "请设置网页运行端口 (默认 5000): " WEB_PORT
    WEB_PORT=${WEB_PORT:-5000}
    echo "$WEB_PASSWORD" > "$APP_DIR/password.txt"
fi

# ==========================================
# 3. 生成后端代码 (app.py) - 核心修复
# ==========================================
cat > "$APP_DIR/app.py" <<EOF
import os
import json
import subprocess
import platform
from flask import Flask, request, jsonify, render_template, session, redirect, url_for

app = Flask(__name__)
app.secret_key = os.urandom(24)

# 配置路径
PASSWORD_FILE = "$APP_DIR/password.txt"
EHCO_CONFIG = "/etc/ehco/config.json"
EHCO_BIN = "/usr/local/bin/ehco"
SERVICE_FILE = "/etc/systemd/system/ehco.service"
EHCO_VERSION = "1.1.4"

def check_auth():
    return session.get('logged_in')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password')
        with open(PASSWORD_FILE, 'r') as f:
            stored_pw = f.read().strip()
        if password == stored_pw:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            return render_template('login.html', error="密码错误")
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def index():
    if not check_auth(): return redirect(url_for('login'))
    return render_template('index.html')

# API: 获取状态 (已修复读取逻辑)
@app.route('/api/status')
def get_status():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    
    is_installed = os.path.exists(EHCO_BIN)
    is_running = False
    if is_installed:
        res = subprocess.run(["systemctl", "is-active", "ehco"], capture_output=True, text=True)
        is_running = (res.stdout.strip() == "active")
    
    # 读取配置
    config_data = []
    if os.path.exists(EHCO_CONFIG):
        try:
            with open(EHCO_CONFIG, 'r') as f:
                raw = json.load(f)
                # === 修复: 兼容旧版数组和新版对象 ===
                if isinstance(raw, list):
                    config_data = raw
                else:
                    config_data = raw.get('relay_rules', [])
        except:
            pass

    return jsonify({
        "installed": is_installed,
        "running": is_running,
        "config": config_data
    })

# API: 安装 Ehco
@app.route('/api/install', methods=['POST'])
def install_ehco():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    
    arch = platform.machine()
    if arch == "x86_64":
        arch_tag = "amd64"
    elif arch == "aarch64":
        arch_tag = "arm64"
    else:
        return jsonify({"success": False, "message": f"不支持的架构: {arch}"})

    base_url = "https://github.com/Ehco1996/ehco/releases/download"
    filename = f"ehco_linux_{arch_tag}"
    
    # 优先尝试镜像下载
    mirror_url = f"https://mirror.ghproxy.com/{base_url}/v{EHCO_VERSION}/{filename}"
    
    try:
        print(f"Trying to download from: {mirror_url}")
        subprocess.run(["wget", "-O", EHCO_BIN, mirror_url], check=True)
    except subprocess.CalledProcessError:
        # 如果镜像失败，尝试官方源
        try:
            origin_url = f"{base_url}/v{EHCO_VERSION}/{filename}"
            print(f"Mirror failed, trying original: {origin_url}")
            subprocess.run(["wget", "-O", EHCO_BIN, origin_url], check=True)
        except subprocess.CalledProcessError as e:
            return jsonify({"success": False, "message": "下载失败，请检查网络或手动上传文件"})

    try:
        subprocess.run(["chmod", "+x", EHCO_BIN], check=True)
        
        # === 修复: 初始化为对象结构 ===
        if not os.path.exists(EHCO_CONFIG):
            with open(EHCO_CONFIG, 'w') as f:
                json.dump({"relay_rules": []}, f)

        service_content = f"""[Unit]
Description=Ehco Service
After=network.target

[Service]
Type=simple
User=root
ExecStart={EHCO_BIN} -c {EHCO_CONFIG}
Restart=on-failure

[Install]
WantedBy=multi-user.target
"""
        with open(SERVICE_FILE, 'w') as f:
            f.write(service_content)

        subprocess.run(["systemctl", "daemon-reload"])
        subprocess.run(["systemctl", "enable", "ehco"])
        subprocess.run(["systemctl", "start", "ehco"])
        
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)})

# API: 卸载 Ehco
@app.route('/api/uninstall', methods=['POST'])
def uninstall_ehco():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    subprocess.run(["systemctl", "stop", "ehco"])
    subprocess.run(["systemctl", "disable", "ehco"])
    if os.path.exists(SERVICE_FILE): os.remove(SERVICE_FILE)
    subprocess.run(["systemctl", "daemon-reload"])
    if os.path.exists(EHCO_BIN): os.remove(EHCO_BIN)
    return jsonify({"success": True})

# API: 重启 Ehco
@app.route('/api/restart', methods=['POST'])
def restart_ehco():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    subprocess.run(["systemctl", "restart", "ehco"])
    return jsonify({"success": True})

# API: 初始化配置
@app.route('/api/init_config', methods=['POST'])
def init_config():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    # === 修复: 初始化为对象结构 ===
    with open(EHCO_CONFIG, 'w') as f:
        json.dump({"relay_rules": []}, f)
    return jsonify({"success": True})

# API: 添加规则
@app.route('/api/add_rule', methods=['POST'])
def add_rule():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    data = request.json
    
    # 默认基本结构
    current_config = {"relay_rules": []}
    
    if os.path.exists(EHCO_CONFIG):
        with open(EHCO_CONFIG, 'r') as f:
            try:
                raw = json.load(f)
                # === 修复: 自动处理数组转对象 ===
                if isinstance(raw, list):
                    current_config["relay_rules"] = raw
                else:
                    current_config = raw
            except:
                pass
    
    rules_to_add = data.get('rules', [])
    for r in rules_to_add:
        # 确保 relay_rules 键存在
        if "relay_rules" not in current_config:
            current_config["relay_rules"] = []
        current_config["relay_rules"].append(r)
        
    with open(EHCO_CONFIG, 'w') as f:
        json.dump(current_config, f, indent=4)
        
    return jsonify({"success": True})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$WEB_PORT)
EOF

# ==========================================
# 4. 生成前端模板 (login.html)
# ==========================================
cat > "$APP_DIR/templates/login.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Ehco Admin Login</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background-color: #f8f9fa; display: flex; align-items: center; justify-content: center; height: 100vh; }
        .card { width: 100%; max-width: 400px; }
    </style>
</head>
<body>
    <div class="card shadow">
        <div class="card-body">
            <h3 class="card-title text-center mb-4">Ehco 管理面板</h3>
            {% if error %}
            <div class="alert alert-danger">{{ error }}</div>
            {% endif %}
            <form method="POST">
                <div class="mb-3">
                    <label class="form-label">密码</label>
                    <input type="password" name="password" class="form-control" required>
                </div>
                <button type="submit" class="btn btn-primary w-100">登录</button>
            </form>
        </div>
    </div>
</body>
</html>
EOF

# ==========================================
# 5. 生成前端模板 (index.html)
# ==========================================
cat > "$APP_DIR/templates/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Ehco Dashboard</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        .status-dot { height: 10px; width: 10px; background-color: #bbb; border-radius: 50%; display: inline-block; margin-right: 5px; }
        .status-active { background-color: #28a745; }
        .status-inactive { background-color: #dc3545; }
    </style>
</head>
<body class="bg-light">

<nav class="navbar navbar-expand-lg navbar-dark bg-dark mb-4">
    <div class="container">
        <a class="navbar-brand" href="#">Ehco Web UI</a>
        <div class="d-flex">
            <a href="/logout" class="btn btn-outline-light btn-sm">退出登录</a>
        </div>
    </div>
</nav>

<div class="container">
    <div class="card mb-4 shadow-sm">
        <div class="card-body d-flex justify-content-between align-items-center">
            <div>
                <h5 class="mb-0">系统状态</h5>
                <span id="installStatus" class="badge bg-secondary">检测中...</span>
                <span id="runStatus" class="badge bg-secondary">检测中...</span>
            </div>
            <div id="actionButtons">
                <button onclick="installEhco()" class="btn btn-success btn-sm">安装 Ehco</button>
                <button onclick="restartEhco()" class="btn btn-warning btn-sm">重启服务</button>
                <button onclick="uninstallEhco()" class="btn btn-danger btn-sm">卸载</button>
            </div>
        </div>
    </div>

    <div class="card mb-4 shadow-sm">
        <div class="card-header d-flex justify-content-between align-items-center">
            <h5 class="mb-0">当前隧道信息</h5>
            <button onclick="initConfig()" class="btn btn-outline-danger btn-sm">初始化配置</button>
        </div>
        <div class="card-body">
            <div class="table-responsive">
                <table class="table table-striped table-hover">
                    <thead>
                        <tr>
                            <th>监听地址</th>
                            <th>监听类型</th>
                            <th>远程地址</th>
                            <th>远程类型</th>
                        </tr>
                    </thead>
                    <tbody id="configTableBody">
                    </tbody>
                </table>
            </div>
            <p class="text-muted small mt-2">注意: 修改配置后请点击“重启服务”生效。</p>
        </div>
    </div>

    <div class="card shadow-sm">
        <div class="card-header">
            <h5 class="mb-0">添加隧道中转</h5>
        </div>
        <div class="card-body">
            <ul class="nav nav-tabs mb-3" id="relayTab" role="tablist">
                <li class="nav-item"><button class="nav-link active" data-bs-toggle="tab" data-bs-target="#mode1" type="button">1. 不加密转发</button></li>
                <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#mode2" type="button">2. 加密转发 (发送)</button></li>
                <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#mode3" type="button">3. 解密转发 (接收)</button></li>
            </ul>

            <div class="tab-content">
                <div class="tab-pane fade show active" id="mode1">
                    <div class="alert alert-info">说明: 一般设置在国内中转机上。将同时转发 TCP 和 UDP。</div>
                    <form onsubmit="addRule(event, 1)">
                        <div class="row g-3">
                            <div class="col-md-4"><label>本机监听端口</label><input type="number" class="form-control" name="lport" required></div>
                            <div class="col-md-4"><label>目标 IP</label><input type="text" class="form-control" name="tip" required></div>
                            <div class="col-md-4"><label>目标端口</label><input type="number" class="form-control" name="tport" required></div>
                        </div>
                        <button type="submit" class="btn btn-primary mt-3">添加规则</button>
                    </form>
                </div>

                <div class="tab-pane fade" id="mode2">
                    <div class="alert alert-info">说明: 一般设置在国内中转机上。用于转发流量到远端已开启解密的机器。</div>
                    <form onsubmit="addRule(event, 2)">
                        <div class="mb-3">
                            <label>加密协议</label>
                            <select class="form-select" name="proto">
                                <option value="ws">WS 隧道</option>
                                <option value="wss">WSS 隧道</option>
                                <option value="mwss">MWSS 隧道</option>
                            </select>
                        </div>
                        <div class="mb-3 form-check">
                            <input type="checkbox" class="form-check-input" id="udpCheck2" name="udp_enable">
                            <label class="form-check-label" for="udpCheck2">同时转发 UDP (不建议用于实时游戏)</label>
                        </div>
                        <div class="row g-3">
                            <div class="col-md-4"><label>本机监听端口</label><input type="number" class="form-control" name="lport" required></div>
                            <div class="col-md-4"><label>落地机 IP</label><input type="text" class="form-control" name="tip" required></div>
                            <div class="col-md-4"><label>落地机端口</label><input type="number" class="form-control" name="tport" required></div>
                        </div>
                        <button type="submit" class="btn btn-primary mt-3">添加规则</button>
                    </form>
                </div>

                <div class="tab-pane fade" id="mode3">
                    <div class="alert alert-info">说明: 一般设置在国外机器上。接收来自 Ehco 的加密流量并解密转发给目标。</div>
                    <form onsubmit="addRule(event, 3)">
                        <div class="mb-3">
                            <label>监听协议 (必须与发送端一致)</label>
                            <select class="form-select" name="proto">
                                <option value="ws">WS 隧道</option>
                                <option value="wss">WSS 隧道</option>
                                <option value="mwss">MWSS 隧道</option>
                            </select>
                        </div>
                        <div class="mb-3">
                            <label>转发给目标的协议</label>
                            <select class="form-select" name="target_proto">
                                <option value="tcp">TCP (默认)</option>
                                <option value="udp">UDP (警告: 可能不稳定)</option>
                            </select>
                        </div>
                        <div class="row g-3">
                            <div class="col-md-4"><label>本机监听端口</label><input type="number" class="form-control" name="lport" required></div>
                            <div class="col-md-4"><label>最终目标 IP</label><input type="text" class="form-control" name="tip" value="127.0.0.1" required></div>
                            <div class="col-md-4"><label>最终目标端口</label><input type="number" class="form-control" name="tport" required></div>
                        </div>
                        <button type="submit" class="btn btn-primary mt-3">添加规则</button>
                    </form>
                </div>
            </div>
        </div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
    document.addEventListener('DOMContentLoaded', refreshStatus);

    async function refreshStatus() {
        const res = await fetch('/api/status');
        if (res.status === 401) window.location.reload();
        const data = await res.json();
        
        const installBadge = document.getElementById('installStatus');
        const runBadge = document.getElementById('runStatus');
        const btns = document.getElementById('actionButtons');
        
        if (data.installed) {
            installBadge.className = 'badge bg-success';
            installBadge.innerText = '已安装';
            runBadge.className = data.running ? 'badge bg-success' : 'badge bg-danger';
            runBadge.innerText = data.running ? '运行中' : '已停止';
        } else {
            installBadge.className = 'badge bg-secondary';
            installBadge.innerText = '未安装';
            runBadge.style.display = 'none';
        }

        const tbody = document.getElementById('configTableBody');
        tbody.innerHTML = '';
        if (data.config && data.config.length > 0) {
            data.config.forEach(item => {
                tbody.innerHTML += \`<tr>
                    <td>\${item.listen}</td>
                    <td><span class="badge bg-info text-dark">\${item.listen_type}</span></td>
                    <td>\${item.remote}</td>
                    <td><span class="badge bg-warning text-dark">\${item.remote_type}</span></td>
                </tr>\`;
            });
        } else {
            tbody.innerHTML = '<tr><td colspan="4" class="text-center">暂无配置</td></tr>';
        }
    }

    async function installEhco() {
        if(!confirm('确认安装 Ehco?')) return;
        const res = await fetch('/api/install', {method: 'POST'});
        const data = await res.json();
        if(data.success) { alert('安装成功'); refreshStatus(); }
        else alert('安装失败: ' + data.message);
    }

    async function uninstallEhco() {
        if(!confirm('确认卸载 Ehco?')) return;
        const res = await fetch('/api/uninstall', {method: 'POST'});
        const data = await res.json();
        if(data.success) { alert('卸载成功'); refreshStatus(); }
    }

    async function restartEhco() {
        const res = await fetch('/api/restart', {method: 'POST'});
        alert('已发送重启命令');
        setTimeout(refreshStatus, 2000);
    }

    async function initConfig() {
        if(!confirm('确认初始化配置？这将清空所有隧道！')) return;
        const res = await fetch('/api/init_config', {method: 'POST'});
        alert('配置已重置');
        refreshStatus();
    }

    async function addRule(event, mode) {
        event.preventDefault();
        const formData = new FormData(event.target);
        const rules = [];
        
        const lport = formData.get('lport');
        const tip = formData.get('tip');
        const tport = formData.get('tport');

        if (mode === 1) {
            rules.push({listen: ':'+lport, listen_type: 'tcp', remote: tip+':'+tport, remote_type: 'tcp'});
            rules.push({listen: ':'+lport, listen_type: 'udp', remote: tip+':'+tport, remote_type: 'udp'});
        } else if (mode === 2) {
            const proto = formData.get('proto');
            const udpEnable = formData.get('udp_enable') === 'on';
            rules.push({listen: ':'+lport, listen_type: 'tcp', remote: tip+':'+tport, remote_type: proto});
            if (udpEnable) {
                rules.push({listen: ':'+lport, listen_type: 'udp', remote: tip+':'+tport, remote_type: proto});
            }
        } else if (mode === 3) {
            const proto = formData.get('proto');
            const targetProto = formData.get('target_proto');
            rules.push({listen: ':'+lport, listen_type: proto, remote: tip+':'+tport, remote_type: targetProto});
        }

        const res = await fetch('/api/add_rule', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({rules: rules})
        });
        
        if (res.ok) {
            alert('规则已添加！请点击“重启服务”生效。');
            event.target.reset();
            refreshStatus();
        } else {
            alert('添加失败');
        }
    }
</script>
</body>
</html>
EOF

# ==========================================
# 6. 设置 Systemd 服务并启动 Web
# ==========================================
cat > /etc/systemd/system/ehco-web.service <<EOF
[Unit]
Description=Ehco Web Dashboard
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn -w 1 -b 0.0.0.0:$WEB_PORT app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ehco-web
systemctl restart ehco-web

# ==========================================
# 7. 强制修复现有配置 (Critical Fix)
# ==========================================
if [ -f "/etc/ehco/config.json" ]; then
    echo -e "${YELLOW}正在强制重置配置文件格式...${PLAIN}"
    # 强制覆盖为正确的对象格式，避免旧的数组格式残留
    echo '{"relay_rules": []}' > /etc/ehco/config.json
    systemctl restart ehco
fi

# ==========================================
# 8. 完成提示
# ==========================================
IP=$(curl -s4 ifconfig.me)
echo -e "${GREEN}==========================================${PLAIN}"
echo -e "${GREEN} Ehco 网页管理端安装完成！${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
echo -e "请访问: http://${IP}:${WEB_PORT}"
echo -e "密码: ${WEB_PASSWORD}"
echo -e "注意: 如果无法访问，请检查服务器防火墙是否放行端口 ${WEB_PORT}"
