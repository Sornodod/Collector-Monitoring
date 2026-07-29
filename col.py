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
import traceback

# ============================================================
# НАСТРОЙКА ЛОГИРОВАНИЯ
# ============================================================

# Создаем директорию для логов если нет
LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs')
os.makedirs(LOG_DIR, exist_ok=True)

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(os.path.join(LOG_DIR, 'collector.log')),
        logging.FileHandler(os.path.join(LOG_DIR, 'errors.log'))
    ]
)

error_logger = logging.getLogger('errors')
error_logger.setLevel(logging.ERROR)
error_handler = logging.FileHandler(os.path.join(LOG_DIR, 'errors.log'))
error_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
error_logger.addHandler(error_handler)

logger = logging.getLogger(__name__)

# ============================================================
# Парсинг аргументов
# ============================================================

parser = argparse.ArgumentParser(description='SornMonitor Collector')
parser.add_argument('--no2fa', action='store_true', help='Отключить 2FA')
parser.add_argument('--port', type=int, default=5000, help='Порт')
parser.add_argument('--host', type=str, default='0.0.0.0', help='Хост')
args = parser.parse_args()

app = Flask(__name__)
app.secret_key = secrets.token_hex(16)

# Отключаем логи GET от Flask
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

# ============================================================
# Загрузка конфига
# ============================================================

CONFIG_FILE = os.path.expanduser('~/.config/sornmonitor/config.json')
if os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE, 'r') as f:
        config = json.load(f)
    TOKEN = config.get('telegram_token', '')
    CHAT_ID = config.get('chat_id', 0)
    BROADCAST_MODE = config.get('broadcast_mode', False)
    ADMIN_LOGIN = config.get('admin_login', 'admin')
    ADMIN_PASSWORD = config.get('admin_password', 'admin123')
    WEB_ENABLED = config.get('web_enabled', True)
    WEB_HOST = config.get('web_host', '0.0.0.0')
    WEB_PORT = config.get('web_port', 5000)
    ALLOWED_IPS = config.get('allowed_ips', ['127.0.0.1'])
else:
    logger.error("❌ Конфиг не найден!")
    sys.exit(1)

# ============================================================
# 2FA
# ============================================================

TOTP_SECRET = None
if not args.no2fa and config.get('enable_2fa', True):
    SECRET_FILE = '2fa_secret.json'
    if os.path.exists(SECRET_FILE):
        with open(SECRET_FILE, 'r') as f:
            secret_data = json.load(f)
            TOTP_SECRET = secret_data.get('secret')
        logger.info("🔐 2FA секрет загружен из файла")
    else:
        TOTP_SECRET = pyotp.random_base32()
        with open(SECRET_FILE, 'w') as f:
            json.dump({'secret': TOTP_SECRET}, f)
        logger.info("🔐 2FA секрет сгенерирован и сохранен")
    logger.info("🔐 2FA включена")
else:
    logger.warning("⚠️  2FA отключена")

USERS = {ADMIN_LOGIN: ADMIN_PASSWORD}

# ============================================================
# Файлы данных
# ============================================================

EVENTS_FILE = 'events.json'
ALLOWED_IPS_FILE = 'allowed_ips.json'

def load_allowed_ips():
    if os.path.exists(ALLOWED_IPS_FILE):
        try:
            with open(ALLOWED_IPS_FILE, 'r') as f:
                ips = json.load(f)
                if isinstance(ips, list) and ips:
                    return ips
        except Exception as e:
            logger.error(f"Ошибка загрузки белого списка: {e}")
    return ALLOWED_IPS

ALLOWED_IPS = load_allowed_ips()

