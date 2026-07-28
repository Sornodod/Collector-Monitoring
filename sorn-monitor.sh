#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Конфигурация
CONFIG_DIR="$HOME/.config/sornmonitor"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_NAME="sornmonitor"
COLLECTOR_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWED_IPS_FILE="$COLLECTOR_DIR/allowed_ips.json"
SECRET_FILE="$COLLECTOR_DIR/2fa_secret.json"
VENV_PYTHON="$COLLECTOR_DIR/.venv/bin/python3"

# Определяем Python с поддержкой pyotp
if [ -f "$VENV_PYTHON" ]; then
    PYTHON_CMD="$VENV_PYTHON"
else
    PYTHON_CMD="python3"
fi

# Функции для вывода
print_header() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         📊 SornMonitor Collector Manager            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_separator() {
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
}

# Проверка прав
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "Некоторые функции требуют прав root"
        print_info "Используйте: sudo sorn-monitor"
        return 1
    fi
    return 0
}

# Загрузка конфига
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        TELEGRAM_TOKEN=$(jq -r '.telegram_token' "$CONFIG_FILE" 2>/dev/null)
        CHAT_ID=$(jq -r '.chat_id' "$CONFIG_FILE" 2>/dev/null)
        BROADCAST_MODE=$(jq -r '.broadcast_mode' "$CONFIG_FILE" 2>/dev/null)
        WEB_HOST=$(jq -r '.web_host' "$CONFIG_FILE" 2>/dev/null)
        WEB_PORT=$(jq -r '.web_port' "$CONFIG_FILE" 2>/dev/null)
        ADMIN_LOGIN=$(jq -r '.admin_login' "$CONFIG_FILE" 2>/dev/null)
        ADMIN_PASSWORD=$(jq -r '.admin_password' "$CONFIG_FILE" 2>/dev/null)
        ENABLE_2FA=$(jq -r '.enable_2fa' "$CONFIG_FILE" 2>/dev/null)
        WEB_ENABLED=$(jq -r '.web_enabled // true' "$CONFIG_FILE" 2>/dev/null)
    else
        print_error "Конфиг не найден! Запусти install.sh"
        return 1
    fi
    
    # Загружаем белый список из allowed_ips.json
    if [ -f "$ALLOWED_IPS_FILE" ]; then
        ALLOWED_IPS=$(jq -r '.[]' "$ALLOWED_IPS_FILE" 2>/dev/null)
    fi
    return 0
}

# Сохранение конфига
save_config() {
    cat > "$CONFIG_FILE" << EOF
{
    "telegram_token": "$TELEGRAM_TOKEN",
    "chat_id": $CHAT_ID,
    "broadcast_mode": $BROADCAST_MODE,
    "web_host": "$WEB_HOST",
    "web_port": $WEB_PORT,
    "admin_login": "$ADMIN_LOGIN",
    "admin_password": "$ADMIN_PASSWORD",
    "allowed_ips": $(echo "$ALLOWED_IPS" | jq -R . | jq -s .),
    "enable_2fa": $ENABLE_2FA,
    "web_enabled": $WEB_ENABLED
}
EOF
    print_success "Конфиг сохранен"
}

# ============================================================
# Вспомогательные функции
# ============================================================

restart_service() {
    print_info "Перезапуск сервиса..."
    
    # Останавливаем сервис
    if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
        sudo systemctl stop $SERVICE_NAME
        sleep 1
    fi
    
    # Убиваем все процессы col.py если остались
    sudo pkill -f "python3.*col.py" 2>/dev/null || true
    sudo pkill -f "col.py" 2>/dev/null || true
    sleep 1
    
    # Запускаем сервис заново
    sudo systemctl start $SERVICE_NAME
    sleep 2
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_success "Сервис перезапущен"
        # Показываем загруженный секрет
        sleep 1
        local loaded_secret=$(sudo journalctl -u $SERVICE_NAME -n 20 --no-pager 2>/dev/null | grep "2FA секрет:" | tail -1 | awk '{print $NF}')
        if [ -n "$loaded_secret" ]; then
            print_info "Загруженный секрет: $loaded_secret"
        fi
    else
        print_error "Ошибка перезапуска сервиса!"
        print_info "Проверьте логи: journalctl -u $SERVICE_NAME -f"
    fi
}

# ============================================================
# 1. Управление веб-мордой
# ============================================================

