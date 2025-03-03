#!/bin/bash

# Импорт переменных из шаблона
EVENT="{{ event_name }}"
SESSION_ID="{{ user.gen_session.id }}"
API_URL="{{ config.api.url }}"

# Remnawave
REMNAWAVE_API="{{ server.settings.remnawave.api }}"
REMNAWAVE_TOKEN="{{ server.settings.remnawave.token }}"


export TZ="Europe/Moscow"
export TOKEN="$REMNAWAVE_TOKEN"

{{ uuid = ( storage.read('name', 'vpn_'_us.id).response.uuid ) || (storage.read('name', 'vpn_mrzb_'_ us.id).response.uuid)  }}


# Логирование
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Проверка доступности API
check_api() {
    local url=$1
    log "Проверка доступности API: $url..."
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$url")
    if [ "$HTTP_CODE" != "200" ]; then
        log "Ошибка: API недоступен. Код ответа: $HTTP_CODE"
        exit 1
    fi
    log "API доступен."
}

# Основной код
log "Запуск скрипта для события: $EVENT"


# Обработка событий
case $EVENT in
    TEST)
# Это нужно исправить
        log "Тестирование подключения к Remnwave..."
        check_api "$REMNAWAVE_API/api/system/stats"
        ;;

    INIT)
        log "Тестирование подключения к SHM..."
        check_api "$API_URL/shm/v1/test"
        ;;

    CREATE)
        log "Создание пользователя..."
        {{ service = service.id(us.service_id) }}
        EXPIRE_DATE=$(date +'%Y-%m-%d %T' --date="{{ us.expire }} UTC - 3 hours + 21 minutes")

        USER_NOTE="{{ user.login }}"

        if [ -z "{{ us.settings.data.username }}" ]; then
            log "Создание нового пользователя (не вручную)..."
            PAYLOAD=$(cat <<-EOF
            {
                "username": "service_{{ us.id }}",
                "status": "ACTIVE",
                "trafficLimitStrategy": "MONTH",
                "expireAt": "$EXPIRE_DATE",
                "description": "$USER_NOTE",
                "activeUserInbounds": {{ toJson(service.settings.remnawave) }}
            }
EOF
            )


            log "Отправка запроса на создание пользователя..."
            log "Payload: $PAYLOAD"
            USER_CFG=$(curl -sk -XPOST \
                "$REMNAWAVE_API/api/users" \
                -H "Authorization: Bearer $TOKEN" \
                -H 'Content-Type: application/json' \
                -d "$PAYLOAD")
            log "Ответ от Remnawave: $USER_CFG"
        else
            log "Обновление конфигурации пользователя (создан вручную)..."
            USER_CFG=$(curl -sk -XGET \
                "$REMNAWAVE_API/api/users/username/{{ us.settings.data.username }}" \
                -H "Authorization: Bearer $TOKEN" \
                -H 'accept: application/json')
            log "Ответ от Remnawave: $USER_CFG"
        fi

        STATUS_CODE=$(echo "$USER_CFG" | jq -r '.statusCode')
        if [ "$STATUS_CODE" == "404" ]; then
            log "Ошибка: Не удалось обновить пользователя. Ответ: $USER_CFG"
            exit 1
        fi

        log "Загрузка конфигурации пользователя в SHM..."
        curl -sk -XPUT \
            -H "session-id: $SESSION_ID" \
            -H "Content-Type: application/json" \
            "$API_URL/shm/v1/storage/manage/vpn_{{ us.id }}" \
            --data-binary "$USER_CFG"
        ;;

    ACTIVATE|BLOCK|PROLONGATE|CHANGED)
        log "Обработка события: $EVENT..."
        EXPIRE_DATE=$(date +'%Y-%m-%d %T' --date="{{ us.expire }} UTC - 3 hours + 21 minutes")
        {{ uuid = ( storage.read('name', 'vpn_'_ us.id).response.uuid ) || (storage.read('name', 'vpn_mrzb_'_ us.id).response.uuid)  }}



        USERNAME="{{ us.settings.data.username }}"

        if [ -z "$USERNAME" ]; then
            USERNAME="service_{{ us.id }}"
        fi

        log "Отправка запроса на обновление $USERNAME..."

        case $EVENT in
            ACTIVATE)

                USER_CFG=$(curl -sk -XPATCH \
                    "$REMNAWAVE_API/api/users/enable/{{uuid}}" \
                    -H "Authorization: Bearer $TOKEN")
                log "Ответ от Remnawave: $USER_CFG"
                PAYLOAD='{"uuid": "{{ uuid }}", "expireAt": "$EXPIRE_DATE", "status": "ACTIVE"}'
        PAYLOAD=$(cat <<-EOF
            {
                "uuid": "{{ uuid }}",
                "expireAt": "$EXPIRE_DATE"
            }
EOF
            )
                log "Payload: $PAYLOAD"
                USER_CFG=$(curl -sk -XPOST \
                    "$REMNAWAVE_API/api/users/update" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H 'Content-Type: application/json' \
                    -d "$PAYLOAD")
                log "Ответ от Remnawave: $USER_CFG"
                ;;
            BLOCK)
                log "Payload: $PAYLOAD"
                USER_CFG=$(curl -sk -XPATCH \
                    "$REMNAWAVE_API/api/users/disable/{{uuid}}" \
                    -H "Authorization: Bearer $TOKEN")
                log "Ответ от Remnawave: $USER_CFG"
                ;;
            PROLONGATE)
                        PAYLOAD=$(cat <<-EOF
                            {
                                "uuid": "{{ uuid }}",
                                "expireAt": "$EXPIRE_DATE"
                            }
EOF
                            )
                log "Payload: $PAYLOAD"
                USER_CFG=$(curl -sk -XPOST \
                    "$REMNAWAVE_API/api/users/update" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H 'Content-Type: application/json' \
                    -d "$PAYLOAD")
                log "Ответ от Remnawave: $USER_CFG"
                ;;
            CHANGED)
                PAYLOAD=$(cat <<-EOF
                    {
                        "uuid": "{{ uuid }}",
                        "expireAt": "$EXPIRE_DATE"
                    }
EOF
                    )
                log "Payload: $PAYLOAD"
                USER_CFG=$(curl -sk -XPOST \
                    "$REMNAWAVE_API/api/users/update" \
                    -H "Authorization: Bearer $TOKEN" \
                    -H 'Content-Type: application/json' \
                    -d "$PAYLOAD")
                log "Ответ от Remnawave: $USER_CFG"
                ;;
        esac


        STATUS_CODE=$(echo "$USER_CFG" | jq -r '.statusCode')
        if [ "$STATUS_CODE" == "404" ]; then
            log "Ошибка: Не удалось обновить пользователя. Ответ: $USER_CFG"
            exit 1
        fi

        log "Обновление конфигурации пользователя в SHM..."
        curl -sk -XPOST \
            -H "session-id: $SESSION_ID" \
            -H "Content-Type: application/json" \
            "$API_URL/shm/v1/storage/manage/vpn_{{ us.id }}" \
            --data-binary "$USER_CFG"
        ;;

    REMOVE)
        log "Удаление пользователя..."
        USERNAME="{{ us.settings.data.username }}"
        {{ uuid = ( storage.read('name', 'vpn_'_ us.id).response.uuid ) || (storage.read('name', 'vpn_mrzb_'_ us.id).response.uuid)  }}

        if [ -z "$USERNAME" ]; then
            USERNAME="service_{{ us.id }}"
        fi

        log "Отправка запроса на удаление пользователя..."
        curl -sk -XDELETE \
            "$REMNAWAVE_API/api/users/delete/{{uuid}}" \
            -H "Authorization: Bearer $TOKEN"

        log "Удаление ключа пользователя из SHM..."
        curl -sk -XDELETE \
            -H "session-id: $SESSION_ID" \
            "$API_URL/shm/v1/storage/manage/vpn_{{ us.id }}"
        ;;

    *)
        log "Неизвестное событие: $EVENT. Продолжаем работу."
        exit 0
        ;;
esac

log "Работа шаблона завершена."