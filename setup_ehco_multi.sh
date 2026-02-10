#!/bin/bash

# ==========================================
# Ehco 多服务器集群管理面板 - 一键安装脚本
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在安装依赖 (Python3, Pip, Paramiko)...${PLAIN}"
apt update -y
apt install -y python3 python3-pip python3-venv sshpass jq

# 项目目录
APP_DIR="/opt/ehco-cluster"
mkdir -p "$APP_DIR/templates"
mkdir -p "$APP_DIR/data"

# 虚拟环境
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install flask gunicorn paramiko

# ==========================================
# 配置 登录密码 和 端口
# ==========================================
echo -e "------------------------------------------------"
if [ -f "$APP_DIR/data/password.txt" ]; then
    echo -e "${GREEN}检测到已安装，保留原密码设置。${PLAIN}"
    read -p "请输入网页运行端口 (默认 8888): " WEB_PORT
    WEB_PORT=${WEB_PORT:-8888}
else
    read -p "请设置【主控面板】的登录密码: " WEB_PASSWORD
    read -p "请设置网页运行端口 (默认 8888): " WEB_PORT
    WEB_PORT=${WEB_PORT:-8888}
    echo "$WEB_PASSWORD" > "$APP_DIR/data/password.txt"
    # 初始化服务器列表
    echo "[]" > "$APP_DIR/data/servers.json"
fi

# ==========================================
# 生成后端 (app.py) - 修复了 EOF 嵌套问题
# ==========================================
cat > "$APP_DIR/app.py" <<EOF
import os
import json
import paramiko
import time
from flask import Flask, request, jsonify, render_template, session, redirect, url_for

app = Flask(__name__)
app.secret_key = os.urandom(24)

DATA_DIR = "$APP_DIR/data"
SERVERS_FILE = os.path.join(DATA_DIR, "servers.json")
PASSWORD_FILE = os.path.join(DATA_DIR, "password.txt")

# Ehco 版本信息
EHCO_VER = "1.1.4"
# 镜像加速
DOWNLOAD_URL_BASE = "https://mirror.ghproxy.com/https://github.com/Ehco1996/ehco/releases/download/v1.1.4"

def get_ssh_client(ip, port, user, password):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(ip, port=int(port), username=user, password=password, timeout=5)
        return client, None
    except Exception as e:
        return None, str(e)

def run_remote_command(server, cmd):
    client, err = get_ssh_client(server['ip'], server['port'], 'root', server['password'])
    if not client:
        return None, err
    stdin, stdout, stderr = client.exec_command(cmd)
    output = stdout.read().decode().strip()
    error = stderr.read().decode().strip()
    client.close()
    return output, error

# ================= ROUTES =================

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password')
        with open(PASSWORD_FILE, 'r') as f:
            stored = f.read().strip()
        if password == stored:
            session['logged_in'] = True
            return redirect(url_for('dashboard'))
        else:
            return render_template('login.html', error="密码错误")
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def root():
    return redirect(url_for('dashboard'))

# 1. 仪表盘：服务器列表
@app.route('/dashboard')
def dashboard():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template('dashboard.html')

