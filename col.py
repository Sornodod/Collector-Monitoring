from flask import Flask, request, render_template_string, jsonify, session, redirect, url_for
from datetime import datetime
import json
import os
import threading
import time
import requests
import pyotp
import secrets
import logging
import sys
import argparse

# Парсинг аргументов
parser = argparse.ArgumentParser(description='SornMonitor Collector')
parser.add_argument('--no2fa', action='store_true', help='Отключить 2FA')
parser.add_argument('--port', type=int, default=5000, help='Порт')
parser.add_argument('--host', type=str, default='0.0.0.0', help='Хост')
args = parser.parse_args()

app = Flask(__name__)
app.secret_key = secrets.token_hex(16)

# Отключаем логи GET
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

# Загрузка конфига
CONFIG_FILE = os.path.expanduser('~/.config/sornmonitor/config.json')
if os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE, 'r') as f:
        config = json.load(f)
    TOKEN = config.get('telegram_token', '')
    CHAT_ID = config.get('chat_id', 0)
    BROADCAST_MODE = config.get('broadcast_mode', False)
    ADMIN_LOGIN = config.get('admin_login', 'admin')
    ADMIN_PASSWORD = config.get('admin_password', 'admin123')
    ALLOWED_IPS = config.get('allowed_ips', ['127.0.0.1'])
else:
    print("❌ Конфиг не найден!")
    sys.exit(1)

# 2FA
TOTP_SECRET = None
if not args.no2fa and config.get('enable_2fa', True):
    SECRET_FILE = '2fa_secret.json'
    if os.path.exists(SECRET_FILE):
        with open(SECRET_FILE, 'r') as f:
            secret_data = json.load(f)
            TOTP_SECRET = secret_data.get('secret')
    else:
        TOTP_SECRET = pyotp.random_base32()
        with open(SECRET_FILE, 'w') as f:
            json.dump({'secret': TOTP_SECRET}, f)
    print("🔐 2FA включена")
else:
    print("⚠️  2FA отключена")

USERS = {ADMIN_LOGIN: ADMIN_PASSWORD}

# Файлы данных
EVENTS_FILE = 'events.json'
ALLOWED_IPS_FILE = 'allowed_ips.json'

def load_events():
    if os.path.exists(EVENTS_FILE):
        with open(EVENTS_FILE, 'r') as f:
            return json.load(f)
    return []

def save_events(events):
    with open(EVENTS_FILE, 'w') as f:
        json.dump(events, f, indent=2)

events = load_events()
if len(events) > 1000:
    events = events[-1000:]
    save_events(events)

queue = []

def send_telegram(text):
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    if BROADCAST_MODE:
        try:
            updates = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates").json()
            chat_ids = set()
            for update in updates.get('result', []):
                if 'message' in update:
                    chat_ids.add(update['message']['chat']['id'])
            for chat_id in chat_ids:
                try:
                    requests.post(url, json={'chat_id': chat_id, 'text': text}, timeout=10)
                except:
                    pass
            return True
        except Exception as e:
            print(f"❌ Ошибка broadcast: {e}")
            return False
    else:
        try:
            response = requests.post(url, json={'chat_id': CHAT_ID, 'text': text}, timeout=10)
            return response.status_code == 200
        except Exception as e:
            print(f"❌ Ошибка Telegram: {e}")
            return False

def telegram_sender():
    global queue
    while True:
        if queue:
            event = queue.pop(0)
            text = f"📊 {event['server']}\n📝 {event['message']}"
            if event.get('error'):
                text = f"⚠️ {text}"
            if send_telegram(text):
                print(f"✅ Отправлено: {event['server']}")
            else:
                print(f"❌ Ошибка, возвращаем в очередь: {event['server']}")
                queue.insert(0, event)
                time.sleep(5)
        time.sleep(0.5)

thread = threading.Thread(target=telegram_sender, daemon=True)
thread.start()