toggle_web_ui() {
    local action=$1
    if [ "$action" = "off" ]; then
        print_info "Отключаем веб-морду полностью..."
        if [ -f "$CONFIG_FILE" ]; then
            jq '.web_enabled = false' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
        WEB_ENABLED="false"
        print_success "Веб-морда полностью отключена"
        restart_service
    elif [ "$action" = "on" ]; then
        print_info "Включаем веб-морду..."
        read -p "Введите IP для доступа (0.0.0.0 - все): " WEB_HOST
        [ -z "$WEB_HOST" ] && WEB_HOST="0.0.0.0"
        jq ".web_host = \"$WEB_HOST\" | .web_enabled = true" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        WEB_ENABLED="true"
        print_success "Веб-морда включена на $WEB_HOST"
        restart_service
    elif [ "$action" = "local" ]; then
        print_info "Ограничиваем веб-морду локальным доступом..."
        jq '.web_host = "127.0.0.1" | .web_enabled = true' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        WEB_ENABLED="true"
        WEB_HOST="127.0.0.1"
        print_success "Веб-морда доступна только локально (127.0.0.1)"
        restart_service
    fi
}

# ============================================================
# 2. Обновление с гита
# ============================================================

update_from_git() {
    print_info "Обновление с GitHub..."
    
    # Сохраняем текущий конфиг
    cp "$CONFIG_FILE" /tmp/config_backup.json
    
    # Скачиваем новый col.py
    curl -s -L -o "$COLLECTOR_DIR/col.py.new" https://raw.githubusercontent.com/Sornodod/Collector-Monitoring/main/col.py
    
    if [ $? -ne 0 ] || [ ! -s "$COLLECTOR_DIR/col.py.new" ]; then
        print_error "Не удалось скачать обновление!"
        rm -f "$COLLECTOR_DIR/col.py.new"
        return 1
    fi
    
    # Проверяем синтаксис
    $PYTHON_CMD -m py_compile "$COLLECTOR_DIR/col.py.new" 2>/dev/null
    if [ $? -ne 0 ]; then
        print_error "Ошибка синтаксиса в новой версии!"
        rm -f "$COLLECTOR_DIR/col.py.new"
        return 1
    fi
    
    # Заменяем
    mv "$COLLECTOR_DIR/col.py.new" "$COLLECTOR_DIR/col.py"
    chmod +x "$COLLECTOR_DIR/col.py"
    
    print_success "Обновление применено!"
    restart_service
}

# ============================================================
# 3. Управление 2FA
# ============================================================

toggle_2fa() {
    local action=$1
    if [ "$action" = "on" ]; then
        print_info "Включаем 2FA..."
        jq '.enable_2fa = true' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        print_success "2FA включена"
        
        # Показываем секрет или генерируем новый
        if [ -f "$SECRET_FILE" ]; then
            local secret=$(jq -r '.secret' "$SECRET_FILE" 2>/dev/null)
            if [ -n "$secret" ] && [ "$secret" != "null" ]; then
                echo ""
                echo -e "${YELLOW}🔐 Текущий секрет 2FA:${NC} $secret"
                echo ""
            else
                print_warning "Секрет поврежден! Генерируем новый..."
                regenerate_2fa_secret_force
            fi
        else
            print_warning "Секрет 2FA не найден! Генерируем..."
            regenerate_2fa_secret_force
        fi
        restart_service
    elif [ "$action" = "off" ]; then
        print_info "Отключаем 2FA..."
        jq '.enable_2fa = false' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        print_success "2FA отключена"
        restart_service
    fi
}

# ============================================================
# 7. Показать 2FA секрет
# ============================================================

