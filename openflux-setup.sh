#!/usr/bin/env bash
# Interactive Ubuntu/Debian OpenFlux installer. Run as root: bash openflux-setup.sh
set -Eeuo pipefail
umask 077
BASE=/etc/openflux-node
BIN=/opt/openflux-node/bin/openflux
UNIT=/etc/systemd/system/openflux-managed@.service
MARKER='# Managed by openflux-setup.sh'
TEMP=''
CREATED=''
FW_PORT=''
FW_KIND=''
SUCCESS=0
STATE_ROOT=/var/lib/openflux-node
AUDIT_FILE=/var/log/openflux-install/operations.log
INSTALLER_BRANCH=experimental
WORK_TEMP=''
UPDATE_OLD=''
UPDATE_UNITS=()
RESTORED=()

cleanup() {
  local rc=$?
  [[ -z "$TEMP" ]] || rm -f -- "$TEMP"
  if [[ -n "$CREATED" && "$SUCCESS" != 1 ]]; then
    systemctl disable "openflux-managed@$CREATED" >/dev/null 2>&1 || true
    stop_unit_bounded "openflux-managed@$CREATED" >/dev/null 2>&1 || true
    if [[ "$FW_KIND" == ufw ]]; then ufw delete allow "$FW_PORT/tcp" >/dev/null 2>&1 || true; fi
    if [[ "$FW_KIND" == firewalld ]]; then
      firewall-cmd --remove-port="$FW_PORT/tcp" >/dev/null 2>&1 || true
      firewall-cmd --permanent --remove-port="$FW_PORT/tcp" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$BASE/$CREATED" "/var/lib/openflux-node/$CREATED"
    echo 'Добавление клиента не завершено; созданный профиль удалён.' >&2
  fi
  if [[ -n "$UPDATE_OLD" ]]; then
    red 'Восстановление прежнего ядра после незавершённого обновления.' >&2
    atomic_core_link "$UPDATE_OLD" || true
    local unit
    for unit in "${UPDATE_UNITS[@]}"; do
      if stop_unit_bounded "$unit"; then timeout 15 systemctl start "$unit" || true; fi
    done
    audit_event core_update all rolled_back
  fi
  local name
  for name in "${RESTORED[@]}"; do
    systemctl disable "openflux-managed@$name" >/dev/null 2>&1 || true
    stop_unit_bounded "openflux-managed@$name" >/dev/null 2>&1 || true
    systemctl kill --signal=SIGKILL --kill-whom=all "openflux-managed@$name" >/dev/null 2>&1 || true
    rm -rf -- "$BASE/$name" "$STATE_ROOT/$name"
  done
  [[ -z "$WORK_TEMP" ]] || rm -rf -- "$WORK_TEMP"
  unset BACKUP_PASSWORD
  if [[ "$rc" != 0 ]]; then audit_event operation "${channel:-none}" failed; fi
  exit "$rc"
}
RED=''; GREEN=''; BLUE=''; CYAN=''; RESET=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; BLUE=$'\033[1;34m'; CYAN=$'\033[1;36m'; RESET=$'\033[0m'
fi
red() { printf '%s%s%s\n' "$RED" "$*" "$RESET"; }
green() { printf '%s%s%s\n' "$GREEN" "$*" "$RESET"; }
# OSC 8 hyperlink with a readable URL fallback for unsupported terminals.
web_link() {
  local address=$1
  if [[ -t 1 && "${TERM:-dumb}" != dumb && "${OPENFLUX_HYPERLINKS:-1}" != 0 ]]; then
    printf '\033]8;;%s\033\\%s%s%s\033]8;;\033\\' "$address" "$CYAN" "$address" "$RESET"
  else
    printf '%s%s%s' "$CYAN" "$address" "$RESET"
  fi
}
fail() { red "Ошибка: $*" >&2; exit 1; }
ask() { IFS= read -r -p "$1" "$2" || fail 'Ввод прерван'; }
client_help() {
  cat <<'HELP'

Установка и подключение клиентов

Общее для всех платформ:
  На сервере добавьте отдельного клиента через пункт 2.
  Передайте ему строку openflux://… из результата установки.
  Она также хранится в /etc/openflux-node/ИМЯ/client-link.txt.
  Ссылка содержит секретный ключ — не публикуйте её.
  В приложении: + → Ключ или ссылка / Импорт → вставить → сохранить.
  Названия кнопок могут отличаться в разных версиях.

iPhone / iPad:
  1. Установите TestFlight из App Store.
  2. На устройстве откройте https://testflight.apple.com/join/BwnAcdus
  3. Установите OpenFlux, импортируйте ссылку и подключитесь.
  4. Разрешите добавление VPN-конфигурации.
  Доступность бета-сборки проверяется в TestFlight.

Android:
  1. Откройте https://github.com/p1neappleXpress/OpenFluxAndroid/releases/latest
  2. В Assets скачайте APK для своего устройства.
  3. Разрешите установку из этого источника, установите APK.
  4. Импортируйте ссылку, выберите режим VPN и подтвердите разрешение Android.

macOS:
  1. Откройте https://github.com/p1neappleXpress/OpenFluxDesktop/releases/latest
  2. Скачайте macos-arm64.dmg (Apple Silicon) или macos-x64.dmg (Intel).
  3. Перенесите приложение в Программы и откройте его.
  4. Если macOS блокирует неподписанную сборку, используйте правый клик →
     Открыть либо штатное разрешение в Конфиденциальность и безопасность.
  5. Импортируйте ссылку. Для режима Весь трафик потребуется пароль администратора.
  В нашей версии Телемост с режимом Весь трафик несовместим: используйте прокси.

Windows:
  1. Откройте https://github.com/p1neappleXpress/OpenFluxDesktop/releases/latest
  2. В Assets скачайте установщик Windows (.msi / setup.exe) и установите.
  3. Импортируйте ссылку и выберите режим подключения.
  4. Для режима Весь трафик подтвердите запрос прав администратора.
  Если версия отказывает в полном туннеле с Телемостом, используйте прокси.

Linux:
  1. Откройте https://github.com/p1neappleXpress/OpenFluxDesktop/releases/latest
  2. Для Debian/Ubuntu скачайте .deb и выполните:
       sudo apt install ./ИМЯ_СКАЧАННОГО_ФАЙЛА.deb
     Для других дистрибутивов используйте архив Linux, если он есть в релизе.
  3. Запустите OpenFluxDesktop и импортируйте ссылку.
  4. Если системный туннель недоступен, используйте локальный прокси.

Режим прокси (проверьте фактические порты в настройках OpenFlux):
  SOCKS5: 127.0.0.1:1080; HTTP: 127.0.0.1:1081.
  Укажите прокси в нужном приложении. В Firefox: Настройки → Настройки сети →
  Ручная настройка → SOCKS v5; включите DNS через SOCKS v5.
  Сам запуск прокси не направляет через него весь трафик компьютера.

Проверка:
  Откройте сайт и проверьте внешний IP — должен быть IP VPS.
  Статус Подключено ещё не доказывает передачу данных.
  При резервном direct проверьте активный транспорт: соединение может идти
  напрямую, даже если Яндекс/Телемост не работает.
  Капча Яндекса может требоваться на телефоне и сервере. Если приложение
  не показывает окно, нужны диагностика клиента/обновление, а не новый ключ.
  Ошибка classic-mode frames / Session peers only означает несовместимость
  режима или версий клиента и сервера. Этот установщик её не исправляет.
Создание ссылок сервисов (пункт 2):
  Яндекс Доска: https://boards.yandex.ru/ → новая доска → Поделиться →
  редактирование по ссылке. Скопируйте приглашение с ?hash=… целиком.
  Mail.ru: https://cloud.mail.ru/ → новый документ → Поделиться →
  доступ на редактирование по ссылке. Нужен https://cloud.mail.ru/public/…/…
  Cups.online: выберите автосоздание комнат в скрипте. OpenFlux создаст небольшой
  набор комнат и сохранит его в профиле. Обычный адрес https://cups.online/ не подходит.
  Альтернатива: откройте https://interview.cups.online/live-coding/ и скопируйте
  адрес комнаты с ?room=UUID; вставьте одну или несколько ссылок через пробел.
  Можно также вставить готовую base64url-строку комнат OpenFlux.
  Не используйте комнаты реальных собеседований. При 403/429 не создавайте
  комнаты многократными повторами. На каждое устройство — отдельный набор.
  Для всех сервисов работа зависит от версии клиента; возможен запрос входа/капчи.
HELP
}
check_or_update() {
  command -v python3 >/dev/null && command -v curl >/dev/null || fail 'Сначала выполните первую настройку.'
  local initial=${1:-no}
  local current latest asset sha_url metadata work target old_target reply unit failed=0
  if [[ "$initial" == install ]]; then
    [[ ! -e "$BIN" && ! -L "$BIN" ]] || fail 'Обнаружена частичная установка ядра; проверьте её вручную.'
    current=node-v0.0.0
    install -d -m 755 /opt/openflux-node /opt/openflux-node/bin
  else
    [[ -L "$BIN" ]] || fail 'Ядро не установлено через ссылку openflux; автоматическая замена запрещена.'
    current=$(basename "$(readlink "$BIN")"); current=${current#openflux-}
  fi
  [[ "$current" =~ ^node-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Не удалось определить установленную версию.'
  TEMP=$(mktemp)
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 \
    'https://api.github.com/repos/p1neappleXpress/OpenFlux/releases?per_page=100' -o "$TEMP"
  metadata=$(python3 - "$TEMP" "$current" "$(uname -m)" <<'PY'
import json,re,sys
releases=json.load(open(sys.argv[1]))
valid=[r for r in releases if re.fullmatch(r'node-v\d+\.\d+\.\d+',r['tag_name']) and not r['draft'] and not r['prerelease']]
if not valid: sys.exit('Не найдены стабильные серверные релизы среди последних 100 публикаций.')
version=lambda t: tuple(map(int,t.removeprefix('node-v').split('.')))
r=max(valid,key=lambda r:version(r['tag_name']))
arch={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(sys.argv[3])
if not arch: sys.exit('Неподдерживаемая архитектура')
assets={a['name']:a['browser_download_url'] for a in r['assets']}
name='openflux-linux-'+arch
for a in (name,'SHA256SUMS'):
 if a not in assets: sys.exit('В релизе отсутствует '+a)
for url in (assets[name],assets['SHA256SUMS']):
 if not url.startswith('https://github.com/p1neappleXpress/OpenFlux/releases/download/'): sys.exit('Неожиданный URL релиза')
print(r['tag_name'],assets[name],assets['SHA256SUMS'], 'new' if version(r['tag_name'])>version(sys.argv[2]) else 'current',sep='\t')
PY
) || fail 'Не удалось проверить релизы.'
  local availability
  IFS=$'\t' read -r latest asset sha_url availability <<< "$metadata"
  if [[ "$initial" == install ]]; then
    green "Для первой установки выбран последний стабильный серверный релиз: $latest"
  else
    echo "Установлено: $current; последний стабильный серверный релиз: $latest"
  fi
  [[ "$availability" == new ]] || { green 'Обновление не требуется.'; return; }
  green "Доступна новая версия: $latest"
  [[ "$action" == 7 || "$initial" == install ]] || return 0
  if [[ "$initial" != install ]]; then
    echo 'Обновляется серверное ядро, а не приложения на телефонах/компьютерах.'
    echo 'Работающие каналы будут кратко прерваны. При сбое запуска будет возврат старого ядра.'
    ask 'Установить обновление? [y/N]: ' reply
    [[ "$reply" == y || "$reply" == Y ]] || return 0
  fi
  if [[ "$initial" != install ]]; then
    backup_profiles || fail 'Обновление отменено: нужна шифрованная резервная копия.'
    rm -rf -- "$WORK_TEMP"; WORK_TEMP=''
  fi
  work=$(mktemp -d)
  if ! curl -fsSL --retry 2 --max-time 180 "$asset" -o "$work/core" ||
     ! curl -fsSL --retry 2 --max-time 60 "$sha_url" -o "$work/SHA256SUMS"; then
    rm -rf "$work"; fail 'Не удалось скачать релиз.'
  fi
  local expected
  expected=$(python3 - "$work/SHA256SUMS" "${asset##*/}" <<'PY'
import re,sys
for line in open(sys.argv[1]):
 parts=line.split()
 if len(parts)==2 and parts[1].lstrip('*').removeprefix('./')==sys.argv[2] and re.fullmatch('[0-9a-fA-F]{64}',parts[0]):
  print(parts[0]); break
else: sys.exit('Нет контрольной суммы бинарника')
PY
) || { rm -rf "$work"; fail 'Некорректный SHA256SUMS.'; }
  if ! printf '%s  %s\n' "$expected" "$work/core" | sha256sum -c -; then
    rm -rf "$work"; fail 'Контрольная сумма не совпала; обновление отменено.'
  fi
  target="/opt/openflux-node/bin/openflux-$latest"
  [[ ! -e "$target" ]] || { rm -rf "$work"; fail 'Файл этой версии уже существует; проверьте его вручную.'; }
  install -m 755 "$work/core" "$target"
  rm -rf "$work"
  if [[ "$initial" == install ]]; then
    ln -s "openflux-$latest" "$BIN"
    green "Серверное ядро $latest установлено; SHA256SUMS проверен."
    return 0
  fi
  begin_core_transaction
  local previous=$UPDATE_OLD
  atomic_core_link "openflux-$latest"
  restart_update_units || fail 'Обновление не прошло проверку; прежнее ядро будет восстановлено.'
  printf '%s\n' "$(basename "$previous")" > /opt/openflux-node/bin/.previous-core
  chmod 600 /opt/openflux-node/bin/.previous-core
  UPDATE_OLD=''
  audit_event core_update all done
  green "Ядро обновлено до $latest. Предыдущая версия доступна через пункт 12."
  echo 'Проверьте сайты на устройствах: состояние active не подтверждает весь туннель.'

}

# Lists names and metadata only: never prints keys, links or cookies.
client_service() {
  local config=$1 label='' pair kind title
  if grep -Eiq '^[[:space:]]*(Transport|Type)[[:space:]]*=[[:space:]]*(vyandex|yandex)[[:space:]]*$' "$config"; then
    label='Яндекс Документы'
  fi
  if grep -Eiq '^[[:space:]]*(Transport|Type)[[:space:]]*=[[:space:]]*telemost[[:space:]]*$' "$config"; then
    label="${label:+$label + }Телемост"
  fi
  for pair in 'boards:Яндекс Доска' 'mailru:Mail.ru Документы' 'cupsonline:Cups.online'; do
    kind=${pair%%:*}; title=${pair#*:}
    if grep -Eiq "^[[:space:]]*(Transport|Type)[[:space:]]*=[[:space:]]*$kind[[:space:]]*$" "$config"; then
      label="${label:+$label + }$title"
    fi
  done
  printf '%s' "${label:-Другой/неизвестный}"
}
list_clients() {
  local dir name managed status unit port service found=0
  printf '\n%-32s %-28s %-18s %-12s %s\n' 'КЛИЕНТ' 'СЕРВИС' 'УПРАВЛЕНИЕ' 'СОСТОЯНИЕ' 'DIRECT TCP'
  for dir in "$BASE"/*; do
    [[ -d "$dir" && ! -L "$dir" && -f "$dir/node.conf" ]] || continue
    found=1; name=${dir##*/}; port='—'
    if [[ -f "$dir/.managed-by-setup" ]]; then
      managed='скрипт'; unit="openflux-managed@$name"
    else
      managed='внешний/ручной'; unit="openflux-node@$name"
    fi
    status=$(systemctl is-active "$unit" 2>/dev/null) || true
    status=${status:-unknown}
    [[ ! -f "$dir/revoked" ]] || status='отозван'
    if [[ -f "$dir/port" ]]; then
      IFS= read -r port < "$dir/port" || true
    else
      port=$(sed -nE 's/^[[:space:]]*Listen[[:space:]]*=[[:space:]]*[^ ]*:([0-9]+)[[:space:]]*$/\1/p' "$dir/node.conf" | head -1)
      port=${port:-—}
    fi
    service=$(client_service "$dir/node.conf")
    printf '%-32s %-28s %-18s %-12s %s\n' "$name" "$service" "$managed" "$status" "$port"
  done
  [[ "$found" == 1 ]] || echo 'Клиентов пока нет.'
  echo 'Для удаления выберите пункт 3, затем номер клиента.'
}
# Operational journal deliberately accepts identifiers only, never arbitrary output.
audit_event() {
  [[ $EUID == 0 || "${BASH_SOURCE[0]}" != "$0" ]] || return 0
  local event=${1:-unknown} client=${2:-none} result=${3:-unknown}
  [[ "$event" =~ ^[a-z0-9_-]+$ ]] || event=invalid-event
  [[ "$client" =~ ^[a-z0-9_-]+$ ]] || client=redacted
  [[ "$result" =~ ^[a-z0-9_-]+$ ]] || result=unknown
  [[ ! -L "$AUDIT_FILE" ]] || return 0
  mkdir -p "$(dirname "$AUDIT_FILE")" || return 0
  ( umask 077; touch "$AUDIT_FILE"; chmod 600 "$AUDIT_FILE"
    printf '%s event=%s client=%s result=%s\n' "$(date -u +%FT%TZ)" "$event" "$client" "$result" >> "$AUDIT_FILE"
  ) 2>/dev/null || true
}
preflight() {
  local mode=${1:-inspect} os version
  [[ $EUID == 0 ]] || fail 'Нужен root или sudo.'
  [[ -r /etc/os-release ]] || fail 'Не удалось определить ОС.'
  os=$(. /etc/os-release; printf '%s' "$ID")
  [[ "$os" == ubuntu || "$os" == debian ]] || fail 'Поддерживаются только Ubuntu/Debian.'
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null || fail 'Требуется работающий systemd.'
  case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) fail 'Поддерживаются amd64/arm64.' ;; esac
  command -v apt-get >/dev/null || fail 'Не найден apt-get.'
  if [[ "$mode" == installed ]]; then
    for tool in python3 curl openssl tar timeout ss; do command -v "$tool" >/dev/null || fail "Не найден $tool. Выполните первую настройку."; done
    [[ -x "$BIN" ]] || fail 'Сначала выполните первую настройку сервера.'
  fi
  if command -v python3 >/dev/null; then
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' || fail 'Требуется Python 3.9 или новее.'
  fi
  if command -v curl >/dev/null; then
    curl -fsSL --connect-timeout 10 --max-time 20 -o /dev/null https://api.github.com/repos/p1neappleXpress/OpenFlux || fail 'Нет доступа к GitHub API по HTTPS. Изменения не выполнены.'
  else
    echo 'curl ещё не установлен; HTTPS будет проверен после установки зависимостей.'
  fi
  echo "ОС: $os; архитектура: $(uname -m); systemd: доступен."
  local count=0 dir
  for dir in "$BASE"/*; do [[ ! -f "$dir/node.conf" ]] || count=$((count+1)); done
  echo "Обнаружено профилей: $count. Существующие профили не перезаписываются."
  echo 'Доступность UDP/WebRTC этим тестом не подтверждается.'
}
select_client() {
  local dir name number
  local names=()
  for dir in "$BASE"/*; do
    [[ -d "$dir" && ! -L "$dir" && -f "$dir/node.conf" && ! -L "$dir/node.conf" ]] || continue
    name=${dir##*/}; [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || continue
    names+=("$name"); printf '%d) %s — %s\n' "${#names[@]}" "$name" "$(client_service "$dir/node.conf")"
  done
  [[ ${#names[@]} -gt 0 ]] || { echo 'Клиентов нет.'; return 1; }
  echo '0) Отмена'
  while :; do
    ask 'Номер клиента: ' number
    [[ "$number" != 0 ]] || return 1
    if [[ "$number" =~ ^[1-9][0-9]{0,5}$ ]] && ((number<=${#names[@]})); then
      SELECTED_CLIENT=${names[$((number-1))]}; return 0
    fi
    red 'Неверный номер.'
  done
}
client_units_for() {
  local name=$1 prefix candidate command_line
  for prefix in openflux-managed openflux-node openflux-telemost; do
    candidate="$prefix@$name.service"
    command_line=$(systemctl show "$candidate" -p ExecStart --value 2>/dev/null) || continue
    if [[ "$command_line" == *"--config $BASE/$name/node.conf ;"* && "$command_line" == *"path=$BIN ;"* ]]; then printf '%s\n' "$candidate"; fi
  done
}
diagnose_text() {
  python3 -c '
import sys
s=sys.stdin.read().lower()
if any(x in s for x in ("captcha","smartcaptcha")): print("Обнаружена капча: нужна проверка на соответствующей стороне.")
if any(x in s for x in ("classic-mode frames","session peers only","kdf context")): print("Обнаружено предупреждение: протокол или контекст шифрования различаются.")
if "gave up" in s or "dropped" in s: print("Обнаружены потери/отброшенные данные; стабильность не подтверждена.")
if "handshake timed out" in s: print("Согласование с устройством не завершилось вовремя.")
if any(x in s for x in ("new client took over","peer restarted","-> watching \"")): print("Есть недавние признаки обмена с участником или его переподключения; это не тест интернет-трафика.")
print("Сквозная передача интернет-трафика не проверена. Откройте сайт на устройстве и проверьте внешний IP.")
'
}
diagnose_client() {
  select_client || return 0
  local name=$SELECTED_CLIENT unit logs='' units=()
  while IFS= read -r unit; do [[ -z "$unit" ]] || units+=("$unit"); done < <(client_units_for "$name")
  echo "Клиент: $name; настроенный сервис: $(client_service "$BASE/$name/node.conf")"
  echo 'Это настройка, а не доказательство активного транспорта.'
  [[ ${#units[@]} -gt 0 ]] || echo 'Не найден сервис с ожидаемой конфигурацией.'
  for unit in "${units[@]}"; do
    systemctl show "$unit" -p ActiveState -p SubState -p NRestarts -p MainPID
    logs+=$(journalctl -u "$unit" --since '10 minutes ago' -n 200 --no-pager -o cat 2>/dev/null || true)
    logs+=$'\n'
  done
  printf '%s' "$logs" | diagnose_text
  echo 'Сырые логи могут содержать ссылки транспорта. Не публикуйте их без удаления секретов.'
  audit_event diagnose "$name" done
}
show_client_link() {
  select_client || return 0
  local file="$BASE/$SELECTED_CLIENT/client-link.txt" value reply
  [[ -f "$file" && ! -L "$file" ]] || fail 'Сохранённая ссылка отсутствует. Профиль не изменён.'
  value=$(cat "$file")
  [[ "$value" =~ ^openflux://v1/[A-Za-z0-9_+/=-]+$ ]] || fail 'Файл не содержит ожидаемую ссылку OpenFlux.'
  red 'Ссылка и QR содержат секрет доступа. Не публикуйте их.'
  printf '%s%s%s\n' "$BLUE" "$value" "$RESET"
  ask 'Показать QR-код в терминале? [y/N]: ' reply
  if [[ "$reply" == y || "$reply" == Y ]]; then
    if ! command -v qrencode >/dev/null; then
      ask 'Установить пакет qrencode из репозитория ОС? [y/N]: ' reply
      [[ "$reply" == y || "$reply" == Y ]] || return 0
      apt-get install -y qrencode
    fi
    printf '%s' "$value" | qrencode -t ANSIUTF8
  fi
  audit_event show_link "$SELECTED_CLIENT" done
}
# Authenticated envelope: OpenSSL AES-CBC/PBKDF2 ciphertext, encrypt-then-HMAC.
# Password arrives on fd 3, never argv, environment or log.
crypto_archive() {
  python3 - "$1" "$2" "$3" 3<&3 <<'PY'
import hashlib,hmac,os,pathlib,subprocess,sys,tempfile
mode,src,dst=sys.argv[1:]; magic=b'OPENFLUX-BACKUP-1\n'; limit=512*1024*1024
password=os.read(3,65536).rstrip(b'\n')
if not password: sys.exit('Пустой пароль')
source=pathlib.Path(src)
if source.stat().st_size>limit: sys.exit('Архив слишком большой (лимит 512 МБ)')
raw=source.read_bytes()
def crypt(data,decrypt=False):
 r,w=os.pipe()
 try:
  os.write(w,password+b'\n'); os.close(w); w=-1
  cmd=['openssl','enc','-aes-256-cbc','-pbkdf2','-iter','300000','-salt','-pass',f'fd:{r}']
  if decrypt: cmd.append('-d')
  result=subprocess.run(cmd,input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(r,))
  if result.returncode: raise ValueError('Не удалось обработать шифрованный архив')
  return result.stdout
 finally:
  os.close(r)
  if w!=-1: os.close(w)
try:
 if mode=='encrypt':
  salt=os.urandom(16); ciphertext=crypt(raw)
  key=hashlib.pbkdf2_hmac('sha256',password,b'openflux-mac:'+salt,300000)
  payload=magic+salt+ciphertext
  output=payload+hmac.digest(key,payload,'sha256')
 elif mode=='decrypt':
  if not raw.startswith(magic) or len(raw)<len(magic)+16+32+16: raise ValueError('Неверный формат архива')
  salt=raw[len(magic):len(magic)+16]; key=hashlib.pbkdf2_hmac('sha256',password,b'openflux-mac:'+salt,300000)
  if not hmac.compare_digest(hmac.digest(key,raw[:-32],'sha256'),raw[-32:]): raise ValueError('Неверный пароль или архив повреждён')
  output=crypt(raw[len(magic)+16:-32],True)
 else: raise ValueError('Неверный режим')
 dest=pathlib.Path(dst)
 # Exclusive creation prevents accidental overwrite of a backup or symlink.
 fd=os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'wb') as f: f.write(output)
except (OSError,ValueError) as e: sys.exit(str(e))
PY
}
read_backup_password() {
  local again
  IFS= read -r -s -p 'Пароль архива (не менее 12 символов): ' BACKUP_PASSWORD || return 1
  printf '\n'
  [[ ${#BACKUP_PASSWORD} -ge 12 && ${#BACKUP_PASSWORD} -le 1024 ]] || { unset BACKUP_PASSWORD; red 'Нужно от 12 до 1024 символов.'; return 1; }
  if [[ "${1:-}" == confirm ]]; then
    IFS= read -r -s -p 'Повторите пароль: ' again || return 1
    printf '\n'
    [[ "$again" == "$BACKUP_PASSWORD" ]] || { unset BACKUP_PASSWORD; red 'Пароли не совпадают.'; return 1; }
  fi
}
pack_archive() {
  python3 - "$BASE" "$STATE_ROOT" "$BIN" "$1" <<'PY'
import json,os,pathlib,re,sys,tarfile,io
base,state,binary,out=map(pathlib.Path,sys.argv[1:]); names=[]; total=0; members=[]
for d in sorted(base.iterdir()):
 if d.is_dir() and not d.is_symlink() and re.fullmatch('[a-z0-9][a-z0-9-]{0,30}',d.name) and (d/'node.conf').is_file():
  names.append(d.name)
  for root,prefix in ((d,'conf'),(state/d.name,'state')):
   if not root.exists(): continue
   for p in [root,*root.rglob('*')]:
    if p.is_symlink() or not (p.is_dir() or p.is_file()): sys.exit('Архив не создаётся: символические ссылки/спецфайлы в профиле')
    if p.is_file(): total+=p.stat().st_size
    members.append((p,str(pathlib.PurePosixPath(prefix)/d.name/p.relative_to(root))))
if not names: sys.exit('Нет профилей для резервной копии')
if total>256*1024*1024: sys.exit('Данные профилей превышают 256 МБ')
manifest=dict(schema=1,channels=names,core=os.readlink(binary) if binary.is_symlink() else '')
with tarfile.open(out,'w:gz',dereference=False) as t:
 raw=json.dumps(manifest).encode(); info=tarfile.TarInfo('manifest.json'); info.size=len(raw);info.mode=0o600;t.addfile(info,io.BytesIO(raw))
 for p,name in members: t.add(p,arcname=name,recursive=False)
PY
}
validate_archive() {
  python3 - "$1" "$2" <<'PY'
import json,pathlib,re,sys,tarfile
archive,stage=map(pathlib.Path,sys.argv[1:])
try:
 with tarfile.open(archive,'r:*') as t:
  members=[];seen=set();total=0
  for m in t:
   if len(members)>=10000: raise ValueError('превышен лимит файлов')
   members.append(m)
   path=pathlib.PurePosixPath(m.name)
   if path.is_absolute() or '..' in path.parts or m.name in seen or not (m.isfile() or m.isdir()): raise ValueError('опасный путь/тип файла')
   if len(path.parts)>20 or len(m.name)>1024: raise ValueError('слишком длинный путь')
   seen.add(m.name);total+=m.size
   if total>256*1024*1024: raise ValueError('превышен лимит данных')
   if (m.name=='manifest.json' or m.name.endswith('/node.conf')) and m.size>65536: raise ValueError('превышен лимит метаданных')
   if m.name.endswith('/encryption-key') and m.size>256: raise ValueError('превышен лимит ключа')
  manifest=json.load(t.extractfile('manifest.json'))
  names=manifest.get('channels')
  if manifest.get('schema')!=1 or not isinstance(names,list) or not names or len(names)!=len(set(names)): raise ValueError('неверный manifest')
  if any(not isinstance(n,str) or not re.fullmatch('[a-z0-9][a-z0-9-]{0,30}',n) for n in names): raise ValueError('неверное имя')
  for m in members:
   parts=pathlib.PurePosixPath(m.name).parts
   if m.name!='manifest.json' and (len(parts)<2 or parts[0] not in ('conf','state') or parts[1] not in names): raise ValueError('лишний файл')
  for n in names:
   text=t.extractfile(f'conf/{n}/node.conf').read().decode()
   if not re.search(r'^Role\s*=\s*exit\s*$',text,re.M): raise ValueError('не выходной профиль')
   expected={'EncryptionKeyFile':f'/etc/openflux-node/{n}/encryption-key','CookieStore':f'/var/lib/openflux-node/{n}/cookies.json'}
   for k,v in expected.items():
    values=re.findall(r'^\s*'+k+r'\s*=\s*(.*?)\s*$',text,re.M)
    if values!=[v]: raise ValueError('неожиданный путь конфигурации')
   key=t.extractfile(f'conf/{n}/encryption-key').read().decode().strip()
   if not re.fullmatch('[a-fA-F0-9]{64}',key): raise ValueError('ключ отсутствует или повреждён')
  stage.mkdir(mode=0o700,parents=True,exist_ok=False)
  for m in members:
   p=stage/m.name
   if m.isdir(): p.mkdir(parents=True,exist_ok=True,mode=0o700)
   else:
    p.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with p.open('xb') as f: f.write(t.extractfile(m).read())
    p.chmod(0o600)
except (OSError,ValueError,KeyError,TypeError,UnicodeError,tarfile.TarError) as e:
 sys.exit('Небезопасный/некорректный архив: '+str(e))
PY
}
backup_profiles() {
  local destination reply
  echo 'Архив содержит ключи и cookies. Он будет зашифрован; пароль восстановить нельзя.'
  ask 'Абсолютный путь нового архива (например /root/openflux.backup): ' destination
  [[ "$destination" == /* && ! -e "$destination" && ! -L "$destination" ]] || fail 'Нужен новый абсолютный путь; существующий файл не перезаписывается.'
  read_backup_password confirm || return 1
  WORK_TEMP=$(mktemp -d) || { unset BACKUP_PASSWORD; red 'Не удалось выделить защищённый временный каталог.' >&2; return 1; }
  if [[ -z "$WORK_TEMP" ]] || ! chmod 700 "$WORK_TEMP"; then
    unset BACKUP_PASSWORD
    [[ -z "$WORK_TEMP" ]] || rm -rf -- "$WORK_TEMP"
    WORK_TEMP=''
    return 1
  fi
  if ! pack_archive "$WORK_TEMP/profiles.tar.gz"; then
    red 'Не удалось собрать резервную копию. Изменение ядра отменяется.' >&2
    unset BACKUP_PASSWORD
    rm -rf -- "$WORK_TEMP"; WORK_TEMP=''
    return 1
  fi
  if ! crypto_archive encrypt "$WORK_TEMP/profiles.tar.gz" "$destination" 3<<<"$BACKUP_PASSWORD"; then
    red 'Не удалось зашифровать архив. Изменение ядра отменяется.' >&2
    unset BACKUP_PASSWORD
    rm -rf -- "$WORK_TEMP"; WORK_TEMP=''
    return 1
  fi
  unset BACKUP_PASSWORD
  green "Резервная копия сохранена: $destination"
  audit_event backup all done
  BACKUP_RESULT=$destination
  rm -rf -- "$WORK_TEMP"; WORK_TEMP=''
}
validate_installer() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  [[ $(head -1 "$1") == '#!/usr/bin/env bash' ]] || { echo 'Получен не Bash-скрипт' >&2; return 1; }
  grep -qF '# Interactive Ubuntu/Debian OpenFlux installer.' "$1" || return 1
  bash -n "$1"
}
validate_restore_targets() {
  local stage=$1 dir name unit
  for dir in "$stage/conf"/*; do
    name=${dir##*/}
    [[ ! -e "$BASE/$name" && ! -L "$BASE/$name" && ! -e "$STATE_ROOT/$name" && ! -L "$STATE_ROOT/$name" ]] || { echo "Имя $name занято. Восстановление ничего не перезаписывает." >&2; return 1; }
    for unit in openflux-managed openflux-node openflux-telemost; do
      [[ ! -e "/etc/systemd/system/$unit@$name.service" ]] || { echo "Сервис $name уже существует." >&2; return 1; }
    done
  done
}
restore_profiles() {
  preflight installed
  local source reply name dir unit existing=0 port next_port
  ask 'Абсолютный путь шифрованного архива: ' source
  [[ "$source" == /* && -f "$source" && ! -L "$source" ]] || fail 'Не найден обычный файл архива.'
  read_backup_password || return 1
  WORK_TEMP=$(mktemp -d); chmod 700 "$WORK_TEMP"
  crypto_archive decrypt "$source" "$WORK_TEMP/profiles.tar.gz" 3<<<"$BACKUP_PASSWORD"
  unset BACKUP_PASSWORD
  validate_archive "$WORK_TEMP/profiles.tar.gz" "$WORK_TEMP/stage"
  local names=()
  for dir in "$WORK_TEMP/stage/conf"/*; do
    name=${dir##*/}; names+=("$name")
  done
  validate_restore_targets "$WORK_TEMP/stage" || fail 'Обнаружены конфликты восстановления.'
  # Validate all listeners against active sockets, stopped profiles and one another.
  python3 - "$WORK_TEMP/stage/conf" "$BASE" "$BIN" <<'PY'
import pathlib,re,socket,subprocess,sys
stage,base,binary=sys.argv[1:]; reserved=set(); helptext=subprocess.run([binary,'--help'],capture_output=True,text=True).stdout
if not helptext: helptext=subprocess.run([binary,'--help'],capture_output=True,text=True).stderr
for p in pathlib.Path(base).rglob('node.conf'):
 reserved.update(map(int,re.findall(r'(?m)^\s*Listen\s*=.*:(\d+)\s*$',p.read_text())))
for p in pathlib.Path(stage).rglob('node.conf'):
 text=p.read_text()
 for kind in re.findall(r'(?m)^\s*(?:Transport|Type)\s*=\s*(\w+)\s*$',text):
  if '--transport='+kind not in helptext: sys.exit('Ядро не подтверждает поддержку транспорта '+kind)
 for value in re.findall(r'(?m)^\s*Listen\s*=.*:(\d+)\s*$',text):
  port=int(value)
  if not 1024<=port<=65535 or port in reserved: sys.exit('Конфликт/неверный порт '+value)
  try:
   with socket.socket() as s: s.bind(('0.0.0.0',port))
  except OSError: sys.exit('Порт занят '+value)
  reserved.add(port)
PY
  echo "Проверено профилей: ${#names[@]}. Существующие файлы не будут перезаписаны."
  echo 'Правила firewall из архива не применяются автоматически: direct-порты нужно разрешить отдельно.'
  ask 'Восстановить профили? [y/N]: ' reply
  [[ "$reply" == y || "$reply" == Y ]] || return 0
  ensure_unit
  for name in "${names[@]}"; do
    # Register ownership before mutation so cleanup can undo an interrupted restore.
    RESTORED+=("$name")
    mkdir "$BASE/$name"
    cp -R "$WORK_TEMP/stage/conf/$name/." "$BASE/$name/"
    mkdir "$STATE_ROOT/$name"
    if [[ -d "$WORK_TEMP/stage/state/$name" ]]; then cp -R "$WORK_TEMP/stage/state/$name/." "$STATE_ROOT/$name/"; fi
    rm -f "$BASE/$name/firewall" "$BASE/$name/revoked"
    touch "$BASE/$name/.managed-by-setup"
    chown -R root:openflux-node "$BASE/$name"
    find "$BASE/$name" -type d -exec chmod 751 {} +
    find "$BASE/$name" -type f -exec chmod 640 {} +
    chown -R openflux-node:openflux-node "$STATE_ROOT/$name"
    find "$STATE_ROOT/$name" -type d -exec chmod 750 {} +
    find "$STATE_ROOT/$name" -type f -exec chmod 600 {} +
  done
  echo 'Профили восстановлены в остановленном состоянии.'
  ask 'Включить автозапуск и запустить восстановленные каналы? [y/N]: ' reply
  if [[ "$reply" == y || "$reply" == Y ]]; then
    for name in "${names[@]}"; do
      timeout 25 systemctl enable --now "openflux-managed@$name" || fail "Не удалось запустить $name; восстановление отменяется."
    done
    sleep 3
    for name in "${names[@]}"; do systemctl is-active --quiet "openflux-managed@$name" || fail "Канал $name завершился; восстановление отменяется."; done
  fi
  RESTORED=()
  audit_event restore all done
  green 'Восстановление завершено. Проверьте сайты и внешний IP на устройствах.'
}
rollback_core() {
  preflight installed
  local previous current unit reply
  previous=$(cat /opt/openflux-node/bin/.previous-core 2>/dev/null) || fail 'Нет сохранённой версии для отката.'
  [[ "$previous" =~ ^openflux-node-v[0-9]+\.[0-9]+\.[0-9]+$ && -x "/opt/openflux-node/bin/$previous" ]] || fail 'Неверная/отсутствующая предыдущая версия.'
  current=$(basename "$(readlink "$BIN")")
  [[ "$current" != "$previous" ]] || { echo 'Уже используется предыдущая версия.'; return; }
  echo "Возврат $current → $previous. Активные каналы будут перезапущены."
  ask 'Выполнить откат? [y/N]: ' reply
  [[ "$reply" == y || "$reply" == Y ]] || return 0
  backup_profiles || fail 'Без резервной копии откат отменён.'
  begin_core_transaction
  atomic_core_link "$previous"
  restart_update_units || fail 'Откат не прошёл проверку. Восстановлю исходное ядро.'
  UPDATE_OLD=''
  green 'Предыдущее ядро включено. Проверьте подключение устройств.'
  audit_event core_rollback all done
}
atomic_core_link() {
  local target=$1 temporary
  temporary=$(mktemp -u /opt/openflux-node/bin/.link.XXXXXXXX)
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$BIN"
}
begin_core_transaction() {
  UPDATE_OLD=$(readlink "$BIN"); UPDATE_UNITS=()
  local unit exec_start
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    exec_start=$(systemctl show "$unit" -p ExecStart --value)
    [[ "$exec_start" == *"path=$BIN ;"* ]] || continue
    UPDATE_UNITS+=("$unit")
  done < <(systemctl list-units 'openflux-managed@*.service' 'openflux-node@*.service' 'openflux-telemost@*.service' --state=active --no-legend --plain | awk '{print $1}')
}
stop_unit_bounded() {
  local unit=$1 current attempt
  systemctl stop --no-block "$unit" || return 1
  for ((attempt=0; attempt<10; attempt++)); do
    current=$(systemctl show "$unit" -p ActiveState --value) || return 1
    [[ "$current" == inactive || "$current" == failed ]] && return 0
    sleep 1
  done
  systemctl kill --signal=SIGKILL --kill-whom=all "$unit" || true
  for ((attempt=0; attempt<5; attempt++)); do
    current=$(systemctl show "$unit" -p ActiveState --value) || return 1
    [[ "$current" == inactive || "$current" == failed ]] && return 0
    sleep 1
  done
  return 1
}
restart_update_units() {
  local unit failed=0
  for unit in "${UPDATE_UNITS[@]}"; do
    echo "Перезапуск $unit (до 25 секунд)…"
    if stop_unit_bounded "$unit"; then
      timeout 15 systemctl start "$unit" || failed=1
    else
      failed=1
    fi
  done
  sleep 5
  for unit in "${UPDATE_UNITS[@]}"; do systemctl is-active --quiet "$unit" || failed=1; done
  [[ "$failed" == 0 ]]
}
github_download() {
  local address=$1 output=$2
  if [[ -n "${GH_TOKEN:-}" ]]; then
    [[ "$GH_TOKEN" != *$'\n'* && "$GH_TOKEN" != *'"'* ]] || fail 'Некорректный GH_TOKEN.'
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 60 --config /dev/fd/3 "$address" -o "$output" 3<<<"header = \"Authorization: Bearer $GH_TOKEN\""
  else
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 60 "$address" -o "$output"
  fi
}
update_installer() {
  local branch=$INSTALLER_BRANCH commit destination previous reply downloaded_hash local_hash
  [[ "$branch" == experimental || "$branch" == main ]] || fail 'Обновление разрешено только из main/experimental.'
  destination=$(readlink -f -- "${BASH_SOURCE[0]}")
  [[ -f "$destination" && -w "$destination" ]] || fail 'Файл установщика недоступен для замены.'
  WORK_TEMP=$(mktemp -d); chmod 700 "$WORK_TEMP"
  echo "Источник: Dgeliko/openflux-install, ветка $branch."
  echo 'Для приватного репозитория можно заранее задать GH_TOKEN с доступом чтения. Токен в скрипт не сохраняется.'
  github_download "https://api.github.com/repos/Dgeliko/openflux-install/commits/$branch" "$WORK_TEMP/commit.json" || fail 'Нет доступа к репозиторию. Файл установщика не изменён.'
  commit=$(python3 - "$WORK_TEMP/commit.json" <<'PY'
import json,re,sys
v=json.load(open(sys.argv[1])).get('sha','')
if not re.fullmatch('[a-f0-9]{40}',v): sys.exit('GitHub не вернул SHA коммита')
print(v)
PY
) || fail 'Не удалось определить коммит.'
  github_download "https://raw.githubusercontent.com/Dgeliko/openflux-install/$commit/openflux-setup.sh" "$WORK_TEMP/script" || fail 'Не удалось скачать файл по SHA коммита.'
  validate_installer "$WORK_TEMP/script" || fail 'Загруженный файл не прошёл проверку. Замена отменена.'
  downloaded_hash=$(sha256sum "$WORK_TEMP/script" | cut -d' ' -f1)
  local_hash=$(sha256sum "$destination" | cut -d' ' -f1)
  [[ "$downloaded_hash" != "$local_hash" ]] || { green 'Файл установщика уже соответствует ветке.'; return; }
  echo "Проверен коммит: $commit; SHA256: $downloaded_hash"
  ask 'Заменить установщик и сохранить предыдущую копию? [y/N]: ' reply
  [[ "$reply" == y || "$reply" == Y ]] || return 0
  previous="${destination}.previous.$(date -u +%Y%m%dT%H%M%SZ)"
  [[ ! -e "$previous" && ! -L "$previous" ]] || fail 'Резервная копия скрипта уже существует.'
  cp -p -- "$destination" "$previous"
  TEMP=$(mktemp "$(dirname "$destination")/.openflux-update.XXXXXXXX")
  install -m 700 "$WORK_TEMP/script" "$TEMP"
  mv -f -- "$TEMP" "$destination"; TEMP=''
  audit_event self_update none done
  green "Установщик обновлён. Предыдущий файл: $previous"
  echo 'Для загрузки нового меню выйдите через 0 и запустите файл заново.'
}
transport_status() {
  local kind=$1
  case "$kind" in
    telemost) echo 'Телемост: связь наблюдалась в нашем окружении, стабильность не гарантирована; экспериментальный транспорт.' ;;
    vyandex|yandex) echo 'Яндекс Документы: в нашем iOS-окружении были блокирующие капчи, сквозная работа не подтверждена.' ;;
    boards|mailru|cupsonline) echo 'Сквозная работа этого транспорта нами не проверена; добавление профиля не является тестом связи.' ;;
  esac
}

ensure_unit() {
if [[ -e "$UNIT" ]]; then
  grep -qxF "$MARKER" "$UNIT" || fail 'Шаблон сервиса создан другим инструментом; не перезаписываю.'
else
  cat > "$UNIT" <<EOF
$MARKER
[Unit]
Description=OpenFlux managed channel %i
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=openflux-node
Group=openflux-node
StateDirectory=openflux-node/%i
WorkingDirectory=/var/lib/openflux-node/%i
ExecStart=$BIN --config $BASE/%i/node.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/openflux-node/%i
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  systemctl daemon-reload
fi

}

# Sourcing exposes functions to isolated development checks, with no system mutations.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ $EUID == 0 ]] || fail 'Запустите через sudo bash openflux-setup.sh или под root.'
[[ -t 0 ]] || fail 'Нужен интерактивный терминал. Сначала скачайте скрипт, затем запускайте bash openflux-setup.sh.'
command -v flock >/dev/null || fail 'Не найден flock (пакет util-linux).'
if [[ "${1:-}" != --run-menu-action ]]; then
  exec 9>/run/openflux-setup.lock
  flock -n 9 || fail 'Другой экземпляр установщика уже работает.'
fi
[[ -d /run/systemd/system ]] || fail 'Требуется systemd.'

if [[ "${1:-}" != --run-menu-action ]]; then
  script_path=$(readlink -f -- "${BASH_SOURCE[0]}")
  while :; do
printf '\nOpenFlux: настройка сервера и клиентов\n'
green '1) Первая настройка сервера + первый клиент'
green '2) Добавление клиента'
red '3) Удаление клиента'
echo '4) Список всех клиентов'
echo '5) Установка и настройка клиентов (все платформы)'
echo '6) Проверить новую версию серверного ядра'
green '7) Обновить серверное ядро OpenFlux'
echo '8) Диагностика клиента'
echo '9) Показать ссылку и QR существующего клиента'
echo '10) Шифрованная резервная копия'
echo '11) Восстановление профилей из архива'
echo '12) Откат серверного ядра'
echo '13) Обновить сам установщик'
echo '14) Проверка сервера до изменений'
echo '15) Журнал операций (без ключей и ссылок)'
echo
red 'Удаление останавливает сервис и удаляет профиль, ключ и cookies.'
echo '0) Выход'
ask 'Выберите 0–15: ' action
[[ "$action" != 0 ]] || break
    if [[ ! "$action" =~ ^([1-9]|1[0-5])$ ]]; then
      red 'Неверный пункт.'
      continue
    fi
    # A fresh process resets operation variables and preserves errexit/rollback.
    set +e
    audit_event "menu_$action" none started
    bash "$script_path" --run-menu-action "$action"
    result=$?
    set -e
    if [[ "$result" == 0 ]]; then audit_event "menu_$action" none returned; else audit_event "menu_$action" none failed; fi
    if [[ "$result" != 0 ]]; then
      red "Операция завершилась с ошибкой (код $result). Можно выбрать другой пункт."
    fi
    IFS= read -r -p 'Нажмите Enter для возврата в главное меню…' pause || break
  done
  exit 0
fi
action=${2:-}
[[ "$action" =~ ^([1-9]|1[0-5])$ ]] || fail 'Неверный пункт.'
case "$action" in
  8) diagnose_client; exit 0 ;;
  9) show_client_link; exit 0 ;;
  10) backup_profiles; exit 0 ;;
  11) restore_profiles; exit 0 ;;
  12) rollback_core; exit 0 ;;
  13) update_installer; exit 0 ;;
  14) preflight inspect; exit 0 ;;
  15) [[ ! -f "$AUDIT_FILE" ]] || tail -n 60 "$AUDIT_FILE"; exit 0 ;;
esac
if [[ "$action" == 6 || "$action" == 7 ]]; then check_or_update; exit 0; fi
if [[ "$action" == 5 ]]; then client_help; exit 0; fi
if [[ "$action" == 4 ]]; then list_clients; exit 0; fi
if [[ "$action" == 3 ]]; then
  clients=()
  red 'Выберите клиента: профиль, ключ и cookies будут удалены.'
  for dir in "$BASE"/*; do
    [[ -d "$dir" && ! -L "$dir" && -f "$dir/node.conf" && ! -L "$dir/node.conf" ]] || continue
    name=${dir##*/}
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || continue
    clients+=("$name")
    status=''
    [[ ! -f "$dir/revoked" ]] || status=' (ключ уже отозван)'
    printf '%s%d) %s — %s%s%s\n' "$RED" "${#clients[@]}" "$name" "$(client_service "$dir/node.conf")" "$status" "$RESET"
  done
  [[ ${#clients[@]} -gt 0 ]] || { echo 'Клиентов нет.'; exit 0; }
  green '0) Отмена'
  while :; do
    ask 'Номер клиента: ' choice
    [[ "$choice" != 0 ]] || exit 0
    if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#clients[@]} )); then
      channel=${clients[$((choice - 1))]}
      break
    fi
    echo 'Введите номер из списка или 0 для отмены.'
  done
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || fail 'Неверное имя.'
  conf="$BASE/$channel"
  [[ -d "$conf" && ! -L "$conf" && -f "$conf/node.conf" && ! -L "$conf/node.conf" ]] || fail 'Не найден обычный каталог профиля с node.conf.'
  [[ ! -L "/var/lib/openflux-node/$channel" ]] || fail 'Каталог состояния является ссылкой; требуется ручная проверка.'
  # Both historical templates can point at the same config. Stop both to revoke access.
  client_units=()
  for prefix in openflux-managed openflux-node openflux-telemost; do
    candidate="$prefix@$channel"
    exec_start=$(systemctl show "$candidate" -p ExecStart --value 2>/dev/null) || continue
    if [[ "$exec_start" == *"--config $conf/node.conf ;"* && "$exec_start" == *"path=$BIN ;"* ]]; then
      client_units+=("$candidate")
    fi
  done
  [[ ${#client_units[@]} -gt 0 ]] || fail 'Не найден сервис OpenFlux с ожидаемым путём конфигурации. Нужна ручная проверка.'
  red "Выбран клиент: $channel"
  for client_unit in "${client_units[@]}"; do
    red "Остановка $client_unit (ожидание до 10 секунд)…"
    systemctl disable "$client_unit"
    systemctl stop --no-block "$client_unit"
    for ((attempt=0; attempt<10; attempt++)); do
      state=$(systemctl show "$client_unit" -p ActiveState --value)
      [[ "$state" == inactive || "$state" == failed ]] && break
      sleep 1
    done
    state=$(systemctl show "$client_unit" -p ActiveState --value)
    if [[ "$state" != inactive && "$state" != failed ]]; then
      red 'Процесс не завершился вовремя; принудительная остановка выбранного сервиса.'
      systemctl kill --signal=SIGKILL --kill-whom=all "$client_unit" || true
      for ((attempt=0; attempt<5; attempt++)); do
        state=$(systemctl show "$client_unit" -p ActiveState --value)
        [[ "$state" == inactive || "$state" == failed ]] && break
        sleep 1
      done
    fi
    state=$(systemctl show "$client_unit" -p ActiveState --value)
    [[ "$state" == inactive || "$state" == failed ]] || fail 'Сервис не остановлен. Файлы профиля сохранены; повторите действие после проверки журнала.'
    green "Сервис $client_unit остановлен."
  done
  rm -f -- "$conf/encryption-key" "$conf/client-link.txt"
  touch "$conf/revoked"
  chmod 600 "$conf/revoked"
  if [[ -f "$conf/firewall" ]]; then
    read -r kind reserved_port < "$conf/firewall"
    [[ "$reserved_port" =~ ^[0-9]{4,5}$ ]] || fail 'Неверные метаданные порта; профиль оставлен отключённым.'
    case "$kind" in
      ufw) ufw delete allow "$reserved_port/tcp" ;;
      firewalld)
        firewall-cmd --remove-port="$reserved_port/tcp"
        firewall-cmd --permanent --remove-port="$reserved_port/tcp" ;;
      *) fail 'Неизвестные метаданные firewall; профиль оставлен отключённым.' ;;
    esac
  fi
  rm -rf -- "$conf" "/var/lib/openflux-node/$channel"
  systemctl reset-failed "openflux-managed@$channel" >/dev/null 2>&1 || true
  audit_event delete "$channel" done
  red 'Клиент удалён. Правило в панели провайдера VPS, если есть, удалите отдельно.'
  exit 0
fi
if [[ "$action" == 1 ]]; then
  preflight inspect
  apt-get update
  apt-get install -y curl ca-certificates openssl python3 iproute2 coreutils tar
  preflight installed-tools
  if [[ ! -x "$BIN" ]]; then
    check_or_update install
  else
    echo 'Используется существующее ядро; обновление и замена не выполняются.'
  fi
  if ! id openflux-node >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin openflux-node
  fi
  install -d -m 755 "$BASE" /var/lib/openflux-node
fi
preflight installed
# Intermediate directories created under umask 077 must be traversable by the service user.
chmod 755 /opt/openflux-node /opt/openflux-node/bin
id openflux-node >/dev/null 2>&1 || fail 'Нет пользователя openflux-node. Выполните первую настройку.'
for tool in python3 openssl ss curl; do command -v "$tool" >/dev/null || fail "Не найден $tool; выполните первую настройку."; done
ensure_unit

while :; do
  ask 'Уникальное имя клиента (например iphone-2): ' channel
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo 'Нужны a-z, 0-9, дефис; до 31 символа.'; continue; }
  if [[ -e "$BASE/$channel" || -e "/var/lib/openflux-node/$channel" || -e "/etc/systemd/system/openflux-managed@$channel.service" || -e "/etc/systemd/system/openflux-node@$channel.service" ]]; then
    echo 'Это имя уже занято.'; continue
  fi
  break
done
printf '\n1) Яндекс Документы (vyandex)\n2) Телемост\n3) Яндекс Доска\n4) Mail.ru Документы\n5) Cups.online\n'
ask 'Выберите 1–5: ' service
case "$service" in
  1) transport=vyandex
     printf 'Откройте '; web_link 'https://docs.yandex.ru/'; printf ' → Создать → Текстовый документ.\n'
     echo 'Поделиться → Редактирование по ссылке, без пароля и срока действия.'
     echo 'Откройте редактор и скопируйте адрес https://docs.yandex.ru/edit/d/…'
     echo 'Возможна капча на сервере и устройстве; её показ зависит от клиента.' ;;
  2) transport=telemost
     printf 'Откройте '; web_link 'https://telemost.yandex.ru/'; printf ' и создайте новую видеовстречу.\n'
     echo 'Скопируйте приглашение https://telemost.yandex.ru/j/…'
     echo 'Используйте отдельную встречу для каждого устройства. Вкладку можно закрыть.'
     echo 'Телемост экспериментальный; некоторые версии Mac работают только в режиме прокси.' ;;
  3) transport=boards
     printf 'Откройте '; web_link 'https://boards.yandex.ru/'; printf '\n'
     echo 'Создайте отдельную доску → Поделиться → доступ на редактирование по ссылке.'
     echo 'Скопируйте приглашение с параметром ?hash=… (его нельзя удалять).'
     echo 'Может потребоваться вход или капча на обеих сторонах.' ;;
  4) transport=mailru
     printf 'Откройте '; web_link 'https://cloud.mail.ru/'; printf '\n'
     echo 'Создайте отдельный текстовый документ. Через Поделиться откройте доступ по ссылке.'
     echo 'Разрешите редактирование и скопируйте https://cloud.mail.ru/public/…/…'
     echo 'Если сервис требует вход, его нужно пройти в клиенте; доступность зависит от сборки.' ;;
  5) transport=cupsonline
     printf 'Сервис: '; web_link 'https://interview.cups.online/live-coding/'; printf '\n'
     echo 'Обычная ссылка сайта не подходит: OpenFlux использует упакованный список комнат.'
     echo '1) Создать комнаты автоматически штатным мастером OpenFlux'
     echo '2) Вставить ссылки существующих комнат или готовый список'
     ask 'Выберите 1 или 2: ' cups_choice
     case "$cups_choice" in
       1)
         echo 'Будет создан один небольшой набор комнат. При отказе не повторяйте запрос многократно.'
         ask 'Создать комнаты Cups.online? [Y/n]: ' reply
         [[ -z "$reply" || "$reply" == y || "$reply" == Y ]] || exit 0
         TEMP=$(mktemp)
         printf '%s\n' '{"id":1,"method":"createRooms","params":{}}' | timeout 150 "$BIN" --node-wizard > "$TEMP" || fail 'Не удалось создать комнаты; проверьте сеть и версию ядра.'
         cups_input=$(python3 - "$TEMP" <<'PY'
import json,sys
for line in open(sys.argv[1]):
 try: d=json.loads(line)
 except ValueError: continue
 if d.get('id')==1:
  if not d.get('ok') or not isinstance(d.get('rooms'),str): sys.exit(d.get('error','Нет списка комнат в ответе'))
  print(d['rooms']); break
else: sys.exit('Мастер не вернул ответ createRooms')
PY
) || fail 'Мастер не вернул список комнат.' ;;
       2)
         echo 'Откройте live-coding в браузере и скопируйте URL с ?room=UUID.'
         echo 'Можно вставить несколько отдельных комнат через пробел или готовую base64url-строку OpenFlux.'
         echo 'Для каждого клиента используйте свои комнаты; не создавайте лишние комнаты.'
         ask 'Ссылки комнат или упакованный список: ' cups_input ;;
       *) fail 'Неверный пункт Cups.online.' ;;
     esac ;;
  *) fail 'Неверный транспорт.' ;;
