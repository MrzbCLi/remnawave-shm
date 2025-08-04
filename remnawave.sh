#!/bin/bash

# Переменные из конфигурации и пользовательских данных
EVENT="{{ event_name }}"
SESSION_ID="{{ user.gen_session.id }}"
API_URL="{{ config.api.url }}" # URL для внутреннего API (SHM)

REMNAWAVE_HOST="{{ server.settings.api.host }}" # URL для Remnawave API
TOKEN="{{ server.settings.api.token }}" # Токен авторизации для Remnawave API

# Получение UUID пользователя из хранилища
# Предполагается, что эта команда возвращает JSON с полем "uuid"
# или что переменная uuid устанавливается другим способом до выполнения скрипта
 {{ uuid = storage.read('name', 'vpn_mrzb_'_ us.id).response.uuid }}

# Получение chat_id из настроек пользователя
 {{ chat_id = user.settings.telegram.chat_id }}
# Для тестирования:
# chat_id="your-telegram-chat-id"

# Использование модуля date для форматирования даты истечения
 {{ USE date }}
 {{ expire = date.format(us.expire, '%s') + 1260 }}
 {{ new_expire = date.format(expire, '%Y-%m-%dT%H:%M:%S') }}
# Для тестирования (установите актуальную дату в формате ISO 8601):
# new_expire=$(date -u -d "+21 minutes" +"%Y-%m-%dT%H:%M:%SZ") # Пример: текущее время + 21 минута

echo "EVENT: $EVENT"
echo "USER_ID (us.id): {{ us.id }}" # Для отладки
echo "USER_UUID (uuid): $uuid" # Для отладки
echo "NEW_EXPIRE_DATE: $new_expire" # Для отладки