show_2fa_secret() {
    print_info "2FA секрет:"
    if [ -f "$SECRET_FILE" ]; then
        local secret=$(jq -r '.secret' "$SECRET_FILE" 2>/dev/null)
        if [ -n "$secret" ] && [ "$secret" != "null" ]; then
            echo ""
            echo -e "${YELLOW}🔐 Текущий секрет:${NC} ${GREEN}$secret${NC}"
            echo ""
            echo -e "${YELLOW}📱 Используйте этот секрет в Google Authenticator${NC}"
            echo ""
            
            # Проверяем совпадение с конфигом
            local config_2fa=$(jq -r '.enable_2fa // false' "$CONFIG_FILE" 2>/dev/null)
            if [ "$config_2fa" = "true" ]; then
                echo -e "${GREEN}✅ 2FA включена в конфиге${NC}"
            else
                echo -e "${YELLOW}⚠️  2FA отключена в конфиге. Включи через пункт 5${NC}"
            fi
            
            # Проверяем, загружен ли секрет в сервис
            if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
                local service_secret=$(sudo journalctl -u $SERVICE_NAME -n 20 --no-pager 2>/dev/null | grep "2FA секрет:" | tail -1 | awk '{print $NF}')
                if [ -n "$service_secret" ]; then
                    if [ "$service_secret" = "$secret" ]; then
                        echo -e "${GREEN}✅ Секрет загружен в сервис${NC}"
                    else
                        echo -e "${RED}❌ Секрет в сервисе отличается!${NC}"
                        echo -e "   В сервисе: $service_secret"
                        echo -e "   В файле:  $secret"
                        echo -e "   Перезапусти сервис: systemctl restart $SERVICE_NAME"
                    fi
                else
                    echo -e "${YELLOW}⚠️  Не удалось проверить секрет в логах (сервис не показывает секрет)${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  Сервис не запущен${NC}"
            fi
        else
            print_error "Секрет поврежден или пуст!"
        fi
    else
        print_warning "Секрет 2FA не найден"
        print_info "Секрет будет сгенерирован при первом запуске с включенной 2FA"
        echo ""
        read -p "Сгенерировать секрет сейчас? (y/n): " gen_now
        if [[ "$gen_now" =~ ^[Yy]$ ]]; then
            regenerate_2fa_secret_force
        fi
    fi
    echo ""
    read -p "Нажмите Enter для продолжения"
}

# ============================================================
# 8. Сгенерировать новый 2FA секрет (с подтверждением)
# ============================================================

regenerate_2fa_secret() {
    print_warning "Генерация нового секрета 2FA!"
    read -p "Вы уверены? Текущий секрет перестанет работать! (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Отмена"
        return
    fi
    regenerate_2fa_secret_force
}

# ============================================================
# 8b. Принудительная генерация 2FA секрета (без подтверждения)
# ============================================================

