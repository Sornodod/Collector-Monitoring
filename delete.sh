#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║         🗑️  УДАЛЕНИЕ SornMonitor Collector             ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Проверка подтверждения
echo -e "${RED}⚠️  ВНИМАНИЕ! Это действие УДАЛИТ:${NC}"
echo -e "   - Все конфиги (~/.config/sornmonitor/)"
echo -e "   - Все данные (events.json, allowed_ips.json, 2fa_secret.json)"
echo -e "   - Виртуальное окружение (.venv)"
echo -e "   - systemd сервис (если установлен)"
echo -e "   - Алиасы (если добавлены)"
echo ""
echo -e "${YELLOW}Уверен что хочешь удалить? (y/n)${NC}"
read -p "> " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}❌ Отмена. Ничего не удалено.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}⏳ Удаляем...${NC}"

# 1. Остановка и удаление systemd сервиса
SERVICE_NAME="sornmonitor"
if systemctl list-units --full -all | grep -q "$SERVICE_NAME.service"; then
    echo -e "${YELLOW}🛑 Останавливаем сервис...${NC}"
    sudo systemctl stop $SERVICE_NAME 2>/dev/null
    sudo systemctl disable $SERVICE_NAME 2>/dev/null
    
    echo -e "${YELLOW}🗑️  Удаляем сервис...${NC}"
    sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
    sudo systemctl daemon-reload
    echo -e "${GREEN}✅ Сервис удален${NC}"
else
    echo -e "${YELLOW}⚠️  Сервис не найден${NC}"
fi

# 2. Удаление конфигов
echo -e "${YELLOW}🗑️  Удаляем конфиги...${NC}"
CONFIG_DIR="$HOME/.config/sornmonitor"
if [ -d "$CONFIG_DIR" ]; then
    rm -rf $CONFIG_DIR
    echo -e "${GREEN}✅ Конфиги удалены${NC}"
else
    echo -e "${YELLOW}⚠️  Конфиги не найдены${NC}"
fi

# 3. Удаление файлов данных в текущей директории
echo -e "${YELLOW}🗑️  Удаляем файлы данных...${NC}"
FILES_TO_REMOVE=(
    "events.json"
    "allowed_ips.json"
    "2fa_secret.json"
    ".env"
    "col.py"
    "run.sh"
    "send_event.sh"
)

for file in "${FILES_TO_REMOVE[@]}"; do
    if [ -f "$file" ]; then
        rm -f "$file"
        echo -e "   ${GREEN}✅ $file удален${NC}"
    fi
done

# 4. Удаление виртуального окружения
echo -e "${YELLOW}🗑️  Удаляем виртуальное окружение...${NC}"
if [ -d ".venv" ]; then
    rm -rf .venv
    echo -e "${GREEN}✅ .venv удален${NC}"
else
    echo -e "${YELLOW}⚠️  .venv не найден${NC}"
fi

# 5. Удаление алиасов
echo -e "${YELLOW}🗑️  Удаляем алиасы...${NC}"

# Из .bashrc
if [ -f ~/.bashrc ]; then
    if grep -q "alias sornmonitor=" ~/.bashrc; then
        sed -i '/alias sornmonitor=/d' ~/.bashrc
        echo -e "${GREEN}✅ Алиас удален из ~/.bashrc${NC}"
    else
        echo -e "${YELLOW}⚠️  Алиас не найден в ~/.bashrc${NC}"
    fi
fi

# Из .zshrc
if [ -f ~/.zshrc ]; then
    if grep -q "alias sornmonitor=" ~/.zshrc; then
        sed -i '/alias sornmonitor=/d' ~/.zshrc
        echo -e "${GREEN}✅ Алиас удален из ~/.zshrc${NC}"
    else
        echo -e "${YELLOW}⚠️  Алиас не найден в ~/.zshrc${NC}"
    fi
fi

# Из config.fish (Fish shell)
if [ -f ~/.config/fish/config.fish ]; then
    if grep -q "alias sornmonitor=" ~/.config/fish/config.fish; then
        sed -i '/alias sornmonitor=/d' ~/.config/fish/config.fish
        echo -e "${GREEN}✅ Алиас удален из ~/.config/fish/config.fish${NC}"
    else
        echo -e "${YELLOW}⚠️  Алиас не найден в config.fish${NC}"
    fi
fi

# 6. Опционально - удаление всей директории
echo ""
echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}🗑️  Удалить всю директорию SornMonitor?${NC}"
echo -e "${YELLOW}(включая этот скрипт и все файлы в ней) (y/n)${NC}"
read -p "> " REMOVE_DIR

if [[ "$REMOVE_DIR" =~ ^[Yy]$ ]]; then
    CURRENT_DIR=$(pwd)
    cd ..
    echo -e "${YELLOW}🗑️  Удаляем директорию...${NC}"
    rm -rf "$CURRENT_DIR"
    echo -e "${GREEN}✅ Директория удалена${NC}"
    echo -e "${RED}⚠️  Скрипт самоуничтожился! Выход...${NC}"
    exit 0
fi

# Финальный вывод
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✅ УДАЛЕНИЕ ЗАВЕРШЕНО!                         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}📋 Что было удалено:${NC}"
echo -e "   ✅ systemd сервис"
echo -e "   ✅ Конфиги (~/.config/sornmonitor/)"
echo -e "   ✅ Файлы данных (events.json, allowed_ips.json, 2fa_secret.json)"
echo -e "   ✅ Виртуальное окружение (.venv)"
echo -e "   ✅ Алиасы (sornmonitor)"
echo -e "   ✅ Скрипты (run.sh, send_event.sh)"
echo ""
echo -e "${YELLOW}🧹 Чтобы очистить полностью:${NC}"
echo -e "   Удали папку вручную: ${GREEN}rm -rf $(pwd)${NC}"
echo ""
echo -e "${BLUE}💡 Если хочешь переустановить:${NC}"
echo -e "   ${GREEN}git clone ... && cd ... && ./install.sh${NC}"