# 2. 单机管理页
@app.route('/manage/<int:server_id>')
def manage(server_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template('manage.html', server_id=server_id)

# ================= APIs =================

# API: 获取服务器列表（含连通性检测）
@app.route('/api/servers', methods=['GET'])
def list_servers():
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    with open(SERVERS_FILE, 'r') as f:
        servers = json.load(f)
    
    # 简单的连通性检测
    check_status = request.args.get('check')
    if check_status == 'true':
        for s in servers:
            client, err = get_ssh_client(s['ip'], s['port'], 'root', s['password'])
            s['online'] = True if client else False
            s['err'] = err
            if client: client.close()
            
    return jsonify(servers)

# API: 添加服务器
@app.route('/api/servers/add', methods=['POST'])
def add_server():
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    data = request.json
    with open(SERVERS_FILE, 'r') as f:
        servers = json.load(f)
    
    new_id = 1 if not servers else max(s['id'] for s in servers) + 1
    new_server = {
        'id': new_id,
        'alias': data['alias'],
        'ip': data['ip'],
        'port': data['port'],
        'password': data['password']
    }
    servers.append(new_server)
    with open(SERVERS_FILE, 'w') as f:
        json.dump(servers, f, indent=4)
    return jsonify({'success': True})

# API: 删除服务器
@app.route('/api/servers/delete/<int:sid>', methods=['POST'])
def delete_server(sid):
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    with open(SERVERS_FILE, 'r') as f:
        servers = json.load(f)
    servers = [s for s in servers if s['id'] != sid]
    with open(SERVERS_FILE, 'w') as f:
        json.dump(servers, f, indent=4)
    return jsonify({'success': True})

# --- 远程操作 API ---

def get_server_by_id(sid):
    with open(SERVERS_FILE, 'r') as f:
        servers = json.load(f)
    for s in servers:
        if s['id'] == sid: return s
    return None

@app.route('/api/remote/status/<int:sid>')
def remote_status(sid):
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    server = get_server_by_id(sid)
    if not server: return jsonify({'error': 'Not found'}), 404

    # 1. 检查是否安装
    check_cmd = "test -f /usr/local/bin/ehco && echo 'yes' || echo 'no'"
    out, err = run_remote_command(server, check_cmd)
    if err: return jsonify({'success': False, 'message': f"连接失败: {err}"})
    
    is_installed = (out == 'yes')
    is_running = False
    config_data = []

    if is_installed:
        # 2. 检查运行状态
        run_cmd = "systemctl is-active ehco"
        out_run, _ = run_remote_command(server, run_cmd)
        is_running = (out_run == 'active')

        # 3. 读取配置
        cat_cmd = "cat /etc/ehco/config.json"
        out_conf, _ = run_remote_command(server, cat_cmd)
        try:
            if out_conf:
                raw = json.loads(out_conf)
                if isinstance(raw, list): config_data = raw
                else: config_data = raw.get('relay_rules', [])
        except:
            pass

    return jsonify({
        'success': True,
        'server_alias': server['alias'],
        'server_ip': server['ip'],
        'installed': is_installed,
        'running': is_running,
        'config': config_data
    })

@app.route('/api/remote/install/<int:sid>', methods=['POST'])
def remote_install(sid):
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    server = get_server_by_id(sid)
    
    # 1. 检测架构
    arch_out, _ = run_remote_command(server, "uname -m")
    if arch_out == 'x86_64': filename = "ehco_linux_amd64"
    elif arch_out == 'aarch64': filename = "ehco_linux_arm64"
    else: return jsonify({'success': False, 'message': '不支持的架构'})

    download_url = f"{DOWNLOAD_URL_BASE}/{filename}"
    
    # 2. 组合安装命令 (远程执行)
    # 【修复重点】改用 echo 写入文件，彻底避免嵌套 Heredoc 导致的 Bash 错误
    install_script = f"""
    apt update && apt install -y wget jq
    wget -O /usr/local/bin/ehco {download_url}
    chmod +x /usr/local/bin/ehco
    mkdir -p /etc/ehco
    echo '{{"relay_rules": []}}' > /etc/ehco/config.json
    
    echo '[Unit]
Description=Ehco Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ehco -c /etc/ehco/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target' > /etc/systemd/system/ehco.service

    systemctl daemon-reload
    systemctl enable ehco
    systemctl start ehco
    """
    
    out, err = run_remote_command(server, install_script)
    if "error" in err.lower() and "apt" not in err.lower(): 
         return jsonify({'success': False, 'message': err})
         
    return jsonify({'success': True})

@app.route('/api/remote/restart/<int:sid>', methods=['POST'])
def remote_restart(sid):
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    server = get_server_by_id(sid)
    run_remote_command(server, "systemctl restart ehco")
    return jsonify({'success': True})

@app.route('/api/remote/save_rules/<int:sid>', methods=['POST'])
def remote_save_rules(sid):
    if not session.get('logged_in'): return jsonify({'error': '401'}), 401
    server = get_server_by_id(sid)
    data = request.json 
    
    new_config = {"relay_rules": data.get('rules', [])}
    json_str = json.dumps(new_config, indent=4)
    
    # 通过 echo 写入远程文件
    json_str_safe = json_str.replace("'", "'\"'\"'")
    cmd = f"echo '{json_str_safe}' > /etc/ehco/config.json && systemctl restart ehco"
    
    out, err = run_remote_command(server, cmd)
    return jsonify({'success': True})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$WEB_PORT)