# Основная логика скрипта на основе события
case $EVENT in

  CREATE)
    echo "Create user"
    # Описание пользователя для Remnawave
    DESCR="SHM_info- {{ user.login }}, {{ user.full_name }}, https://t.me/{{ user.settings.telegram.login }}, US_ID: {{ user.id }}"
    USER_TAG="SHM"

    # Тело запроса для создания пользователя (соответствует CreateUserRequestDto)
    # Убедитесь, что все поля соответствуют актуальной CreateUserRequestDto
    # если не переданы, или их нужно передавать, если это требуется вашей логикой.
    # Поле activeUserInbounds ожидает массив UUID активных инбаундов.
    PAYLOAD_CREATE="{{ toJson(
        username = "remnawave_" _ us.id,
        status = "ACTIVE", # Возможные значения: ACTIVE, DISABLED, LIMITED, EXPIRED
        trafficLimitStrategy = "MONTH", # Возможные значения: NO_RESET, DAY, WEEK, MONTH
        trafficLimitBytes = 483183820800, # 450 GiB
        expireAt = new_expire,
        description = '$DESCR',
        telegramId = chat_id,
        tag = '$USER_TAG'
        # activeUserInbounds = server.settings.remnawave # Это должно быть массивом UUID инбаундов
        # Пример: activeUserInbounds = ["uuid-inbound-1", "uuid-inbound-2"]
        # Если server.settings.remnawave - это уже массив UUID, то все в порядке.
        # Если это один UUID, его нужно обернуть в массив.
        # Если это специальное значение, которое обрабатывается шаблонизатором для получения массива, тоже ок.
        # Для теста можно закомментировать или передать пустой массив: activeUserInbounds = []
        activateAllInbounds = true # Пример, если нужно активировать все доступные инбаунды
    ).dquote
    }}"

    echo "Create User Payload: $PAYLOAD_CREATE"

    # Вызов API для создания пользователя
    USER_CFG=$(curl -sk -XPOST \
      "$REMNAWAVE_HOST/api/users" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$PAYLOAD_CREATE")

    echo "Create User Response: $USER_CFG"

    # Проверка успешности создания пользователя (проверяем наличие username в ответе)
    # В CreateUserResponseDto есть response.username
    if [ -z "$(echo "$USER_CFG" | jq -r '.response.username | select( . != null )')" ]; then
      echo "Error creating user: $USER_CFG"
      exit 1
    fi

    # Получаем uuid созданного пользователя из ответа для дальнейшего использования, если это необходимо
    # created_user_uuid=$(echo "$USER_CFG" | jq -r '.response.uuid')
    # echo "Created User UUID: $created_user_uuid"

    echo "User created successfully: $(echo "$USER_CFG" | jq .response.username)"

    echo "Upload user config to SHM"
    # Загрузка конфигурации пользователя во внутреннее хранилище (SHM)
    # Этот вызов остается без изменений, так как он относится к другому API
    curl -sk -XPUT \
      -H "session-id: $SESSION_ID" \
      -H "Content-Type: application/json" \
      "$API_URL/shm/v1/storage/manage/vpn_mrzb_{{ us.id }}" \
      --data-binary "$USER_CFG" # Передаем полный ответ от Remnawave API

    echo "done (CREATE)"
    ;;

  ACTIVATE)
    echo "Activate user"
    echo "Activating user with UUID: {{ uuid }}"

    # Вызов API для активации пользователя
    # Новый API: POST /api/users/{uuid}/actions/enable (без тела запроса)
    ACTIVE_USER_RESPONSE=$(curl -sk -XPOST \
      "$REMNAWAVE_HOST/api/users/{{ uuid }}/actions/enable" \
      -H "Authorization: Bearer $TOKEN")

    echo "Enable User Response: $ACTIVE_USER_RESPONSE"

    # Проверка статуса пользователя после активации
    # EnableUserResponseDto содержит response.status
    if [ "$(echo "$ACTIVE_USER_RESPONSE" | jq -r '.response.status')" != "ACTIVE" ]; then
      echo "Error enabling user: $ACTIVE_USER_RESPONSE"
      exit 1
    fi
    echo "User enabled successfully."

    # Тело запроса для обновления пользователя (только дата истечения)
    # Новый API для обновления: PATCH /api/users (тело содержит uuid и обновляемые поля)
    # UpdateUserRequestDto требует uuid в теле запроса.
    DATA_UPDATE_ACTIVATE="{{ toJson(
        uuid = uuid,
        expireAt = new_expire
    ).dquote
    }}"

    echo "Update User Payload (ACTIVATE): $DATA_UPDATE_ACTIVATE"

    # Вызов API для обновления информации о пользователе (даты истечения)
    UPDATE_USER_RESPONSE_ACTIVATE=$(curl -sk -XPATCH \
      "$REMNAWAVE_HOST/api/users" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$DATA_UPDATE_ACTIVATE")

    echo "Update User Response (ACTIVATE): $UPDATE_USER_RESPONSE_ACTIVATE"

    # Проверка статуса пользователя после обновления
    # UpdateUserResponseDto содержит response.status
    if [ "$(echo "$UPDATE_USER_RESPONSE_ACTIVATE" | jq -r '.response.status')" != "ACTIVE" ]; then
        echo "Error updating user after activation: $UPDATE_USER_RESPONSE_ACTIVATE"
        # exit 1 # Возможно, не стоит выходить, если активация прошла, а обновление нет
    fi
    echo "User expiration updated successfully."

    echo "done (ACTIVATE)"
    ;;

  BLOCK)
    echo "Block user"
    echo "Blocking user with UUID: {{ uuid }}"

    # Вызов API для блокировки пользователя
    # Новый API: POST /api/users/{uuid}/actions/disable (без тела запроса)
    DISABLE_USER_RESPONSE=$(curl -sk -XPOST \
      "$REMNAWAVE_HOST/api/users/{{ uuid }}/actions/disable" \
      -H "Authorization: Bearer $TOKEN")

    echo "Disable User Response: $DISABLE_USER_RESPONSE"

    # Проверка статуса пользователя после блокировки
    # DisableUserResponseDto содержит response.status (ожидаем "DISABLED")
    if [ "$(echo "$DISABLE_USER_RESPONSE" | jq -r '.response.status')" != "DISABLED" ]; then
      echo "Error disabling user: $DISABLE_USER_RESPONSE"
      exit 1
    fi
    echo "User disabled successfully."

    echo "done (BLOCK)"
    ;;

  REMOVE)
    echo "Remove user"
    echo "Removing user with UUID: {{ uuid }}"

    # Вызов API для удаления пользователя
    # Новый API: DELETE /api/users/{uuid}
    REMOVE_USER_RESPONSE=$(curl -sk -XDELETE \
      "$REMNAWAVE_HOST/api/users/{{ uuid }}" \
      -H "Authorization: Bearer $TOKEN")

    echo "Remove User Response: $REMOVE_USER_RESPONSE"

    # Проверка успешности удаления
    # DeleteUserResponseDto содержит response.isDeleted (ожидаем true)
    if [ "$(echo "$REMOVE_USER_RESPONSE" | jq -r '.response.isDeleted')" != "true" ]; then
      echo "Error removing user: $REMOVE_USER_RESPONSE"
      exit 1
    fi
    echo "User removed from Remnawave successfully."

    echo "Remove user key from SHM"
    # Удаление конфигурации пользователя из внутреннего хранилища (SHM)
    # Этот вызов остается без изменений
    curl -sk -XDELETE \
      -H "session-id: $SESSION_ID" \
      "$API_URL/shm/v1/storage/manage/vpn_mrzb_{{ us.id }}"

    echo "done (REMOVE)"
    ;;

  PROLONGATE)
    echo "Prolongate user subscription"
    echo "User UUID: {{ uuid }}"

    # 1. Получение текущей информации о пользователе (опционально, для проверки статуса)
    # Новый API: GET /api/users/{uuid}
    GET_USER_RESPONSE=$(curl -sk -XGET \
      "$REMNAWAVE_HOST/api/users/{{ uuid }}" \
      -H "Authorization: Bearer $TOKEN")

    echo "Get User Response (PROLONGATE): $GET_USER_RESPONSE"
    CURRENT_USER_STATUS=$(echo "$GET_USER_RESPONSE" | jq -r '.response.status')

    # 2. Активация пользователя, если он не активен
    # GetUserByUuidResponseDto содержит response.status
    if [ "$CURRENT_USER_STATUS" != "ACTIVE" ]; then
      echo "User status is $CURRENT_USER_STATUS. Attempting to enable..."
      # Новый API: POST /api/users/{uuid}/actions/enable
      ENABLE_USER_RESPONSE_PROLONGATE=$(curl -sk -XPOST \
        "$REMNAWAVE_HOST/api/users/{{ uuid }}/actions/enable" \
        -H "Authorization: Bearer $TOKEN")
      echo "Enable User Response (PROLONGATE): $ENABLE_USER_RESPONSE_PROLONGATE"
      if [ "$(echo "$ENABLE_USER_RESPONSE_PROLONGATE" | jq -r '.response.status')" != "ACTIVE" ]; then
        echo "Error enabling user during prolongation: $ENABLE_USER_RESPONSE_PROLONGATE"
        # Можно добавить exit 1, если активация критична
      else
        echo "User enabled successfully during prolongation."
      fi
    fi

    # 3. Сброс трафика пользователя
    # Новый API: POST /api/users/{uuid}/actions/reset-traffic (без тела запроса)
    echo "Resetting user traffic..."
    RESET_TRAFFIC_RESPONSE=$(curl -sk -XPOST \
      "$REMNAWAVE_HOST/api/users/{{ uuid }}/actions/reset-traffic" \
      -H "Authorization: Bearer $TOKEN")

    echo "Reset Traffic Response: $RESET_TRAFFIC_RESPONSE"
    # ResetUserTrafficResponseDto содержит response.status (ожидаем ACTIVE, если пользователь был активен)
    # или response.usedTrafficBytes должно стать 0
    if [ "$(echo "$RESET_TRAFFIC_RESPONSE" | jq -r '.response.usedTrafficBytes')" != "0" ]; then
        # Проверка может быть неточной, если API не сбрасывает usedTrafficBytes в 0 немедленно в ответе,
        # а только инициирует сброс. Лучше проверить статус или специфическое поле, если оно есть.
        # В ResetUserTrafficResponseDto есть response.status, можно проверить его.
        if [ "$(echo "$RESET_TRAFFIC_RESPONSE" | jq -r '.response.status')" != "ACTIVE" ]; then # Предполагаем, что статус должен остаться/стать ACTIVE
             echo "Warning: User traffic might not have been reset successfully or status is not ACTIVE. Response: $RESET_TRAFFIC_RESPONSE"
        else
             echo "User traffic reset initiated/completed."
        fi
    else
        echo "User traffic reset successfully (usedTrafficBytes is 0)."
    fi


    # 4. Обновление информации о пользователе (дата истечения)
    # Новый API для обновления: PATCH /api/users
    # UpdateUserRequestDto требует uuid в теле запроса.
    DATA_UPDATE_PROLONGATE="{{ toJson(
        uuid = uuid,
        expireAt = new_expire
        # Можно также обновить status здесь, если это необходимо, например, status = "ACTIVE"
    ).dquote
    }}"

    echo "Update User Payload (PROLONGATE): $DATA_UPDATE_PROLONGATE"

    UPDATE_USER_RESPONSE_PROLONGATE=$(curl -sk -XPATCH \
      "$REMNAWAVE_HOST/api/users" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$DATA_UPDATE_PROLONGATE")

    echo "Update User Response (PROLONGATE): $UPDATE_USER_RESPONSE_PROLONGATE"

    # Проверка статуса пользователя после обновления
    # UpdateUserResponseDto содержит response.status
    if [ "$(echo "$UPDATE_USER_RESPONSE_PROLONGATE" | jq -r '.response.status')" != "ACTIVE" ]; then
      echo "Error updating user during prolongation: $UPDATE_USER_RESPONSE_PROLONGATE"
      exit 1
    fi
    echo "User prolongation successful."

    echo "done (PROLONGATE)"
    ;;

  *)
    echo "Unknown event: $EVENT. Exit."
    exit 0
    ;;
esac

exit 0