LOGIN_HTML = '''
<!DOCTYPE html>
<html>
<head><title>Авторизация</title>
<style>body{font-family:monospace;background:#1e1e1e;color:#d4d4d4;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
.login{background:#252526;padding:40px;border-radius:10px;width:300px;box-shadow:0 0 20px rgba(0,0,0,0.5)}
.login h1{text-align:center;color:#4ec9b0;margin-bottom:30px}
.login input{width:100%;padding:10px;margin:8px 0;background:#1e1e1e;border:1px solid #3d3d3d;color:#d4d4d4;border-radius:5px;font-size:14px;box-sizing:border-box}
.login input:focus{outline:none;border-color:#4ec9b0}
.login button{width:100%;padding:12px;margin:15px 0;background:#4ec9b0;color:#1e1e1e;border:none;border-radius:5px;font-size:16px;cursor:pointer;font-weight:bold}
.login button:hover{background:#3db89f}
.error{color:#f44747;text-align:center;margin:10px 0}
.totp-input{letter-spacing:4px;font-size:20px!important;text-align:center}
.no2fa-badge{display:inline-block;background:#f44747;color:#fff;padding:2px 10px;border-radius:10px;font-size:12px;margin-top:10px}
</style></head>
<body><div class="login"><h1>🔐 Мониторинг</h1>
{% if error %}<div class="error">{{ error }}</div>{% endif %}
<form method="POST">
<input type="text" name="username" placeholder="Логин" required>
<input type="password" name="password" placeholder="Пароль" required>
{% if totp_enabled %}
<input type="text" name="totp" placeholder="6-значный код" class="totp-input" maxlength="6" required>
{% endif %}
<button type="submit">Войти</button>
</form>
{% if not totp_enabled %}<div class="no2fa-badge">⚠️ 2FA ОТКЛЮЧЕНА</div>{% endif %}
</div></body></html>
'''