EOF

# ==========================================
# 4. 前端 - 登录页 (login.html)
# ==========================================
cat > "$APP_DIR/templates/login.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Ehco Cluster Login</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>body{background:#f0f2f5;display:flex;align-items:center;justify-content:center;height:100vh}</style>
</head>
<body>
    <div class="card shadow p-4" style="width:350px">
        <h4 class="text-center mb-4">Ehco 中控台</h4>
        {% if error %}<div class="alert alert-danger">{{error}}</div>{% endif %}
        <form method="POST">
            <input type="password" name="password" class="form-control mb-3" placeholder="请输入密码" required>
            <button class="btn btn-primary w-100">登录</button>
        </form>
    </div>
</body>
</html>
EOF

# ==========================================
# 5. 前端 - 首页/仪表盘 (dashboard.html)
# ==========================================
cat > "$APP_DIR/templates/dashboard.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Ehco 服务器列表</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        .status-dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
        .bg-conn-ok { background-color: #28a745; }
        .bg-conn-err { background-color: #dc3545; }
        .bg-conn-check { background-color: #ffc107; }
        .card-server { cursor: pointer; transition: 0.2s; }
        .card-server:hover { transform: translateY(-3px); box-shadow: 0 5px 15px rgba(0,0,0,0.1); }
    </style>
</head>
<body class="bg-light">
<nav class="navbar navbar-dark bg-dark mb-4">
    <div class="container">
        <span class="navbar-brand">Ehco Web UI Cluster</span>
        <a href="/logout" class="btn btn-outline-light btn-sm">退出</a>
    </div>
</nav>
<div class="container">
    <div class="d-flex justify-content-between align-items-center mb-4">
        <h4>已添加服务器</h4>
        <button class="btn btn-primary" data-bs-toggle="modal" data-bs-target="#addServerModal">+ 添加服务器</button>
    </div>

    <div class="row" id="serverList">
        <div class="text-center w-100 mt-5">加载中...</div>
    </div>
</div>

<div class="modal fade" id="addServerModal">
    <div class="modal-dialog">
        <div class="modal-content">
            <div class="modal-header"><h5 class="modal-title">添加受控服务器</h5></div>
            <div class="modal-body">
                <form id="addServerForm">
                    <div class="mb-2"><label>备注名称</label><input type="text" name="alias" class="form-control" required></div>
                    <div class="mb-2"><label>IP 地址</label><input type="text" name="ip" class="form-control" required></div>
                    <div class="mb-2"><label>SSH 端口</label><input type="number" name="port" class="form-control" value="22" required></div>
                    <div class="mb-2"><label>Root 密码</label><input type="password" name="password" class="form-control" required></div>
                </form>
            </div>
            <div class="modal-footer">
                <button class="btn btn-secondary" data-bs-dismiss="modal">取消</button>
                <button class="btn btn-primary" onclick="submitAddServer()">确认添加</button>
            </div>
        </div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
    document.addEventListener('DOMContentLoaded', loadServers);

    async function loadServers() {
        const listDiv = document.getElementById('serverList');
        // 先获取列表
        let res = await fetch('/api/servers');
        let servers = await res.json();
        
        renderList(servers, false);

        // 异步检测连通性
        res = await fetch('/api/servers?check=true');
        servers = await res.json();
        renderList(servers, true);
    }

    function renderList(servers, checked) {
        const listDiv = document.getElementById('serverList');
        if (servers.length === 0) {
            listDiv.innerHTML = '<div class="text-center text-muted">暂无服务器，请先添加</div>';
            return;
        }
        listDiv.innerHTML = '';
        servers.forEach(s => {
            let statusBadge = '<span class="status-dot bg-conn-check"></span> 检测中...';
            if (checked) {
                if (s.online) statusBadge = '<span class="status-dot bg-conn-ok"></span> 连通正常';
                else statusBadge = '<span class="status-dot bg-conn-err"></span> <small>连接失败</small>';
            }

            let html = \`
            <div class="col-md-4 mb-3">
                <div class="card card-server shadow-sm">
                    <div class="card-body">
                        <div class="d-flex justify-content-between">
                            <h5 class="card-title">\${s.alias}</h5>
                            <button onclick="deleteServer(\${s.id})" class="btn btn-sm btn-outline-danger" style="z-index:9">删</button>
                        </div>
                        <p class="card-text text-muted mb-2">\${s.ip}:\${s.port}</p>
                        <div class="mb-3">\${statusBadge}</div>
                        <a href="/manage/\${s.id}" class="btn btn-outline-primary w-100 stretched-link">\${checked && !s.online ? '无法管理' : '管理隧道'}</a>
                    </div>
                </div>
            </div>\`;
            listDiv.innerHTML += html;
        });
    }

    async function submitAddServer() {
        const form = document.getElementById('addServerForm');
        const formData = new FormData(form);
        const data = Object.fromEntries(formData.entries());
        
        await fetch('/api/servers/add', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(data)
        });
        location.reload();
    }

    async function deleteServer(id) {
        if(!confirm('确认移除此服务器记录?')) return;
        event.stopPropagation(); // 防止触发 stretched-link
        await fetch('/api/servers/delete/'+id, {method: 'POST'});
        loadServers();
    }
</script>
</body>
</html>
EOF

# ==========================================
# 6. 前端 - 隧道管理页 (manage.html)
# ==========================================
cat > "$APP_DIR/templates/manage.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>隧道管理</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-light">
<div class="container mt-4">
    <nav aria-label="breadcrumb">
        <ol class="breadcrumb">
            <li class="breadcrumb-item"><a href="/dashboard">服务器列表</a></li>
            <li class="breadcrumb-item active" id="serverBreadcrumb">加载中...</li>
        </ol>
    </nav>

    <div class="card mb-3 shadow-sm">
        <div class="card-body d-flex justify-content-between align-items-center">
            <div>
                <h5 class="mb-0" id="serverTitle">...</h5>
                <span id="installStatus" class="badge bg-secondary">状态检测中...</span>
                <span id="runStatus" class="badge bg-secondary">...</span>
            </div>
            <div id="actionBtns" style="display:none">
                <button onclick="installEhco()" class="btn btn-success btn-sm">一键安装 Ehco</button>
            </div>
            <div id="controlBtns" style="display:none">
                <button onclick="restartEhco()" class="btn btn-warning btn-sm">重启服务</button>
            </div>
        </div>
    </div>

    <div class="card mb-3 shadow-sm">
        <div class="card-header d-flex justify-content-between align-items-center">
            <h6 class="mb-0">隧道列表 (从远程读取)</h6>
            <button onclick="clearRules()" class="btn btn-outline-danger btn-sm">清空并初始化</button>
        </div>
        <div class="card-body">
            <table class="table table-striped table-hover">
                <thead><tr><th>监听</th><th>类型</th><th>转发至</th><th>目标类型</th></tr></thead>
                <tbody id="rulesTable"><tr><td colspan="4">加载中...</td></tr></tbody>
            </table>
        </div>
    </div>

    <div class="card shadow-sm">
        <div class="card-header"><h6>添加隧道转发</h6></div>
        <div class="card-body">
            <ul class="nav nav-tabs mb-3" id="myTab" role="tablist">
                <li class="nav-item"><button class="nav-link active" data-bs-toggle="tab" data-bs-target="#tab1">不加密转发</button></li>
                <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#tab2">加密发送 (中转)</button></li>
                <li class="nav-item"><button class="nav-link" data-bs-toggle="tab" data-bs-target="#tab3">解密接收 (落地)</button></li>
            </ul>

            <div class="tab-content">
                <div class="tab-pane fade show active" id="tab1">
                    <div class="alert alert-info py-2">说明: 国内中转机 -> 落地机 (原生 TCP/UDP)。</div>
                    <form onsubmit="addRule(event, 1)">
                        <div class="row g-2 align-items-end">
                            <div class="col-md-3"><label>本机监听端口</label><input type="number" name="lport" class="form-control" required></div>
                            <div class="col-md-3"><label>目标 IP</label><input type="text" name="tip" class="form-control" required></div>
                            <div class="col-md-3"><label>目标端口</label><input type="number" name="tport" class="form-control" required></div>
                            <div class="col-md-3">
                                <div class="form-check border p-2 rounded bg-white">
                                    <input class="form-check-input" type="checkbox" name="udp_enable" id="udp1">
                                    <label class="form-check-label text-danger fw-bold" for="udp1">同时添加 UDP 规则</label>
                                </div>
                            </div>
                        </div>
                        <button class="btn btn-primary mt-3">添加规则</button>
                    </form>
                </div>

                <div class="tab-pane fade" id="tab2">
                    <form onsubmit="addRule(event, 2)">
                        <div class="mb-2">
                            <label>协议</label>
                            <select name="proto" class="form-select w-auto d-inline-block">
                                <option value="ws">WS</option><option value="wss">WSS</option><option value="mwss">MWSS</option>
                            </select>
                        </div>
                        <div class="row g-2 align-items-end">
                            <div class="col-md-3"><label>本机监听端口</label><input type="number" name="lport" class="form-control" required></div>
                            <div class="col-md-3"><label>落地 IP</label><input type="text" name="tip" class="form-control" required></div>
                            <div class="col-md-3"><label>落地端口</label><input type="number" name="tport" class="form-control" required></div>
                            <div class="col-md-3">
                                <div class="form-check border p-2 rounded bg-white">
                                    <input class="form-check-input" type="checkbox" name="udp_enable" id="udp2">
                                    <label class="form-check-label text-danger fw-bold" for="udp2">同时添加 UDP 规则</label>
                                </div>
                            </div>
                        </div>
                        <button class="btn btn-primary mt-3">添加规则</button>
                    </form>
                </div>

                <div class="tab-pane fade" id="tab3">
                    <form onsubmit="addRule(event, 3)">
                        <div class="mb-2">
                            <label>监听协议</label>
                            <select name="proto" class="form-select w-auto d-inline-block">
                                <option value="ws">WS</option><option value="wss">WSS</option><option value="mwss">MWSS</option>
                            </select>
                        </div>
                        <div class="row g-2 align-items-end">
                            <div class="col-md-3"><label>本机监听端口</label><input type="number" name="lport" class="form-control" required></div>
                            <div class="col-md-3"><label>最终目标 IP</label><input type="text" name="tip" value="127.0.0.1" class="form-control" required></div>
                            <div class="col-md-3"><label>最终目标端口</label><input type="number" name="tport" class="form-control" required></div>
                            <div class="col-md-3">
                                <label>转发给目标协议</label>
                                <select name="target_proto" class="form-select">
                                    <option value="tcp">TCP (默认)</option>
                                    <option value="udp">UDP</option>
                                </select>
                            </div>
                        </div>
                        <button class="btn btn-primary mt-3">添加规则</button>
                    </form>
                </div>
            </div>
        </div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
    const SID = {{ server_id }};
    let currentConfig = [];

    document.addEventListener('DOMContentLoaded', refreshRemote);

    async function refreshRemote() {
        const res = await fetch('/api/remote/status/' + SID);
        const data = await res.json();
        
        if(!data.success) {
            alert('连接服务器失败: ' + data.message);
            window.location.href = '/dashboard';
            return;
        }

        document.getElementById('serverBreadcrumb').innerText = data.server_alias;
        document.getElementById('serverTitle').innerText = data.server_alias + ' (' + data.server_ip + ')';

        if(data.installed) {
            document.getElementById('installStatus').className = 'badge bg-success';
            document.getElementById('installStatus').innerText = '已安装';
            document.getElementById('runStatus').innerText = data.running ? '运行中' : '已停止';
            document.getElementById('runStatus').className = data.running ? 'badge bg-success' : 'badge bg-danger';
            document.getElementById('controlBtns').style.display = 'block';
            document.getElementById('actionBtns').style.display = 'none';
        } else {
            document.getElementById('installStatus').className = 'badge bg-secondary';
            document.getElementById('installStatus').innerText = '未安装';
            document.getElementById('runStatus').style.display = 'none';
            document.getElementById('controlBtns').style.display = 'none';
            document.getElementById('actionBtns').style.display = 'block';
        }

        currentConfig = data.config || [];
        renderTable(currentConfig);
    }

    function renderTable(rules) {
        const tbody = document.getElementById('rulesTable');
        tbody.innerHTML = '';
        if(rules.length === 0) {
            tbody.innerHTML = '<tr><td colspan="4" class="text-center text-muted">暂无配置</td></tr>';
            return;
        }
        rules.forEach(r => {
            tbody.innerHTML += \`<tr><td>\${r.listen}</td><td><span class="badge bg-light text-dark border">\${r.listen_type}</span></td><td>\${r.remote}</td><td><span class="badge bg-light text-dark border">\${r.remote_type}</span></td></tr>\`;
        });
    }

    async function installEhco() {
        if(!confirm('将在远程服务器执行安装脚本，确认?')) return;
        const res = await fetch('/api/remote/install/' + SID, {method: 'POST'});
        const d = await res.json();
        if(d.success) { alert('安装指令已发送，请稍等片刻刷新页面'); setTimeout(refreshRemote, 3000); }
        else alert('安装失败: ' + d.message);
    }

    async function restartEhco() {
        await fetch('/api/remote/restart/' + SID, {method: 'POST'});
        alert('已重启');
        setTimeout(refreshRemote, 1000);
    }

    async function saveRules(newRules) {
        const res = await fetch('/api/remote/save_rules/' + SID, {
            method: 'POST', 
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({rules: newRules})
        });
        if(res.ok) {
            alert('规则已添加并重启服务');
            refreshRemote();
        } else {
            alert('保存失败');
        }
    }

    async function clearRules() {
        if(!confirm('确定清空该服务器所有隧道？')) return;
        await saveRules([]);
    }

    function addRule(e, mode) {
        e.preventDefault();
        const fd = new FormData(e.target);
        const lport = fd.get('lport');
        const tip = fd.get('tip');
        const tport = fd.get('tport');
        const udpEnabled = fd.get('udp_enable') === 'on';

        let newEntries = [];

        if (mode === 1) { // 不加密
            newEntries.push({listen: ':'+lport, listen_type: 'tcp', remote: tip+':'+tport, remote_type: 'tcp'});
            if (udpEnabled) {
                newEntries.push({listen: ':'+lport, listen_type: 'udp', remote: tip+':'+tport, remote_type: 'udp'});
            }
        } else if (mode === 2) { // 加密发送
            const proto = fd.get('proto');
            newEntries.push({listen: ':'+lport, listen_type: 'tcp', remote: tip+':'+tport, remote_type: proto});
            if (udpEnabled) {
                newEntries.push({listen: ':'+lport, listen_type: 'udp', remote: tip+':'+tport, remote_type: proto});
            }
        } else if (mode === 3) { // 解密接收
            const proto = fd.get('proto');
            const tproto = fd.get('target_proto');
            newEntries.push({listen: ':'+lport, listen_type: proto, remote: tip+':'+tport, remote_type: tproto});
        }

        // 追加到现有配置
        const finalRules = currentConfig.concat(newEntries);
        saveRules(finalRules);
        e.target.reset();
    }
</script>
</body>
</html>
EOF

# ==========================================
# 7. 设置 Systemd 服务
# ==========================================
cat > /etc/systemd/system/ehco-cluster.service <<EOF
[Unit]
Description=Ehco Cluster Manager
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
systemctl enable ehco-cluster
systemctl restart ehco-cluster

IP=$(curl -s4 ifconfig.me)
echo -e "${GREEN}==========================================${PLAIN}"
echo -e "${GREEN} Ehco 多服务器中控面板 安装完成！${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}"
echo -e "管理地址: http://${IP}:${WEB_PORT}"
echo -e "登录密码: ${WEB_PASSWORD}"
echo -e "------------------------------------------"
echo -e "${YELLOW}使用说明:${PLAIN}"
echo -e "1. 登录后点击右上角【+ 添加服务器】。"
echo -e "2. 输入你要控制的服务器IP、SSH端口(通常22)和Root密码。"
echo -e "3. 首页会自动检测连通性(绿点表示通，红点表示不通)。"
echo -e "4. 点击服务器卡片，即可远程安装Ehco、管理隧道。"
echo -e "5. 添加隧道时，勾选【同时添加 UDP 规则】即可一键双栈转发。"