regenerate_2fa_secret_force() {
    # Определяем Python с pyotp
    local PYTHON_CMD="python3"
    if [ -f "$COLLECTOR_DIR/.venv/bin/python3" ]; then
        PYTHON_CMD="$COLLECTOR_DIR/.venv/bin/python3"
        print_info "Используем Python из venv: $PYTHON_CMD"
    fi
    
    # Проверяем, установлен ли pyotp
    if ! $PYTHON_CMD -c "import pyotp" 2>/dev/null; then
        print_error "pyotp не установлен! Установи:"
        echo "  cd $COLLECTOR_DIR"
        echo "  source .venv/bin/activate"
        echo "  pip install pyotp"
        return 1
    fi
    
    # Генерируем новый секрет через Python
    local new_secret=$($PYTHON_CMD -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null)
    if [ -z "$new_secret" ]; then
        print_error "Не удалось сгенерировать секрет!"
        return 1
    fi
    
    # Сохраняем новый секрет в файл
    cat > "$SECRET_FILE" << EOF
{"secret": "$new_secret"}
EOF
    chmod 600 "$SECRET_FILE"
    
    print_success "Новый секрет сгенерирован!"
    echo ""
    echo -e "${YELLOW}🔐 НОВЫЙ СЕКРЕТ:${NC} ${GREEN}$new_secret${NC}"
    echo ""
    echo -e "${YELLOW}📱 Добавьте этот секрет в Google Authenticator${NC}"
    echo -e "${YELLOW}⚠️  Старый секрет больше не работает!${NC}"
    echo ""
    
    # Проверяем, что секрет записался
    local saved_secret=$(jq -r '.secret' "$SECRET_FILE" 2>/dev/null)
    if [ "$saved_secret" != "$new_secret" ]; then
        print_error "Ошибка сохранения секрета!"
        return 1
    fi
    
    print_success "Секрет сохранен в $SECRET_FILE"
    
    # Проверяем, включена ли 2FA в конфиге
    local current_2fa=$(jq -r '.enable_2fa // false' "$CONFIG_FILE" 2>/dev/null)
    if [ "$current_2fa" = "false" ]; then
        print_warning "2FA в конфиге отключена!"
        read -p "Включить 2FA сейчас? (y/n): " enable_now
        if [[ "$enable_now" =~ ^[Yy]$ ]]; then
            jq '.enable_2fa = true' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            print_success "2FA включена в конфиге"
        fi
    fi
    
    # ПРИНУДИТЕЛЬНЫЙ ПЕРЕЗАПУСК СЕРВИСА
    print_info "Перезапускаем сервис для применения нового секрета..."
    
    # Останавливаем сервис
    if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
        sudo systemctl stop $SERVICE_NAME
        sleep 1
    fi
    
    # Убиваем все процессы col.py если остались
    sudo pkill -f "python3.*col.py" 2>/dev/null || true
    sudo pkill -f "col.py" 2>/dev/null || true
    sleep 1
    
    # Запускаем сервис заново
    sudo systemctl start $SERVICE_NAME
    sleep 2
    
    # Проверяем что сервис запустился
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_success "Сервис перезапущен"
    else
        print_error "Сервис не запустился!"
        print_info "Проверьте логи: journalctl -u $SERVICE_NAME -f"
        return 1
    fi
    
    # ПРОВЕРКА: смотрим что секрет загрузился в логах
    sleep 1
    print_info "Проверяем, что новый секрет загрузился..."
    
    local service_secret=$(sudo journalctl -u $SERVICE_NAME -n 20 --no-pager 2>/dev/null | grep "2FA секрет:" | tail -1 | awk '{print $NF}')
    
    if [ -n "$service_secret" ]; then
        if [ "$service_secret" = "$new_secret" ]; then
            print_success "✅ Новый секрет успешно загружен в сервис!"
            echo ""
            echo -e "${GREEN}Теперь используйте новый секрет в Google Authenticator${NC}"
            echo -e "${YELLOW}Секрет: $new_secret${NC}"
        else
            print_warning "⚠️ В логах другой секрет: $service_secret"
            print_info "Ожидалось: $new_secret"
            echo ""
            echo -e "${YELLOW}Попробуйте перезапустить вручную:${NC}"
            echo "  sudo systemctl restart $SERVICE_NAME"
            echo "  sudo journalctl -u $SERVICE_NAME -f"
        fi
    else
        print_warning "Не удалось найти секрет в логах"
        print_info "Проверьте логи: journalctl -u $SERVICE_NAME -f | grep '2FA секрет'"
        echo ""
        print_info "Секрет сохранен в файле: $SECRET_FILE"
        echo -e "${YELLOW}Секрет: $new_secret${NC}"
        echo -e "${YELLOW}Попробуйте войти с этим секретом${NC}"
    fi
    
    return 0
}

# ============================================================
# 9. Смена логина
# ============================================================

change_login() {
    print_info "Смена логина"
    read -p "Введите новый логин (сейчас: $ADMIN_LOGIN): " NEW_LOGIN
    [ -z "$NEW_LOGIN" ] && { print_warning "Отмена"; return; }
    jq ".admin_login = \"$NEW_LOGIN\"" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    ADMIN_LOGIN="$NEW_LOGIN"
    print_success "Логин изменен на: $ADMIN_LOGIN"
    restart_service
}

# ============================================================
# 10. Смена пароля
# ============================================================

change_password() {
    print_info "Смена пароля"
    read -sp "Введите новый пароль: " NEW_PASS
    echo ""
    read -sp "Повторите пароль: " NEW_PASS2
    echo ""
    if [ "$NEW_PASS" != "$NEW_PASS2" ]; then
        print_error "Пароли не совпадают!"
        return
    fi
    [ -z "$NEW_PASS" ] && { print_warning "Отмена"; return; }
    jq ".admin_password = \"$NEW_PASS\"" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    ADMIN_PASSWORD="$NEW_PASS"
    print_success "Пароль изменен"
    restart_service
}

# ============================================================
# 11. Управление белым списком IP
# ============================================================

show_ips() {
    print_info "Белый список IP:"
    echo ""
    if [ -f "$ALLOWED_IPS_FILE" ]; then
        local i=1
        while read -r ip; do
            echo "  $i) $ip"
            ((i++))
        done < <(jq -r '.[]' "$ALLOWED_IPS_FILE" 2>/dev/null)
    else
        print_warning "Файл allowed_ips.json не найден"
    fi
    echo ""
}

