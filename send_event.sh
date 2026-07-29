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