esac
while :; do
  if [[ "$transport" == cupsonline ]]; then
    raw_url=$cups_input
  else
    ask 'Вставьте ссылку: ' raw_url
  fi
  if url=$(python3 - "$transport" "$raw_url" <<'PY'
import base64,json,re,sys,urllib.parse as U,uuid
kind,raw=sys.argv[1:]; raw=raw.strip()
def stop(): sys.exit('Неподходящий формат ссылки/комнат')
if kind=='cupsonline':
 try:
  if raw.startswith('https://'):
   ids=[]
   for value in raw.split():
    u=U.urlsplit(value)
    if u.scheme!='https' or u.netloc!='interview.cups.online' or u.path.rstrip('/')!='/live-coding': stop()
    ids.append(str(uuid.UUID(U.parse_qs(u.query)['room'][0])))
  else:
   ids=json.loads(base64.urlsafe_b64decode(raw+'='*(-len(raw)%4)))
  if not isinstance(ids,list) or not 1<=len(ids)<=8 or any(not isinstance(x,str) for x in ids): stop()
  ids=[str(uuid.UUID(x)) for x in ids]
  if len(set(ids))!=len(ids): stop()
  print(base64.urlsafe_b64encode(json.dumps(ids,separators=(',',':')).encode()).decode().rstrip('='))
 except (ValueError,KeyError,TypeError): stop()
else:
 u=U.urlsplit(raw)
 if u.scheme!='https' or u.username or u.password: stop()
 if kind=='boards':
  value=U.parse_qs(u.query).get('hash',[''])[0]
  if u.netloc!='boards.yandex.ru' or not re.fullmatch(r'[A-Za-z0-9_=-]{8,512}',value): stop()
  print('https://boards.yandex.ru/guest/?'+U.urlencode({'hash':value}))
 elif kind=='mailru':
  if u.netloc!='cloud.mail.ru' or not re.fullmatch(r'/public/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/?',u.path): stop()
  print('https://cloud.mail.ru'+u.path.rstrip('/'))
 elif kind=='telemost':
  if u.netloc!='telemost.yandex.ru' or not re.fullmatch(r'/j/[0-9]+',u.path): stop()
  print('https://telemost.yandex.ru'+u.path)
 elif kind=='vyandex':
  if not re.fullmatch(r'(docs|disk)\.yandex\.(ru|com|by|kz|uz)',u.netloc) or not re.fullmatch(r'/edit/d/[A-Za-z0-9_-]{16,200}',u.path): stop()
  print('https://'+u.netloc+u.path)
 else: stop()
PY
); then break; fi
  if [[ "$transport" == cupsonline ]]; then
    ask 'Введите корректные ссылки комнат или список (пусто — отмена): ' cups_input
    [[ -n "$cups_input" ]] || exit 0
  fi