add_ip() {
    show_ips
    read -p "Введите IP для добавления: " NEW_IP
    [ -z "$NEW_IP" ] && { print_warning "Отмена"; return; }
    
    # Проверка формата
    if [[ ! "$NEW_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_error "Неверный формат IP"
        return
    fi
    
    # Проверяем дубликат
    if [ -f "$ALLOWED_IPS_FILE" ] && jq -e "index(\"$NEW_IP\")" "$ALLOWED_IPS_FILE" > /dev/null 2>&1; then
        print_error "IP уже в списке"
        return
    fi
    
    # Добавляем в allowed_ips.json
    if [ -f "$ALLOWED_IPS_FILE" ]; then
        jq ". += [\"$NEW_IP\"]" "$ALLOWED_IPS_FILE" > "$ALLOWED_IPS_FILE.tmp" && mv "$ALLOWED_IPS_FILE.tmp" "$ALLOWED_IPS_FILE"
    else
        echo "[\"$NEW_IP\"]" > "$ALLOWED_IPS_FILE"
    fi
    print_success "IP $NEW_IP добавлен"
    restart_service
}

remove_ip() {
    show_ips
    read -p "Введите номер IP для удаления: " IP_NUM
    [ -z "$IP_NUM" ] && { print_warning "Отмена"; return; }
    
    if [ ! -f "$ALLOWED_IPS_FILE" ]; then
        print_error "Файл allowed_ips.json не найден"
        return
    fi
    
    local total=$(jq '. | length' "$ALLOWED_IPS_FILE" 2>/dev/null)
    if [ "$IP_NUM" -lt 1 ] || [ "$IP_NUM" -gt "$total" ]; then
        print_error "Неверный номер"
        return
    fi
    
    if [ "$total" -eq 1 ]; then
        print_error "Нельзя удалить последний IP!"
        return
    fi
    
    jq "del(.[$((IP_NUM-1))])" "$ALLOWED_IPS_FILE" > "$ALLOWED_IPS_FILE.tmp" && mv "$ALLOWED_IPS_FILE.tmp" "$ALLOWED_IPS_FILE"
    print_success "IP удален"
    restart_service
}

manage_ips() {
    while true; do
        clear
        print_header
        echo ""
        show_ips
        echo ""
        echo "  1) Добавить IP"
        echo "  2) Удалить IP"
        echo "  3) Назад"
        echo ""
        read -p "Выберите (1-3): " IP_CHOICE
        
        case $IP_CHOICE in
            1) add_ip ;;
            2) remove_ip ;;
            3) break ;;
            *) print_error "Неверный выбор" ;;
        esac
        sleep 1
    done
}

# ============================================================
# 12. Показать логи
# ============================================================

show_logs() {
    print_info "Последние 50 строк логов:"
    echo ""
    sudo journalctl -u $SERVICE_NAME -n 50 --no-pager
    echo ""
    read -p "Нажмите Enter для продолжения"
}

# ============================================================
# 13. Отправить логи в Telegram
# ============================================================