def load_events():
    if os.path.exists(EVENTS_FILE):
        try:
            with open(EVENTS_FILE, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Ошибка загрузки событий: {e}")
    return []

def save_events(events):
    try:
        with open(EVENTS_FILE, 'w') as f:
            json.dump(events, f, indent=2)
    except Exception as e:
        logger.error(f"Ошибка сохранения событий: {e}")

events = load_events()
if len(events) > 1000:
    events = events[-1000:]
    save_events(events)

queue = []

# ============================================================
# Логирование попыток авторизации
# ============================================================

AUTH_LOG = os.path.join(LOG_DIR, 'auth_attempts.log')

def log_auth_attempt(ip, username, success=False, message=""):
    try:
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        status = "✅ УСПЕШНО" if success else "❌ НЕУДАЧНО"
        log_entry = f"[{timestamp}] {status} | IP: {ip} | Пользователь: {username} | {message}\n"
        with open(AUTH_LOG, 'a') as f:
            f.write(log_entry)
        logger.info(f"🔐 [AUTH] {status} | {username} | {ip} | {message}")
    except Exception as e:
        logger.error(f"Ошибка логирования авторизации: {e}")

# ============================================================
# Логирование webhook запросов
# ============================================================

WEBHOOK_LOG = os.path.join(LOG_DIR, 'webhook_requests.log')

def log_webhook_request(ip, data, status=200):
    try:
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        log_entry = f"[{timestamp}] IP: {ip} | Статус: {status} | Данные: {json.dumps(data)}\n"
        with open(WEBHOOK_LOG, 'a') as f:
            f.write(log_entry)
    except Exception as e:
        logger.error(f"Ошибка логирования webhook: {e}")

# ============================================================
# Отправка в Telegram
# ============================================================

def send_telegram(text):
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"
    
    if BROADCAST_MODE:
        try:
            logger.info("📡 [BROADCAST] Получение списка подписчиков...")
            updates = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates", timeout=10).json()
            chat_ids = set()
            for update in updates.get('result', []):
                if 'message' in update:
                    chat_ids.add(update['message']['chat']['id'])
            
            logger.info(f"👥 [BROADCAST] Найдено подписчиков: {len(chat_ids)}")
            
            if not chat_ids:
                logger.warning("⚠️ [BROADCAST] Нет подписчиков! Напишите /start боту")
                return False
            
            success_count = 0
            for chat_id in chat_ids:
                try:
                    response = requests.post(url, json={'chat_id': chat_id, 'text': text}, timeout=10)
                    if response.status_code == 200:
                        success_count += 1
                        logger.info(f"📨 [BROADCAST] Отправлено в чат {chat_id}: OK")
                    else:
                        logger.error(f"❌ [BROADCAST] Ошибка в чат {chat_id}: {response.status_code}")
                except Exception as e:
                    logger.error(f"❌ [BROADCAST] Ошибка в чат {chat_id}: {e}")
            
            logger.info(f"📊 [BROADCAST] Успешно отправлено: {success_count}/{len(chat_ids)}")
            return success_count > 0
            
        except Exception as e:
            logger.error(f"❌ [BROADCAST] Критическая ошибка: {e}")
            error_logger.error(traceback.format_exc())
            return False
    else:
        try:
            logger.info(f"📡 [PRIVATE] Отправка в чат {CHAT_ID}...")
            response = requests.post(url, json={'chat_id': CHAT_ID, 'text': text}, timeout=10)
            logger.info(f"📨 [PRIVATE] Статус ответа: {response.status_code}")
            
            if response.status_code == 200:
                logger.info(f"✅ [PRIVATE] Успешно отправлено в чат {CHAT_ID}")
                return True
            else:
                logger.error(f"❌ [PRIVATE] Ошибка: {response.text}")
                return False
                
        except requests.exceptions.Timeout:
            logger.error("❌ [PRIVATE] Таймаут при отправке в Telegram")
            return False
        except Exception as e:
            logger.error(f"❌ [PRIVATE] Ошибка Telegram: {e}")
            error_logger.error(traceback.format_exc())
            return False

# ============================================================
# Фоновый поток отправки
# ============================================================

def telegram_sender():
    global queue
    logger.info("🔄 [THREAD] Поток telegram_sender запущен")
    
    while True:
        try:
            if queue:
                queue_size = len(queue)
                logger.info(f"📨 [THREAD] Обработка очереди: {queue_size} событий")
                
                event = queue.pop(0)
                logger.info(f"📤 [THREAD] Отправка: {event['server']} | {event['message']}")
                
                text = f"📊 {event['server']}\n📝 {event['message']}"
                if event.get('error'):
                    text = f"⚠️ {text}"
                
                if send_telegram(text):
                    logger.info(f"✅ [THREAD] Успешно отправлено: {event['server']}")
                else:
                    logger.warning(f"❌ [THREAD] Ошибка отправки, возвращаем в очередь: {event['server']}")
                    queue.insert(0, event)
                    logger.info(f"⏳ [THREAD] Пауза 5 секунд перед повторной попыткой...")
                    time.sleep(5)
            else:
                pass
                
            time.sleep(0.5)
            
        except Exception as e:
            logger.error(f"🔥 [THREAD] КРИТИЧЕСКАЯ ОШИБКА в telegram_sender: {e}")
            error_logger.error(traceback.format_exc())
            logger.info(f"⏳ [THREAD] Пауза 10 секунд после критической ошибки...")
            time.sleep(10)

logger.info("🔄 Запуск фонового потока telegram_sender...")
thread = threading.Thread(target=telegram_sender, daemon=True)
thread.start()
logger.info("✅ Фоновый поток запущен")

# ============================================================
# HTML страницы
# ============================================================

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

# ============================================================
# Веб-морда отключена — заглушка
# ============================================================

WEB_DISABLED_HTML = '''
<!DOCTYPE html>
<html>
<head><title>Web UI Disabled</title></head>
<body style="background:#1e1e1e;color:#d4d4d4;font-family:monospace;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;">
    <div style="text-align:center;max-width:600px;padding:40px;background:#252526;border-radius:10px;box-shadow:0 0 20px rgba(0,0,0,0.5);">
        <h1 style="color:#f44747;">🌐 Веб-морда отключена</h1>
        <p style="color:#888;">Веб-интерфейс отключен в настройках.</p>
        <p style="color:#888;">Webhook доступен по адресу: <code style="background:#1e1e1e;padding:2px 8px;border-radius:4px;color:#4ec9b0;">/webhook</code></p>
        <p style="color:#888;">Статус: <span style="color:#4ec9b0;">✅ Коллектор работает</span></p>
        <hr style="border-color:#333;">
        <p style="color:#555;font-size:12px;">SornMonitor Collector v2.0</p>
    </div>
</body>
</html>
'''

# ============================================================
# Маршруты Flask
# ============================================================

@app.route('/', methods=['GET', 'POST'])
def login():
    # Если веб-морда отключена — показываем заглушку
    if not WEB_ENABLED:
        return WEB_DISABLED_HTML, 200
    
    if session.get('authenticated'):
        return render_template_string(MAIN_HTML, 
                                    events=events, 
                                    queue_size=len(queue), 
                                    session=session,
                                    totp_enabled=TOTP_SECRET is not None)
    
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        totp_code = request.form.get('totp', '')
        client_ip = request.remote_addr
        
        logger.info(f"🔐 [AUTH] Попытка входа: {username} | IP: {client_ip}")
        
        if username in USERS and USERS[username] == password:
            if TOTP_SECRET:
                totp = pyotp.TOTP(TOTP_SECRET)
                if not totp.verify(totp_code):
                    logger.warning(f"❌ [AUTH] Неверный 2FA код: {username} | IP: {client_ip}")
                    log_auth_attempt(client_ip, username, False, "Неверный 2FA код")
                    return render_template_string(LOGIN_HTML, error="❌ Неверный 2FA код", totp_enabled=True)
            
            session['authenticated'] = True
            session['username'] = username
            logger.info(f"✅ [AUTH] Успешный вход: {username} | IP: {client_ip}")
            log_auth_attempt(client_ip, username, True, "Успешный вход")
            return redirect(url_for('login'))
        else:
            logger.warning(f"❌ [AUTH] Неверные логин/пароль: {username} | IP: {client_ip}")
            log_auth_attempt(client_ip, username, False, "Неверный логин или пароль")
            return render_template_string(LOGIN_HTML, error="❌ Неверный логин или пароль", totp_enabled=TOTP_SECRET is not None)
    
    return render_template_string(LOGIN_HTML, error=None, totp_enabled=TOTP_SECRET is not None)

@app.route('/logout', methods=['POST'])
def logout():
    session.clear()
    logger.info("🚪 [AUTH] Выход из системы")
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
    logger.info(f"✅ [IP] Добавлен IP: {ip}")
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
    logger.info(f"🗑️ [IP] Удален IP: {ip}")
    return jsonify({'status': 'ok', 'message': f'IP {ip} удален'})

@app.route('/webhook', methods=['POST'])
def webhook():
    global events, queue
    client_ip = request.remote_addr
    data = request.json
    
    logger.info(f"📥 [WEBHOOK] Получен запрос от {client_ip}")
    
    # Проверка IP
    if client_ip != '127.0.0.1' and client_ip not in ALLOWED_IPS:
        logger.warning(f"🔴 [WEBHOOK] БЛОКИРОВКА: {client_ip} не в белом списке")
        log_webhook_request(client_ip, data, 403)
        return 'Forbidden', 403
    
    if not data:
        logger.warning(f"⚠️ [WEBHOOK] Пустой запрос от {client_ip}")
        return 'Bad Request', 400
    
    event = {
        'time': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'server': data.get('server', 'unknown'),
        'message': data.get('message', ''),
        'error': data.get('error', '')
    }
    
    logger.info(f"📥 [WEBHOOK] Событие: {event['server']} | {event['message']} | Ошибка: {event['error']}")
    
    queue.append(event)
    events.append(event)
    if len(events) > 1000:
        events = events[-1000:]
    save_events(events)
    
    queue_size = len(queue)
    logger.info(f"📊 [WEBHOOK] Очередь: {queue_size} событий")
    log_webhook_request(client_ip, data, 200)
    
    return 'OK', 200

@app.route('/clear', methods=['POST'])
def clear():
    if not session.get('authenticated'):
        return 'Forbidden', 403
    global events
    events = []
    save_events(events)
    logger.info("🗑️ [CLEAR] Все события очищены")
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

@app.route('/health', methods=['GET'])
def health():
    """Healthcheck endpoint для мониторинга"""
    return jsonify({
        'status': 'ok',
        'web_enabled': WEB_ENABLED,
        'queue_size': len(queue),
        'events_count': len(events),
        'telegram_configured': bool(TOKEN),
        'uptime': 'running'
    })

# ============================================================
# Запуск
# ============================================================

if __name__ == '__main__':
    print("=" * 60)
    print("🚀 SornMonitor Collector v2.0")
    print("=" * 60)
    
    if not WEB_ENABLED:
        print("🌐 Веб-морда ОТКЛЮЧЕНА (только /webhook работает)")
    else:
        print(f"🌐 Веб-морда: http://{args.host}:{args.port}")
    
    print(f"📡 Webhook: http://{args.host}:{args.port}/webhook")
    print(f"📊 Загружено {len(events)} событий")
    print(f"📨 Очередь: {len(queue)}")
    print(f"🤖 Telegram бот: {'✅' if TOKEN else '❌'}")
    print(f"👤 Логин: {ADMIN_LOGIN}")
    
    if TOTP_SECRET:
        print(f"🔐 2FA секрет: {TOTP_SECRET}")
    else:
        print("⚠️  2FA отключена")
    
    print(f"🌐 Белый список: {', '.join(ALLOWED_IPS)}")
    print("=" * 60)
    print("📡 Ожидание событий...")
    print("")
    
    # Всегда запускаем Flask, чтобы webhook работал
    try:
        app.run(host=args.host, port=args.port, debug=False)
    except Exception as e:
        logger.error(f"🔥 Критическая ошибка Flask: {e}")
        error_logger.error(traceback.format_exc())
        print(f"🔥 Критическая ошибка: {e}")