done
# Reject reusing a meeting/document already assigned by any of our installers.
if python3 - "$BASE" "$url" <<'PY'
import pathlib,sys
found=any(any(line.strip()=="URL = "+sys.argv[2] for line in p.read_text(errors="replace").splitlines()) for p in pathlib.Path(sys.argv[1]).rglob("node.conf"))
sys.exit(0 if found else 1)
PY
then
  fail 'Эта ссылка уже назначена другому профилю. Создайте отдельную встречу/документ.'
fi
if [[ "$transport" == cupsonline ]]; then
  echo "Список комнат проверен: $url"
else
  printf 'Выбрана ссылка: '; web_link "$url"; printf '\n'
fi
transport_status "$transport"
backup=no
ask 'Добавить резервное прямое соединение direct? [y/N]: ' reply
[[ "$reply" != y && "$reply" != Y ]] || backup=yes
port=''; host=''; firewall=none
if [[ "$backup" == yes ]]; then
  while :; do
    ask 'Публичный IP или DNS-имя VPS: ' host
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] && break
    echo 'Введите IPv4 или DNS-имя (без схемы и порта).'
  done
  # Reserve listener ports and ports recorded in existing OpenFlux configs, including stopped channels.
  port=$(python3 - "$BASE" <<'PY'
import pathlib,re,socket,sys
reserved=set()
for p in pathlib.Path(sys.argv[1]).rglob('*'):
    if p.is_file() and p.name in ('node.conf','port'):
        text=p.read_text(errors='replace')
        if p.name=='port' and text.strip().isdigit(): reserved.add(int(text.strip()))
        for m in re.finditer(r'(?im)^\s*(?:Listen|DirectListen)\s*=.*:(\d+)\s*$',text): reserved.add(int(m[1]))
for port in range(28443,60000):
    if port in reserved: continue
    sockets=[]
    try:
        for family,addr in ((socket.AF_INET,('0.0.0.0',port)),(socket.AF_INET6,('::',port))):
            if family==socket.AF_INET6 and not socket.has_ipv6: continue
            s=socket.socket(family); sockets.append(s)
            if family==socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
            s.bind(addr)
        print(port); break
    except OSError: pass
    finally:
        for s in sockets: s.close()
else: sys.exit('Нет свободного порта')
PY
)
  echo "Выбран свободный TCP-порт $port."
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then firewall=ufw
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then firewall=firewalld
  elif command -v nft >/dev/null && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then
    fail 'Обнаружены пользовательские nftables-правила. Добавьте разрешение порта вручную или запустите без direct; скрипт не изменяет чужие цепочки.'
  elif command -v iptables-save >/dev/null && iptables-save 2>/dev/null | grep -Eq '^-A |^:INPUT DROP|^:INPUT REJECT'; then
    fail 'Обнаружены пользовательские iptables-правила. Настройте UFW/firewalld или запустите без direct.'
  fi
