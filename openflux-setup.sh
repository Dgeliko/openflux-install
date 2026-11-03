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

cleanup() {
  local rc=$?
  [[ -z "$TEMP" ]] || rm -f -- "$TEMP"
  if [[ -n "$CREATED" && "$SUCCESS" != 1 ]]; then
    systemctl disable --now "openflux-managed@$CREATED" >/dev/null 2>&1 || true
    if [[ "$FW_KIND" == ufw ]]; then ufw delete allow "$FW_PORT/tcp" >/dev/null 2>&1 || true; fi
    if [[ "$FW_KIND" == firewalld ]]; then
      firewall-cmd --remove-port="$FW_PORT/tcp" >/dev/null 2>&1 || true
      firewall-cmd --permanent --remove-port="$FW_PORT/tcp" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$BASE/$CREATED" "/var/lib/openflux-node/$CREATED"
    echo 'Добавление клиента не завершено; созданный профиль удалён.' >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
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
  local units=()
  while IFS= read -r unit; do
    [[ -n "$unit" ]] && units+=("$unit")
  done < <(systemctl list-units 'openflux-managed@*.service' 'openflux-node@*.service' 'openflux-telemost@*.service' --state=active --no-legend --plain | awk '{print $1}')
  old_target=$(readlink "$BIN")
  ln -sfn "openflux-$latest" "$BIN"
  for unit in "${units[@]}"; do
    echo "Перезапуск $unit…"
    systemctl restart "$unit" || failed=1
  done
  sleep 5
  for unit in "${units[@]}"; do systemctl is-active --quiet "$unit" || failed=1; done
  if [[ "$failed" == 1 ]]; then
    red 'Сбой запуска — возвращаю прежнее ядро.'
    ln -sfn "$old_target" "$BIN"
    for unit in "${units[@]}"; do systemctl restart "$unit" || true; done
    fail 'Обновление не прошло проверку. Прежняя версия восстановлена; проверьте журналы каналов.'
  fi
  green "Ядро обновлено до $latest. Прежний бинарник сохранён для ручного отката."
  echo 'Проверьте передачу трафика на устройствах: active не гарантирует совместимость туннеля.'
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
echo
red 'Удаление останавливает сервис и удаляет профиль, ключ и cookies.'
echo '0) Выход'
ask 'Выберите 0–7: ' action
[[ "$action" != 0 ]] || break
    if [[ ! "$action" =~ ^[1-7]$ ]]; then
      red 'Неверный пункт.'
      continue
    fi
    # A fresh process resets operation variables and preserves errexit/rollback.
    set +e
    bash "$script_path" --run-menu-action "$action"
    result=$?
    set -e
    if [[ "$result" != 0 ]]; then
      red "Операция завершилась с ошибкой (код $result). Можно выбрать другой пункт."
    fi
    IFS= read -r -p 'Нажмите Enter для возврата в главное меню…' pause || break
  done
  exit 0
fi
action=${2:-}
[[ "$action" =~ ^[1-7]$ ]] || fail 'Неверный пункт.'
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
  red 'Клиент удалён. Правило в панели провайдера VPS, если есть, удалите отдельно.'
  exit 0
fi
if [[ "$action" == 1 ]]; then
  command -v apt-get >/dev/null || fail 'Первая установка поддерживает Ubuntu/Debian.'
  apt-get update
  apt-get install -y curl ca-certificates openssl python3 iproute2
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
[[ -x "$BIN" ]] || fail 'Сначала выполните первую настройку сервера.'
# Intermediate directories created under umask 077 must be traversable by the service user.
chmod 755 /opt/openflux-node /opt/openflux-node/bin
id openflux-node >/dev/null 2>&1 || fail 'Нет пользователя openflux-node. Выполните первую настройку.'
for tool in python3 openssl ss curl; do command -v "$tool" >/dev/null || fail "Не найден $tool; выполните первую настройку."; done
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
