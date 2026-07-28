#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         📊 Установка SornMonitor Collector           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Проверка Python
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}❌ Python3 не найден! Установи: sudo apt install python3 python3-venv python3-pip${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Python3 найден ($(python3 --version))${NC}"

# Проверка pip
if ! command -v pip3 &> /dev/null; then
    echo -e "${RED}❌ pip3 не найден! Установи: sudo apt install python3-pip${NC}"
    exit 1
fi
echo -e "${GREEN}✅ pip3 найден${NC}"

# Проверка curl
if ! command -v curl &> /dev/null; then
    echo -e "${RED}❌ curl не найден! Установи: sudo apt install curl${NC}"
    exit 1
fi
echo -e "${GREEN}✅ curl найден${NC}"

# Выбор способа установки
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}📦 Выбери способ установки зависимостей${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "   ${GREEN}1${NC}) В виртуальное окружение (venv) - рекомендуется"
echo -e "   ${GREEN}2${NC}) Глобально (system-wide) - для Debian/Ubuntu где venv сломан"
echo -e "   ${GREEN}3${NC}) Пропустить (установлю зависимости вручную позже)"
echo ""
read -p "Выбери (1, 2 или 3): " INSTALL_MODE

# Функция для установки python3-venv
install_venv_package() {
    echo -e "${YELLOW}🔍 Проверяем python3-venv...${NC}"
    
    # Проверяем, установлен ли python3-venv
    if python3 -c "import venv" &> /dev/null; then
        echo -e "${GREEN}✅ python3-venv уже установлен${NC}"
        return 0
    fi
    
    # Определяем версию Python
    PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    VENV_PACKAGE="python${PYTHON_VERSION}-venv"
    
    echo -e "${YELLOW}⚠️  python3-venv не установлен. Устанавливаем ${VENV_PACKAGE}...${NC}"
    
    # Проверяем, есть ли apt
    if ! command -v apt &> /dev/null; then
        echo -e "${RED}❌ apt не найден. Установи ${VENV_PACKAGE} вручную${NC}"
        return 1
    fi
    
    # Обновляем список пакетов
    apt update > /dev/null 2>&1
    
    # Устанавливаем пакет
    apt install -y ${VENV_PACKAGE} > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Не удалось установить ${VENV_PACKAGE}${NC}"
        echo -e "${YELLOW}Попробуй установить вручную: apt install ${VENV_PACKAGE}${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ ${VENV_PACKAGE} установлен${NC}"
    return 0
}

# Функция для установки в venv
install_venv() {
    echo -e "${YELLOW}📦 Создаем виртуальное окружение...${NC}"
    
    # Устанавливаем python3-venv если нужно
    install_venv_package
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Удаляем старый venv
    if [ -d ".venv" ]; then
        echo -e "${YELLOW}⚠️  Виртуальное окружение уже существует. Удаляем...${NC}"
        rm -rf .venv
    fi
    
    # Создаем venv
    python3 -m venv .venv 2>&1
    if [ $? -ne 0 ] || [ ! -f ".venv/bin/activate" ]; then
        echo -e "${RED}❌ Не удалось создать виртуальное окружение!${NC}"
        return 1
    fi
    
    source .venv/bin/activate
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Не удалось активировать виртуальное окружение!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Виртуальное окружение создано${NC}"
    
    # Установка зависимостей
    echo -e "${YELLOW}📦 Устанавливаем зависимости в venv...${NC}"
    pip install --upgrade pip > /dev/null 2>&1
    pip install flask pyotp requests > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Ошибка установки зависимостей!${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Зависимости установлены${NC}"
    
    # Создаем run.sh для venv
    cat > run.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
source .venv/bin/activate
python3 col.py "$@"
EOF
    
    chmod +x run.sh
    echo -e "${GREEN}✅ Создан скрипт запуска: ./run.sh (с venv)${NC}"
    
    return 0
}

# Функция для глобальной установки
install_global() {
    echo -e "${YELLOW}📦 Устанавливаем зависимости глобально...${NC}"
    
    if ! command -v pip3 &> /dev/null; then
        echo -e "${RED}❌ pip3 не найден!${NC}"
        return 1
    fi
    
    # Пробуем установить с флагом --break-system-packages (Debian 12+)
    pip3 install --upgrade pip --break-system-packages > /dev/null 2>&1
    pip3 install flask pyotp requests --break-system-packages > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        # Если не получилось с флагом, пробуем без (старые системы)
        pip3 install --upgrade pip > /dev/null 2>&1
        pip3 install flask pyotp requests > /dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Ошибка установки зависимостей!${NC}"
            echo -e "${YELLOW}Попробуй: apt install python3-flask python3-pyotp python3-requests${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}✅ Зависимости установлены глобально${NC}"
    
    # Создаем run.sh для глобальной установки
    cat > run.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
python3 col.py "$@"
EOF
    
    chmod +x run.sh
    echo -e "${GREEN}✅ Создан скрипт запуска: ./run.sh (глобально)${NC}"
    
    return 0
}

# Скачиваем col.py с GitHub
echo -e "${YELLOW}📥 Скачиваем col.py с GitHub...${NC}"
curl -s -L -o col.py https://raw.githubusercontent.com/Sornodod/Collector-Monitoring/main/col.py

if [ $? -ne 0 ] || [ ! -s "col.py" ]; then
    echo -e "${RED}❌ Не удалось скачать col.py!${NC}"
    echo -e "${YELLOW}Проверь интернет и доступ к GitHub${NC}"
    exit 1
fi
echo -e "${GREEN}✅ col.py скачан (размер: $(du -h col.py | cut -f1))${NC}"

# Выполняем установку в зависимости от выбора
case $INSTALL_MODE in
    1)
        install_venv
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Ошибка установки в venv!${NC}"
            echo -e "${YELLOW}Попробуй режим 2 (глобальная установка) или 3 (ручная)${NC}"
            exit 1
        fi
        ;;
    2)
        install_global
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Ошибка глобальной установки!${NC}"
            exit 1
        fi
        ;;
    3)
        echo -e "${YELLOW}⚠️  Пропускаем установку зависимостей${NC}"
        echo -e "${YELLOW}Не забудь установить позже: pip install flask pyotp requests${NC}"
        
        cat > run.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