MAIN_HTML = '''
<!DOCTYPE html>
<html>
<head><title>Мониторинг</title>
<style>
body{font-family:monospace;margin:20px;background:#1e1e1e;color:#d4d4d4}
.event{padding:8px;border-bottom:1px solid #333}
.event:hover{background:#2d2d2d}
.time{color:#888}.server{color:#4ec9b0;font-weight:bold}.msg{color:#ce9178}
.error{color:#f44747;background:#2d1a1a;padding:2px 8px;border-radius:3px}
.ok{color:#4ec9b0;background:#1a2d1a;padding:2px 8px;border-radius:3px}
.count{color:#569cd6}.header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap}
.queue-info{color:#d4d4d4;background:#2d2d2d;padding:2px 10px;border-radius:10px}
.clear-btn{background:#4a2a2a;border:none;color:#f44747;padding:5px 15px;cursor:pointer;border-radius:5px}
.clear-btn:hover{background:#5a3a3a}
.logout-btn{background:#2d2d2d;border:none;color:#d4d4d4;padding:5px 15px;cursor:pointer;border-radius:5px;margin-left:10px}
.logout-btn:hover{background:#3d3d3d}
.admin-btn{background:#2d2d2d;border:none;color:#d4d4d4;padding:5px 15px;cursor:pointer;border-radius:5px;margin-left:10px}
.admin-btn:hover{background:#3d3d3d}
.refresh-btn{background:#1a2d3d;border:none;color:#569cd6;padding:5px 15px;cursor:pointer;border-radius:5px;margin-left:10px}
.refresh-btn:hover{background:#1a3d5a}
.no2fa-badge{background:#f44747;color:#fff;padding:2px 10px;border-radius:10px;font-size:12px;margin-left:10px}
.filters{background:#252526;padding:15px;border-radius:8px;margin:15px 0;display:flex;gap:15px;flex-wrap:wrap;align-items:center}
.filters input,.filters select{background:#1e1e1e;border:1px solid #3d3d3d;color:#d4d4d4;padding:8px 12px;border-radius:5px;font-size:14px;font-family:monospace}
.filters input:focus,.filters select:focus{outline:none;border-color:#4ec9b0}
.filters label{color:#888;font-size:12px;text-transform:uppercase}
.filter-group{display:flex;flex-direction:column;gap:3px}
.reset-btn{background:#2d2d2d;border:1px solid #3d3d3d;color:#d4d4d4;padding:8px 15px;border-radius:5px;cursor:pointer;font-family:monospace}
.reset-btn:hover{background:#3d3d3d}
.filtered-count{color:#569cd6;margin-left:10px}
.hidden{display:none}
.user-info{color:#888;font-size:12px}
.last-update{color:#888;font-size:12px;margin-left:10px}
.modal{display:none;position:fixed;z-index:1000;left:0;top:0;width:100%;height:100%;background-color:rgba(0,0,0,0.7)}
.modal-content{background:#252526;margin:10% auto;padding:30px;border-radius:10px;width:500px;max-width:90%;box-shadow:0 0 20px rgba(0,0,0,0.8)}
.modal-content h2{color:#4ec9b0;margin-top:0}
.modal-content input{width:100%;padding:10px;margin:8px 0;background:#1e1e1e;border:1px solid #3d3d3d;color:#d4d4d4;border-radius:5px;font-size:14px;box-sizing:border-box}
.modal-content input:focus{outline:none;border-color:#4ec9b0}
.modal-content button{padding:10px 20px;margin:5px;border:none;border-radius:5px;cursor:pointer;font-weight:bold}
.btn-add{background:#4ec9b0;color:#1e1e1e}
.btn-add:hover{background:#3db89f}
.btn-remove{background:#4a2a2a;color:#f44747}
.btn-remove:hover{background:#5a3a3a}
.btn-close{background:#2d2d2d;color:#d4d4d4}
.btn-close:hover{background:#3d3d3d}
.ip-list{max-height:200px;overflow-y:auto;margin:15px 0;background:#1e1e1e;border-radius:5px;padding:10px}
.ip-item{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid #333}
.ip-item .ip{color:#4ec9b0}
.ip-item .remove{color:#f44747;cursor:pointer}
.ip-item .remove:hover{text-decoration:underline}
.toast{position:fixed;bottom:20px;right:20px;background:#252526;padding:15px 25px;border-radius:5px;border-left:4px solid #4ec9b0;display:none;z-index:2000}
.toast.error{border-left-color:#f44747}
.toast.show{display:block}
</style>
<script>
let updateInterval,isModalOpen=false;
function startAutoRefresh(){if(updateInterval)clearInterval(updateInterval);updateInterval=setInterval(()=>{if(!isModalOpen)location.reload()},30000)}
function applyFilters(){const s=document.getElementById('filter-server').value.toLowerCase();const m=document.getElementById('filter-msg').value.toLowerCase();const st=document.getElementById('filter-status').value;const events=document.querySelectorAll('.event');let v=0;events.forEach(e=>{const sv=e.dataset.server.toLowerCase();const ms=e.dataset.msg.toLowerCase();const sts=e.dataset.status;let show=true;if(s&&!sv.includes(s))show=false;if(m&&!ms.includes(m))show=false;if(st&&sts!==st)show=false;if(show){e.classList.remove('hidden');v++}else{e.classList.add('hidden')}});document.getElementById('filtered-count').textContent=v}
function resetFilters(){document.getElementById('filter-server').value='';document.getElementById('filter-msg').value='';document.getElementById('filter-status').value='';applyFilters()}
function openAdmin(){isModalOpen=true;document.getElementById('adminModal').style.display='block';loadIPs()}
function closeAdmin(){isModalOpen=false;document.getElementById('adminModal').style.display='none'}
function loadIPs(){fetch('/api/ips').then(r=>r.json()).then(d=>{const list=document.getElementById('ipList');list.innerHTML='';d.ips.forEach(ip=>{const div=document.createElement('div');div.className='ip-item';div.innerHTML=`<span class="ip">${ip}</span><span class="remove" onclick="removeIP('${ip}')">✕ удалить</span>`;list.appendChild(div)})})}
function addIP(){const input=document.getElementById('newIP');const ip=input.value.trim();if(!ip){showToast('Введите IP адрес','error');return}fetch('/api/ips',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:ip})}).then(r=>r.json()).then(d=>{if(d.status==='ok'){input.value='';loadIPs();showToast('IP добавлен: '+ip)}else{showToast(d.message||'Ошибка','error')}})}
function removeIP(ip){if(!confirm(`Удалить IP ${ip}?`))return;fetch('/api/ips',{method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:ip})}).then(r=>r.json()).then(d=>{if(d.status==='ok'){loadIPs();showToast('IP удален: '+ip)}else{showToast(d.message||'Ошибка','error')}})}
function clearEvents(){if(confirm('Очистить все события?')){fetch('/clear',{method:'POST'}).then(()=>location.reload())}}
function logout(){if(confirm('Выйти?')){fetch('/logout',{method:'POST'}).then(()=>location.reload())}}
function showToast(msg,type){const t=document.getElementById('toast');t.textContent=msg;t.className='toast show';if(type==='error')t.classList.add('error');setTimeout(()=>t.classList.remove('show'),3000)}
window.onclick=function(e){const m=document.getElementById('adminModal');if(e.target==m)closeAdmin()}
document.addEventListener('DOMContentLoaded',function(){applyFilters();startAutoRefresh();document.getElementById('lastUpdate').textContent=new Date().toLocaleTimeString()})
</script>
</head>
<body>
<div class="header"><h1>📊 Лог мониторинга</h1><div>
<span class="user-info">{{ session.username }}</span>
{% if not totp_enabled %}<span class="no2fa-badge">⚠️ 2FA OFF</span>{% endif %}
<span class="queue-info">📨 В очереди: {{ queue_size }}</span>
<span class="count">Событий: {{ events|length }}</span>
<span class="filtered-count" id="filtered-count">{{ events|length }}</span>
<span class="last-update" id="lastUpdate"></span>
<button class="refresh-btn" onclick="location.reload()">🔄</button>
<button class="admin-btn" onclick="openAdmin()">⚙️ Белый список IP</button>
<button class="clear-btn" onclick="clearEvents()">✕ Очистить</button>
<button class="logout-btn" onclick="logout()">🚪 Выйти</button>
</div></div>
<div class="filters">
<div class="filter-group"><label>Сервер</label><input type="text" id="filter-server" placeholder="web-01" oninput="applyFilters()"></div>
<div class="filter-group"><label>Сообщение</label><input type="text" id="filter-msg" placeholder="CPU, disk..." oninput="applyFilters()"></div>
<div class="filter-group"><label>Статус</label><select id="filter-status" onchange="applyFilters()"><option value="">Все</option><option value="ok">✓ OK</option><option value="error">⚠️ Error</option></select></div>
<button class="reset-btn" onclick="resetFilters()">✕ Сбросить</button>
</div>
<div id="events-container">{% for e in events|reverse %}
<div class="event" data-server="{{ e.server }}" data-msg="{{ e.message }}" data-status="{% if e.error %}error{% else %}ok{% endif %}">
<span class="time">{{ e.time }}</span> [<span class="server">{{ e.server }}</span>] <span class="msg">{{ e.message }}</span>
{% if e.error %}<span class="error">⚠️ {{ e.error }}</span>{% else %}<span class="ok">✓ OK</span>{% endif %}
</div>{% endfor %}</div>
<div id="adminModal" class="modal"><div class="modal-content"><h2>⚙️ Белый список IP</h2><p style="color:#888;font-size:14px;">Только эти IP могут отправлять события</p>
<div style="display:flex;gap:10px;margin:10px 0;"><input type="text" id="newIP" placeholder="Введите IP (например 192.168.1.10)" style="flex:1;"><button class="btn-add" onclick="addIP()">➕ Добавить</button></div>
<div class="ip-list" id="ipList"></div><div style="display:flex;gap:10px;margin-top:10px;"><button class="btn-close" onclick="closeAdmin()">Закрыть</button></div></div></div>
<div id="toast" class="toast"></div>
</body></html>
'''