fi
printf '\nКлиент: %s; транспорт: %s; резерв direct: %s\n' "$channel" "$transport" "$backup"
ask 'Создать профиль и запустить сервис? [Y/n]: ' reply
[[ -z "$reply" || "$reply" == y || "$reply" == Y ]] || exit 0
conf="$BASE/$channel"; state="/var/lib/openflux-node/$channel"
mkdir "$conf"; CREATED=$channel
chmod 751 "$conf"; chown root:openflux-node "$conf"
touch "$conf/.managed-by-setup"
chmod 600 "$conf/.managed-by-setup"
install -d -m 750 -o openflux-node -g openflux-node "$state"
openssl rand -hex 32 > "$conf/encryption-key"
cat > "$conf/node.conf" <<EOF
Role = exit
Mode = l4
URL = $url
EncryptionKeyFile = $conf/encryption-key
CookieStore = $state/cookies.json
EOF
if [[ "$backup" == no ]]; then
  printf 'Transport = %s\n' "$transport" >> "$conf/node.conf"
else
  printf '\n[Transport %s]\nType = %s\nPriority = 100\nURL = %s\n' "$transport" "$transport" "$url" >> "$conf/node.conf"
fi
if [[ "$backup" == yes ]]; then
  printf '\n[Transport direct]\nType = direct\nPriority = 50\nListen = 0.0.0.0:%s\n' "$port" >> "$conf/node.conf"
  echo "$port" > "$conf/port"
  if [[ "$firewall" == ufw ]]; then
    FW_PORT=$port; FW_KIND=ufw
    ufw allow "$port/tcp" comment "OpenFlux $channel"
  elif [[ "$firewall" == firewalld ]]; then
    FW_PORT=$port; FW_KIND=firewalld
    firewall-cmd --permanent --add-port="$port/tcp"
    firewall-cmd --add-port="$port/tcp"
  fi