python3 col.py "$@"
EOF
        chmod +x run.sh
        echo -e "${GREEN}✅ Создан скрипт запуска: ./run.sh${NC}"
        ;;
    *)
        echo -e "${RED}❌ Неверный выбор!${NC}"
        exit 1
        ;;
esac

# Создаем директорию для конфигов
CONFIG_DIR="$HOME/.config/sornmonitor"
mkdir -p $CONFIG_DIR

# Запрос токена Telegram
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🤖 Настройка Telegram бота${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
while true; do
    echo -e "${YELLOW}Введите токен Telegram бота:${NC}"
    read -p "> " TELEGRAM_TOKEN
    if [ -z "$TELEGRAM_TOKEN" ]; then
        echo -e "${RED}❌ Токен не может быть пустым!${NC}"
    else
        break
    fi
done

# Режим отправки
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}📨 Режим отправки сообщений${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Выбери режим:${NC}"
echo -e "   ${GREEN}1${NC}) Всем подписчикам (broadcast) - бот шлет всем кто написал /start"
echo -e "   ${GREEN}2${NC}) В конкретный чат - только в один указанный чат"
echo ""
read -p "Выбери (1 или 2): " CHAT_MODE

if [ "$CHAT_MODE" = "2" ]; then
    echo ""
    echo -e "${YELLOW}Введите Chat ID (можно узнать через @userinfobot):${NC}"
    read -p "> " CHAT_ID
    if [ -z "$CHAT_ID" ]; then
        echo -e "${RED}❌ Chat ID не может быть пустым!${NC}"
        exit 1
    fi
    BROADCAST_MODE="false"
    echo -e "${GREEN}✅ Будет отправлять только в чат: $CHAT_ID${NC}"
else
    CHAT_ID="0"
    BROADCAST_MODE="true"
    echo -e "${GREEN}✅ Будет отправлять всем подписчикам (broadcast)${NC}"
    echo -e "${YELLOW}⚠️  Пользователи должны написать /start боту чтобы получать сообщения${NC}"
fi

# Запрос IP для веб-морды
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🌐 Настройка доступа к веб-морде${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Введите IP с которого можно открывать веб-морду${NC}"
echo -e "${YELLOW}Оставь пустым для доступа с любого адреса (0.0.0.0)${NC}"
echo -e "${YELLOW}Пример: 192.168.1.100 или 127.0.0.1${NC}"
read -p "> " WEB_HOST

if [ -z "$WEB_HOST" ]; then
    WEB_HOST="0.0.0.0"
    echo -e "${GREEN}✅ Веб-морда будет доступна с любого адреса${NC}"
else
    echo -e "${GREEN}✅ Веб-морда будет доступна только с IP: $WEB_HOST${NC}"
fi

# Запрос порта
echo ""
echo -e "${YELLOW}Введите порт для веб-морды (по умолчанию 5000):${NC}"
read -p "> " WEB_PORT
if [ -z "$WEB_PORT" ]; then
    WEB_PORT="5000"
fi
echo -e "${GREEN}✅ Порт: $WEB_PORT${NC}"

# Запрос логина и пароля для админки
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🔐 Настройка авторизации${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Введите логин для админки (по умолчанию admin):${NC}"
read -p "> " ADMIN_LOGIN
if [ -z "$ADMIN_LOGIN" ]; then
    ADMIN_LOGIN="admin"
    echo -e "${YELLOW}⚠️  Логин по умолчанию: admin${NC}"
else
    echo -e "${GREEN}✅ Логин: $ADMIN_LOGIN${NC}"
fi

echo -e "${YELLOW}Введите пароль для админки:${NC}"
echo -e "${YELLOW}Оставь пустым для пароля по умолчанию (admin123)${NC}"
read -p "> " ADMIN_PASSWORD
if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="admin123"
    echo -e "${YELLOW}⚠️  Пароль по умолчанию: admin123${NC}"
else
    echo -e "${GREEN}✅ Пароль установлен${NC}"
fi

# Вопрос про 2FA
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🔐 Настройка двухфакторной авторизации (2FA)${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Включить 2FA? (y/n)${NC}"
echo -e "${YELLOW}Рекомендуется включить для продакшена${NC}"
read -p "> " ENABLE_2FA

if [[ "$ENABLE_2FA" =~ ^[Yy]$ ]]; then
    ENABLE_2FA="true"
    echo -e "${GREEN}✅ 2FA включена${NC}"
else
    ENABLE_2FA="false"
    echo -e "${YELLOW}⚠️  2FA отключена${NC}"
fi

# Запрос добавления IP в белый список
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🔒 Белый список IP для отправки событий${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Добавить IP сервера для отправки событий?${NC}"
echo -e "${YELLOW}Можно добавить несколько, через запятую${NC}"
echo -e "${YELLOW}Пример: 192.168.1.10,192.168.1.20,10.0.0.5${NC}"
echo -e "${YELLOW}Оставь пустым чтобы добавить только 127.0.0.1${NC}"
read -p "> " ALLOWED_IPS_INPUT

# Формируем список IP
if [ -z "$ALLOWED_IPS_INPUT" ]; then
    ALLOWED_IPS='["127.0.0.1"]'
else
    IFS=',' read -ra IP_ARRAY <<< "$ALLOWED_IPS_INPUT"
    ALLOWED_IPS='['
    for i in "${!IP_ARRAY[@]}"; do
        ip=$(echo "${IP_ARRAY[$i]}" | xargs)
        if [ -n "$ip" ]; then
            ALLOWED_IPS+="\"$ip\""
            if [ $i -lt $((${#IP_ARRAY[@]} - 1)) ]; then
                ALLOWED_IPS+=","
            fi
        fi
    done
    ALLOWED_IPS+=']'
    if [ "$ALLOWED_IPS" = "[]" ]; then
        ALLOWED_IPS='["127.0.0.1"]'
    fi
fi
echo -e "${GREEN}✅ Белый список: $ALLOWED_IPS${NC}"

# Создание конфига
echo ""
echo -e "${YELLOW}📝 Сохраняем конфигурацию...${NC}"

cat > $CONFIG_DIR/config.json << EOF
{
    "telegram_token": "$TELEGRAM_TOKEN",
    "chat_id": $CHAT_ID,
    "broadcast_mode": $BROADCAST_MODE,
    "web_host": "$WEB_HOST",
    "web_port": $WEB_PORT,
    "admin_login": "$ADMIN_LOGIN",
    "admin_password": "$ADMIN_PASSWORD",
    "allowed_ips": $ALLOWED_IPS,
    "enable_2fa": $ENABLE_2FA
}
EOF

echo -e "${GREEN}✅ Конфиг сохранен в $CONFIG_DIR/config.json${NC}"

# Создание .env файла
cat > .env << EOF
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
CHAT_ID=$CHAT_ID
BROADCAST_MODE=$BROADCAST_MODE
WEB_HOST=$WEB_HOST
WEB_PORT=$WEB_PORT
ADMIN_LOGIN=$ADMIN_LOGIN
ADMIN_PASSWORD=$ADMIN_PASSWORD
ALLOWED_IPS='$ALLOWED_IPS'
ENABLE_2FA=$ENABLE_2FA
EOF

echo -e "${GREEN}✅ .env файл создан${NC}"

# systemd сервис
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🛠️  Настройка автозапуска (systemd)${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Установить как systemd сервис? (y/n)${NC}"
read -p "> " INSTALL_SERVICE

if [[ "$INSTALL_SERVICE" =~ ^[Yy]$ ]]; then
    SERVICE_NAME="sornmonitor"
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    
    CURRENT_DIR=$(pwd)
    USER_NAME=$(whoami)
    
    # Определяем путь к python
    if [ "$INSTALL_MODE" = "1" ]; then
        PYTHON_PATH="$CURRENT_DIR/.venv/bin/python3"
    else
        PYTHON_PATH="/usr/bin/python3"
    fi
    
    sudo bash -c "cat > $SERVICE_FILE << EOF
[Unit]
Description=SornMonitor Collector
After=network.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$CURRENT_DIR
Environment=\"PATH=$CURRENT_DIR/.venv/bin:/usr/local/bin:/usr/bin:/bin\"
ExecStart=$PYTHON_PATH $CURRENT_DIR/col.py --host $WEB_HOST --port $WEB_PORT
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF"
    
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    echo -e "${GREEN}✅ Сервис установлен${NC}"
    echo -e "${GREEN}✅ Команды:${NC}"
    echo -e "   ${YELLOW}sudo systemctl start $SERVICE_NAME${NC}  - запустить"
    echo -e "   ${YELLOW}sudo systemctl stop $SERVICE_NAME${NC}   - остановить"
    echo -e "   ${YELLOW}sudo systemctl status $SERVICE_NAME${NC} - статус"
    echo -e "   ${YELLOW}sudo journalctl -u $SERVICE_NAME -f${NC} - логи"
fi

# Создание alias
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}⚡ Добавить алиас для быстрого запуска?${NC}"
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Добавить алиас 'sornmonitor' в ~/.bashrc? (y/n)${NC}"
read -p "> " ADD_ALIAS

if [[ "$ADD_ALIAS" =~ ^[Yy]$ ]]; then
    ALIAS_CMD="alias sornmonitor='cd $PWD && ./run.sh'"
    if grep -q "alias sornmonitor=" ~/.bashrc 2>/dev/null; then
        sed -i "s|alias sornmonitor=.*|$ALIAS_CMD|" ~/.bashrc
    else
        echo "$ALIAS_CMD" >> ~/.bashrc
    fi
    
    if [ -f ~/.config/fish/config.fish ]; then
        FISH_ALIAS="alias sornmonitor='cd $PWD; ./run.sh'"
        if grep -q "alias sornmonitor=" ~/.config/fish/config.fish 2>/dev/null; then
            sed -i "s|alias sornmonitor=.*|$FISH_ALIAS|" ~/.config/fish/config.fish
        else
            echo "$FISH_ALIAS" >> ~/.config/fish/config.fish
        fi
    fi
    
    echo -e "${GREEN}✅ Алиас добавлен! Перезагрузи терминал или выполни: source ~/.bashrc${NC}"
    echo -e "${GREEN}✅ Теперь можно запускать просто: sornmonitor${NC}"
fi

# Создание скрипта для отправки событий
cat > send_event.sh << 'EOF'
#!/bin/bash
COLLECTOR="http://localhost:5000/webhook"
SERVER=$(hostname)
MESSAGE="${1:-Тестовое событие}"
ERROR="${2:-false}"

curl -s -X POST $COLLECTOR \
  -H "Content-Type: application/json" \
  -d "{\"server\":\"$SERVER\",\"message\":\"$MESSAGE\",\"error\":\"$ERROR\"}"

if [ $? -eq 0 ]; then
    echo "✅ Событие отправлено"
else
    echo "❌ Ошибка отправки"
fi
EOF

chmod +x send_event.sh
echo -e "${GREEN}✅ Создан скрипт отправки: ./send_event.sh${NC}"

# Финальный вывод
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✅ УСТАНОВКА ЗАВЕРШЕНА!                       ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}📋 Информация:${NC}"
echo -e "   🤖 Telegram бот: ${GREEN}$TELEGRAM_TOKEN${NC}"

if [ "$BROADCAST_MODE" = "true" ]; then
    echo -e "   📨 Режим: ${GREEN}BROADCAST${NC} - всем подписчикам"
else
    echo -e "   📨 Режим: ${GREEN}PRIVATE${NC} - только в один чат"
    echo -e "   📱 Chat ID: ${GREEN}$CHAT_ID${NC}"
fi

echo -e "   🌐 Веб-морда: ${GREEN}http://$WEB_HOST:$WEB_PORT${NC}"
echo -e "   🔐 Логин: ${GREEN}$ADMIN_LOGIN${NC}"
echo -e "   🔐 Пароль: ${GREEN}$ADMIN_PASSWORD${NC}"
echo -e "   🔒 Белый список: ${GREEN}$ALLOWED_IPS${NC}"

case $INSTALL_MODE in
    1)
        echo -e "   📦 Установка: ${GREEN}venv${NC}"
        ;;
    2)
        echo -e "   📦 Установка: ${GREEN}глобальная${NC}"
        ;;
    3)
        echo -e "   📦 Установка: ${YELLOW}пропущена (ручная)${NC}"
        ;;
esac

if [ "$ENABLE_2FA" = "true" ]; then
    echo -e "   🔐 2FA: ${GREEN}Включена${NC}"
else
    echo -e "   ⚠️  2FA: ${RED}ОТКЛЮЧЕНА${NC}"
fi

echo ""
echo -e "${YELLOW}🚀 Запуск:${NC}"
echo -e "   ${GREEN}./run.sh${NC} - вручную"
if [[ "$INSTALL_SERVICE" =~ ^[Yy]$ ]]; then
    echo -e "   ${GREEN}sudo systemctl start $SERVICE_NAME${NC} - как сервис"
fi
if [[ "$ADD_ALIAS" =~ ^[Yy]$ ]]; then
    echo -e "   ${GREEN}sornmonitor${NC} - быстрый запуск"
fi

echo ""
echo -e "${YELLOW}📤 Отправка событий:${NC}"
echo -e "   ${GREEN}./send_event.sh \"CPU 95%\" true${NC} - с ошибкой"
echo -e "   ${GREEN}./send_event.sh \"Все хорошо\" false${NC} - OK"

echo ""
echo -e "${BLUE}⚠️  ВАЖНО:${NC}"
if [ "$BROADCAST_MODE" = "true" ]; then
    echo -e "   - Напиши /start боту, чтобы подписаться на уведомления"
fi
echo -e "   - Смени пароль по умолчанию в админке!"
if [ "$ENABLE_2FA" = "true" ]; then
    echo -e "   - Настрой 2FA в Google Authenticator (секрет в логах)"
fi
echo -e "   - Добавь IP серверов в белый список через веб-морду"
echo ""

# Автоматический запуск и проверка статуса
if [[ "$INSTALL_SERVICE" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}🚀 Запускаем сервис...${NC}"
    sudo systemctl start $SERVICE_NAME
    sleep 2
    
    echo -e "${YELLOW}📊 Статус сервиса:${NC}"
    sudo systemctl status $SERVICE_NAME --no-pager
    
    echo ""
    echo -e "${YELLOW}📋 Последние логи:${NC}"
    sudo journalctl -u $SERVICE_NAME -n 10 --no-pager
fi