@app.route('/', methods=['GET', 'POST'])
def login():
    if session.get('authenticated'):
        return render_template_string(MAIN_HTML, events=events, queue_size=len(queue), session=session, totp_enabled=TOTP_SECRET is not None)
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        totp_code = request.form.get('totp', '')
        if username in USERS and USERS[username] == password:
            if TOTP_SECRET:
                totp = pyotp.TOTP(TOTP_SECRET)
                if not totp.verify(totp_code):
                    return render_template_string(LOGIN_HTML, error="❌ Неверный 2FA код", totp_enabled=True)
            session['authenticated'] = True
            session['username'] = username
            return redirect(url_for('login'))
        else:
            return render_template_string(LOGIN_HTML, error="❌ Неверный логин или пароль", totp_enabled=TOTP_SECRET is not None)
    return render_template_string(LOGIN_HTML, error=None, totp_enabled=TOTP_SECRET is not None)

@app.route('/logout', methods=['POST'])
def logout():
    session.clear()
    return 'OK', 200

@app.route('/api/ips', methods=['GET'])
def get_ips():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    return jsonify({'ips': ALLOWED_IPS})

@app.route('/api/ips', methods=['POST'])
def add_ip():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    data = request.json
    ip = data.get('ip', '').strip()
    if not ip:
        return jsonify({'status': 'error', 'message': 'IP не может быть пустым'}), 400
    if ip in ALLOWED_IPS:
        return jsonify({'status': 'error', 'message': 'IP уже в списке'}), 400
    parts = ip.split('.')
    if len(parts) != 4:
        return jsonify({'status': 'error', 'message': 'Неверный формат IP'}), 400
    for p in parts:
        try:
            num = int(p)
            if num < 0 or num > 255:
                raise ValueError
        except ValueError:
            return jsonify({'status': 'error', 'message': 'Неверный формат IP'}), 400
    ALLOWED_IPS.append(ip)
    with open(ALLOWED_IPS_FILE, 'w') as f:
        json.dump(ALLOWED_IPS, f, indent=2)
    return jsonify({'status': 'ok', 'message': f'IP {ip} добавлен'})