send_logs_to_telegram() {
    print_info "Отправка логов в Telegram..."
    
    local logs=$(sudo journalctl -u $SERVICE_NAME -n 20 --no-pager)
    local message="#SornMonitor_Логи 📋\n\n\`\`\`\n$logs\n\`\`\`"
    
    if [ -n "$TELEGRAM_TOKEN" ] && [ "$CHAT_ID" != "0" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=MarkdownV2" > /dev/null
        print_success "Логи отправлены в Telegram"
    else
        print_error "Telegram не настроен"
    fi
}

# ============================================================
# 14. Логирование попыток авторизации
# ============================================================

setup_auth_logging() {
    print_info "Настройка логирования попыток авторизации..."
    
    AUTH_LOG="$COLLECTOR_DIR/auth_attempts.log"
    touch "$AUTH_LOG"
    chmod 600 "$AUTH_LOG"
    
    print_success "Логирование настроено: $AUTH_LOG"
    
    if [ -f "$AUTH_LOG" ]; then
        echo ""
        echo -e "${YELLOW}Последние попытки авторизации:${NC}"
        tail -n 10 "$AUTH_LOG" 2>/dev/null || echo "Нет данных"
    fi
    echo ""
    read -p "Нажмите Enter для продолжения"
}

# ============================================================
# 15. Настройка ротации логов
# ============================================================

setup_log_rotation() {
    print_info "Настройка ротации логов..."
    
    LOGROTATE_CONF="/etc/logrotate.d/sornmonitor"
    
    sudo bash -c "cat > $LOGROTATE_CONF << EOF
$COLLECTOR_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl reload $SERVICE_NAME > /dev/null 2>&1 || true
    endscript
}

/var/log/journal/* {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl kill -s USR1 systemd-journald > /dev/null 2>&1 || true
    endscript
}
EOF"
    
    if [ $? -eq 0 ]; then
        print_success "Ротация логов настроена (конфиг: $LOGROTATE_CONF)"
        print_info "Логи будут ротироваться ежедневно, храниться 7 дней"
    else
        print_error "Не удалось настроить ротацию логов"
    fi
}

# ============================================================
# 16. Проверка порта
# ============================================================

check_port() {
    print_info "Проверка занятых портов..."
    echo ""
    echo -e "${YELLOW}Порты, используемые коллектором:${NC}"
    ss -tlnp | grep -E ":${WEB_PORT:-5000}|python" | while read line; do
        echo "  $line"
    done
    
    if ss -tlnp | grep -q ":${WEB_PORT:-5000}"; then
        echo ""
        print_warning "Порт ${WEB_PORT:-5000} занят!"
        echo ""
        echo "Для освобождения порта выполните:"
        echo "  sudo fuser -k ${WEB_PORT:-5000}/tcp"
        echo "  # Или"
        echo "  sudo systemctl restart $SERVICE_NAME"
    else
        print_success "Порт ${WEB_PORT:-5000} свободен"
    fi
    echo ""
    read -p "Нажмите Enter для продолжения"
}

# ============================================================
# 17. Статус системы
# ============================================================

show_status() {
    clear
    print_header
    echo ""
    
    # Загружаем конфиг
    load_config 2>/dev/null
    
    # Статус сервиса
    echo -e "${YELLOW}📊 СТАТУС СЕРВИСА${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "   Статус: ${GREEN}✅ РАБОТАЕТ${NC}"
        echo -e "   PID: $(systemctl show -p MainPID $SERVICE_NAME | cut -d= -f2)"
        echo -e "   Память: $(systemctl show -p MemoryCurrent $SERVICE_NAME | cut -d= -f2 | numfmt --to=iec 2>/dev/null || echo "N/A")"
    else
        echo -e "   Статус: ${RED}❌ НЕ РАБОТАЕТ${NC}"
    fi
    echo ""
    
    # Конфигурация
    echo -e "${YELLOW}⚙️ КОНФИГУРАЦИЯ${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    echo -e "   Telegram бот: ${GREEN}${TELEGRAM_TOKEN:0:10}...${NC}"
    echo -e "   Режим: ${GREEN}$([ "$BROADCAST_MODE" = "true" ] && echo "BROADCAST" || echo "PRIVATE")${NC}"
    echo -e "   Веб-морда: ${GREEN}$([ "$WEB_ENABLED" != "false" ] && echo "http://$WEB_HOST:$WEB_PORT" || echo "ОТКЛЮЧЕНА")${NC}"
    echo -e "   Логин: ${GREEN}$ADMIN_LOGIN${NC}"
    echo -e "   2FA: ${GREEN}$([ "$ENABLE_2FA" = "true" ] && echo "ВКЛ" || echo "ВЫКЛ")${NC}"
    if [ -f "$SECRET_FILE" ] && [ "$ENABLE_2FA" = "true" ]; then
        local secret=$(jq -r '.secret' "$SECRET_FILE" 2>/dev/null)
        if [ -n "$secret" ] && [ "$secret" != "null" ]; then
            echo -e "   2FA секрет: ${YELLOW}$secret${NC}"
        else
            echo -e "   2FA секрет: ${RED}ПОВРЕЖДЕН${NC}"
        fi
    fi
    echo ""
    
    # Белый список IP
    echo -e "${YELLOW}🔒 БЕЛЫЙ СПИСОК IP${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    if [ -f "$ALLOWED_IPS_FILE" ]; then
        while read -r ip; do
            echo -e "   ${GREEN}•${NC} $ip"
        done < <(jq -r '.[]' "$ALLOWED_IPS_FILE" 2>/dev/null)
    else
        echo -e "   ${YELLOW}Нет данных${NC}"
    fi
    echo ""
    
    # Статистика событий
    echo -e "${YELLOW}📊 СТАТИСТИКА СОБЫТИЙ${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    if [ -f "$COLLECTOR_DIR/events.json" ]; then
        local total=$(jq '. | length' "$COLLECTOR_DIR/events.json" 2>/dev/null)
        local errors=$(jq '[.[] | select(.error == "true")] | length' "$COLLECTOR_DIR/events.json" 2>/dev/null)
        echo -e "   Всего событий: ${GREEN}$total${NC}"
        echo -e "   Ошибок: ${RED}$errors${NC}"
    else
        echo -e "   ${YELLOW}Нет данных${NC}"
    fi
    echo ""
    
    # Очередь
    echo -e "${YELLOW}📨 ОЧЕРЕДЬ${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    if [ "$WEB_ENABLED" != "false" ] && curl -s "http://localhost:${WEB_PORT:-5000}/queue" 2>/dev/null | grep -q "queue_size"; then
        local queue_size=$(curl -s "http://localhost:${WEB_PORT:-5000}/queue" 2>/dev/null | jq -r '.queue_size')
        echo -e "   В очереди: ${GREEN}$queue_size${NC}"
    else
        echo -e "   ${YELLOW}Недоступно (веб-морда отключена)${NC}"
    fi
    echo ""
    
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    read -p "Нажмите Enter для продолжения"
}

# ============================================================
# Главное меню
# ============================================================

show_menu() {
    clear
    print_header
    echo ""
    echo -e "${YELLOW}📋 УПРАВЛЕНИЕ КОЛЛЕКТОРОМ${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  1)  Отключить веб-морду полностью"
    echo "  2)  Включить веб-морду"
    echo "  3)  Ограничить веб-морду локальным доступом"
    echo "  4)  Обновить с GitHub"
    echo "  5)  Включить 2FA"
    echo "  6)  Отключить 2FA"
    echo "  7)  Показать 2FA секрет"
    echo "  8)  Сгенерировать новый 2FA секрет"
    echo "  9)  Сменить логин"
    echo " 10)  Сменить пароль"
    echo " 11)  Управление белым списком IP"
    echo " 12)  Показать логи"
    echo " 13)  Отправить логи в Telegram"
    echo " 14)  Логирование попыток авторизации"
    echo " 15)  Настройка ротации логов"
    echo " 16)  Проверка занятых портов"
    echo " 17)  Показать статус системы"
    echo "  0)  Выход"
    echo ""
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}📊 Текущий статус:${NC} $(systemctl is-active $SERVICE_NAME 2>/dev/null || echo "unknown")"
    echo -e "${YELLOW}🌐 Веб-морда:${NC} $([ "$WEB_ENABLED" != "false" ] && echo "http://$WEB_HOST:$WEB_PORT" || echo "ОТКЛЮЧЕНА")"
    echo -e "${YELLOW}🔐 2FA:${NC} $([ "$ENABLE_2FA" = "true" ] && echo "ВКЛ" || echo "ВЫКЛ")"
    echo ""
    read -p "Выберите действие (0-17): " CHOICE
}

# ============================================================
# Главная функция
# ============================================================

main() {
    # Проверяем что мы в директории коллектора
    if [ ! -f "$COLLECTOR_DIR/col.py" ] && [ ! -f "$COLLECTOR_DIR/run.sh" ]; then
        print_error "Это не похоже на директорию SornMonitor Collector!"
        print_info "Запустите скрипт из директории с установленным коллектором"
        exit 1
    fi
    
    # Загружаем конфиг
    if ! load_config; then
        print_info "Запусти install.sh для установки"
        exit 1
    fi
    
    while true; do
        show_menu
        
        case $CHOICE in
            1)
                toggle_web_ui off
                ;;
            2)
                toggle_web_ui on
                ;;
            3)
                toggle_web_ui local
                ;;
            4)
                update_from_git
                ;;
            5)
                toggle_2fa on
                ;;
            6)
                toggle_2fa off
                ;;
            7)
                show_2fa_secret
                ;;
            8)
                regenerate_2fa_secret
                ;;
            9)
                change_login
                ;;
            10)
                change_password
                ;;
            11)
                manage_ips
                ;;
            12)
                show_logs
                ;;
            13)
                send_logs_to_telegram
                ;;
            14)
                setup_auth_logging
                ;;
            15)
                setup_log_rotation
                ;;
            16)
                check_port
                ;;
            17)
                show_status
                ;;
            0)
                clear
                print_info "Выход"
                exit 0
                ;;
            *)
                print_error "Неверный выбор!"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# Запуск
# ============================================================

# Проверка наличия jq
if ! command -v jq &> /dev/null; then
    print_warning "jq не установлен! Устанавливаем..."
    apt-get update > /dev/null 2>&1
    apt-get install -y jq > /dev/null 2>&1
fi

main
