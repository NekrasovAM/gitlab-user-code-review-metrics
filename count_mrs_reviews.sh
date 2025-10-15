#!/usr/bin/env bash
set -euo pipefail

# --- Файлы конфигурации ---
CONFIG_FILE="./config.env"
USERS_FILE="./users.txt"
RESULTS_DIR="./results"

# --- Загружаем конфигурацию ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Файл конфигурации $CONFIG_FILE не найден."
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${API_TOKEN:?API_TOKEN не задан}"
: "${GITLAB_URL:?GITLAB_URL не задан}"
: "${COUNT_APPROVE_WITHOUT_COMMENTS:=FALSE}"  # по умолчанию FALSE

# --- Даты ---
DATE_FROM_ARG="${1:-}"
DATE_TO_ARG="${2:-}"
shift 2 2>/dev/null || true

if [[ -n "$DATE_FROM_ARG" && -z "$DATE_TO_ARG" ]]; then
    echo "Ошибка: указан DATE_FROM как аргумент, но DATE_TO не указан. Укажите второй аргумент."
    exit 1
fi

DATE_FROM="${DATE_FROM_ARG:-${DATE_FROM:-}}"
DATE_TO="${DATE_TO_ARG:-${DATE_TO:-}}"

if [[ -z "$DATE_FROM" ]]; then
    echo "Ошибка: не указан DATE_FROM. Укажите его как первый аргумент или в config.env"
    exit 1
fi
if [[ -z "$DATE_TO" ]]; then
    echo "Ошибка: не указан DATE_TO. Укажите его как второй аргумент или в config.env"
    exit 1
fi

date_regex="^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
if [[ ! "$DATE_FROM" =~ $date_regex ]]; then
    echo "Ошибка: DATE_FROM должен быть в формате YYYY-MM-DD, сейчас: $DATE_FROM"
    exit 1
fi
if [[ ! "$DATE_TO" =~ $date_regex ]]; then
    echo "Ошибка: DATE_TO должен быть в формате YYYY-MM-DD, сейчас: $DATE_TO"
    exit 1
fi

# --- Пользователи ---
if [[ $# -gt 0 ]]; then
    USERS=("$@")
elif [[ -f "$USERS_FILE" ]]; then
    USERS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        USERS+=("$line")
    done < "$USERS_FILE"
else
    echo "Список пользователей не задан и файл $USERS_FILE отсутствует."
    exit 1
fi

command -v jq >/dev/null || { echo "jq required"; exit 1; }
command -v curl >/dev/null || { echo "curl required"; exit 1; }

mkdir -p "$RESULTS_DIR"

process_user() {
    local USER_NAME="$1"
    echo
    echo "=== Обработка пользователя $USER_NAME ==="

    local tmp_events_user
    tmp_events_user=$(mktemp)
    trap '[[ -f "$tmp_events_user" ]] && rm -f "$tmp_events_user"' RETURN

    local USER_ID
    USER_ID=$(curl -sS --header "PRIVATE-TOKEN: $API_TOKEN" \
        "$GITLAB_URL/api/v4/users?username=$USER_NAME" | jq -r '.[0].id // empty')

    if [[ -z "$USER_ID" ]]; then
        echo "Не удалось получить USER_ID для $USER_NAME"
        return
    fi

    # --- Сбор событий ---
    local actions=("commented")
    if [[ "$(echo "$COUNT_APPROVE_WITHOUT_COMMENTS" | tr '[:lower:]' '[:upper:]')" == "TRUE" ]]; then
        actions+=("approved")
    fi

    for action in "${actions[@]}"; do
        local page=1
        local per_page=100
        while :; do
            local resp
            resp=$(curl -sS --header "PRIVATE-TOKEN: $API_TOKEN" \
                "$GITLAB_URL/api/v4/users/$USER_ID/events?action=$action&per_page=$per_page&page=$page")
            local is_array
            is_array=$(echo "$resp" | jq -r 'if type=="array" then "true" else "false" end')
            [[ "$is_array" != "true" ]] && break
            [[ $(echo "$resp" | jq 'length') -eq 0 ]] && break
            echo "$resp" >> "$tmp_events_user"
            ((page++))
        done
    done

    # --- Фильтруем MR по дате ---
    local mr_pairs
    if [[ "$(echo "$COUNT_APPROVE_WITHOUT_COMMENTS" | tr '[:lower:]' '[:upper:]')" == "TRUE" ]]; then
        mr_pairs=$(jq -r --arg df "$DATE_FROM" --arg dt "$DATE_TO" '
            .[]
            | select(.created_at >= $df and .created_at <= $dt)
            | if (.action_name=="approved" and (.target_type=="MergeRequest" or (.target|type=="object" and .target.iid?))) then
                "\(.project_id) \(.target_iid // .target.iid)"
              elif (.action_name=="commented" and .note.noteable_type=="MergeRequest") then
                "\(.project_id) \(.note.noteable_iid)"
              else
                empty
              end
        ' "$tmp_events_user")
    else
        mr_pairs=$(jq -r --arg df "$DATE_FROM" --arg dt "$DATE_TO" '
            .[]
            | select(.created_at >= $df and .created_at <= $dt)
            | select(.note.noteable_type == "MergeRequest")
            | "\(.project_id) \(.note.noteable_iid)"
        ' "$tmp_events_user")
    fi

    if [[ -z "$mr_pairs" ]]; then
        echo "Комментариев или одобренных MR за период $DATE_FROM — $DATE_TO не найдено."
        return
    fi

    # --- Получаем path_with_namespace для каждого проекта ---
    local project_ids
    project_ids=$(echo "$mr_pairs" | awk '{print $1}' | sort -u)
    declare -a project_paths=()
    for pid in $project_ids; do
        local path
        path=$(curl -sS --header "PRIVATE-TOKEN: $API_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$pid" | jq -r '.path_with_namespace // empty')
        [[ -n "$path" ]] && project_paths+=("$pid $path")
    done

    # --- Формируем ссылки на MR ---
    local links=()
    while read -r pid iid; do
        local path
        path=$(printf "%s\n" "${project_paths[@]}" | awk -v id="$pid" '$1==id {print $2; exit}')
        [[ -n "$path" ]] && links+=("$GITLAB_URL/$path/-/merge_requests/$iid")
    done <<< "$mr_pairs"

    local links_unique
    links_unique=$(printf "%s\n" "${links[@]}" | sort -u)
    local total
    total=$(echo "$links_unique" | wc -l | tr -d ' ')

    local OUT_FILE="$RESULTS_DIR/${USER_NAME}-${DATE_FROM}-${DATE_TO}.txt"
    if [[ "$(echo "$COUNT_APPROVE_WITHOUT_COMMENTS" | tr '[:lower:]' '[:upper:]')" == "TRUE" ]]; then
        {
            echo "Пользователь $USER_NAME оставил комментарии или одобрил $total уникальных Merge Requests (период $DATE_FROM — $DATE_TO):"
            echo
            echo "$links_unique"
        } > "$OUT_FILE"
    else
        {
            echo "Пользователь $USER_NAME оставил комментарии в $total уникальных Merge Requests (период $DATE_FROM — $DATE_TO):"
            echo
            echo "$links_unique"
        } > "$OUT_FILE"
    fi
    echo "Результат сохранён в $OUT_FILE"
}

for user in "${USERS[@]}"; do
    user_trimmed=$(echo "$user" | xargs)
    process_user "$user_trimmed"
done