@app.route('/api/ips', methods=['DELETE'])
def remove_ip():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    data = request.json
    ip = data.get('ip', '').strip()
    if ip not in ALLOWED_IPS:
        return jsonify({'status': 'error', 'message': 'IP не найден в списке'}), 400
    if len(ALLOWED_IPS) <= 1:
        return jsonify({'status': 'error', 'message': 'Нельзя удалить последний IP'}), 400
    ALLOWED_IPS.remove(ip)
    with open(ALLOWED_IPS_FILE, 'w') as f:
        json.dump(ALLOWED_IPS, f, indent=2)
    return jsonify({'status': 'ok', 'message': f'IP {ip} удален'})

@app.route('/webhook', methods=['POST'])
def webhook():
    global events, queue
    client_ip = request.remote_addr
    if client_ip != '127.0.0.1' and client_ip not in ALLOWED_IPS:
        print(f"🔴 БЛОКИРОВКА: {client_ip}")
        return 'Forbidden', 403
    data = request.json
    event = {
        'time': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'server': data.get('server', 'unknown'),
        'message': data.get('message', ''),
        'error': data.get('error', '')
    }
    queue.append(event)
    events.append(event)
    if len(events) > 1000:
        events = events[-1000:]
    save_events(events)
    print(f"[{event['time']}] {event['server']}: {event['message']}")
    return 'OK', 200

@app.route('/clear', methods=['POST'])
def clear():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    global events
    events = []
    save_events(events)
    return 'OK', 200

@app.route('/events', methods=['GET'])
def get_events():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    server = request.args.get('server', '')
    msg = request.args.get('msg', '')
    status = request.args.get('status', '')
    filtered = events
    if server:
        filtered = [e for e in filtered if server.lower() in e['server'].lower()]
    if msg:
        filtered = [e for e in filtered if msg.lower() in e['message'].lower()]
    if status == 'ok':
        filtered = [e for e in filtered if not e.get('error')]
    elif status == 'error':
        filtered = [e for e in filtered if e.get('error')]
    return jsonify(filtered)

@app.route('/queue', methods=['GET'])
def get_queue():
    return jsonify({'queue_size': len(queue)})

@app.route('/stats', methods=['GET'])
def get_stats():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    stats = {}
    for e in events:
        server = e['server']
        if server not in stats:
            stats[server] = {'total': 0, 'errors': 0}
        stats[server]['total'] += 1
        if e.get('error'):
            stats[server]['errors'] += 1
    return jsonify(stats)

if __name__ == '__main__':
    print(f"🚀 Загружено {len(events)} событий")
    print(f"📨 Очередь: {len(queue)}")
    print(f"🤖 Telegram бот: {'✅' if TOKEN else '❌'}")
    print(f"👤 Логин: {ADMIN_LOGIN}")
    if TOTP_SECRET:
        print(f"🔐 2FA секрет: {TOTP_SECRET}")
    else:
        print("⚠️  2FA отключена")
    print(f"🌐 Белый список: {', '.join(ALLOWED_IPS)}")
    print(f"🌐 Сервер: http://{args.host}:{args.port}")
    app.run(host=args.host, port=args.port, debug=False)