fi
if [[ -n "$FW_KIND" ]]; then printf '%s %s\n' "$FW_KIND" "$port" > "$conf/firewall"; fi
chown root:openflux-node "$conf"/*; chmod 640 "$conf"/*
systemctl enable --now "openflux-managed@$channel"
sleep 5
if ! systemctl is-active --quiet "openflux-managed@$channel"; then
  journalctl -u "openflux-managed@$channel" -n 25 --no-pager -o cat >&2 || true
  fail 'Сервис не запустился. Причина показана выше; журнал сохранён в systemd.'
fi
TEMP=$(mktemp)
python3 - "$channel" "$url" "$transport" "$host" "$port" "$conf/encryption-key" <<'PY' > "$TEMP"
import json,sys,pathlib
name,url,transport,host,port,key=sys.argv[1:]
transports=[dict(type=transport,url=url,priority=100)]
if port: transports.append(dict(type='direct',dial=f'{host}:{port}',priority=50))
print(json.dumps(dict(name=name,negotiate=True,secret=pathlib.Path(key).read_text().strip(),context=url,transports=transports)))
PY
"$BIN" --make-link - < "$TEMP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["link"])' > "$conf/client-link.txt"
chmod 640 "$conf/client-link.txt"; chown root:openflux-node "$conf/client-link.txt"
SUCCESS=1
audit_event add "$channel" done
green 'Сервис запущен. Ссылка подключения (содержит секрет, не публикуйте):'
printf '%s' "$BLUE"
cat "$conf/client-link.txt"
printf '%s' "$RESET"
green "Ссылка сохранена: $conf/client-link.txt"
echo "Журнал: journalctl -u openflux-managed@$channel -n 50 --no-pager"
if [[ "$backup" == yes ]]; then
  echo "Разрешите также TCP $port в сетевом экране провайдера VPS."
  [[ "$firewall" != none ]] || echo 'Активный управляемый сетевой экран не обнаружен; сервис слушает порт. Не включайте UFW без разрешения SSH.'
fi
echo 'Исходящий HTTPS и UDP/WebRTC должны быть разрешены. Скрипт не меняет правила исходящего трафика.'
echo 'Импортируйте ссылку в OpenFlux и проверьте сайты/внешний IP: active не гарантирует работу туннеля.'
echo 'Если журнал сообщает classic-mode frames / Session peers only, требуется согласовать версии клиента и сервера.'
