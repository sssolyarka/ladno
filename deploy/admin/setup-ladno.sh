#!/bin/bash
# Debian 13 / existing Pterodactyl Wings + Nginx. No panel credentials required.
set -euo pipefail
umask 077
ladno_stage=prepare
ladno_dir=/opt/ladno
ladno_port=18080
ladno_upstream=127.0.0.1
ladno_cert=/etc/letsencrypt/live/makar.frogville.fun/fullchain.pem
ladno_key=/etc/letsencrypt/live/makar.frogville.fun/privkey.pem
ladno_url=https://github.com/sssolyarka/ladno/releases/download/v0.3.0/ladno-pterodactyl-admin.zip
ladno_sha=0c4f777629aba48028901310f02a49fe4567c0c42e8d1551dd41a4be2095635d
ladno_temp=
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Ладно — Debian 13 + Pterodactyl + существующий Nginx

  sudo bash setup-ladno.sh prepare [--dir /opt/ladno]
  sudo bash setup-ladno.sh build   [--dir /opt/ladno]
  sudo bash setup-ladno.sh sources [--dir /opt/ladno]
  sudo bash setup-ladno.sh proxy   --port 18080 --upstream-host 127.0.0.1 \
    --cert /путь/fullchain.pem --key /путь/privkey.pem [--dir /opt/ladno]
  sudo bash setup-ladno.sh check   --port 18080 --upstream-host 127.0.0.1

prepare  Скачать комплект 0.3.0, проверить закреплённый SHA-256, собрать образ.
build    Повторить только сборку из уже подготовленных исходников.
sources  Скачать только исходники для отдельной машины Nginx, без Docker.
proxy    Проверить контейнер и сертификат, добавить новый сайт Nginx.
check    Проверить, что HTTP allocation и HTTPS-домен ведут к одному серверу.

Домен: makar.frogville.fun. Порт — реальный allocation, 18080 только пример.
Порты 80/443 не освобождаются; конфигурации других сайтов не меняются.
EGG импортирует администратор панели. Docker и Wings уже должны быть установлены.
Скрипт не запрашивает пароль панели, не устанавливает Docker и не меняет firewall.
HELP
}
while (($#)); do
  case "$1" in
    prepare|build|sources|proxy|check) ladno_stage=$1; shift;;
    --dir) ladno_dir=${2:?Укажите каталог}; shift 2;;
    --port) ladno_port=${2:?Укажите порт}; shift 2;;
    --upstream-host) ladno_upstream=${2:?Укажите IPv4}; shift 2;;
    --cert) ladno_cert=${2:?Укажите сертификат}; shift 2;;
    --key) ladno_key=${2:?Укажите ключ}; shift 2;;
    -h|--help) usage; exit 0;;
    *) usage >&2; fail "Неизвестный аргумент: $1";;
  esac
done
[[ $ladno_port =~ ^[0-9]{1,5}$ ]] || fail 'Порт должен быть числом от 1024 до 65535'
ladno_port=$((10#$ladno_port))
((ladno_port>=1024 && ladno_port<=65535)) || fail 'Порт должен быть от 1024 до 65535, не 80 или 443'
[[ $ladno_dir =~ ^/(opt|srv)/[a-zA-Z0-9_./-]+$ ]] || fail 'Каталог исходников должен находиться внутри /opt или /srv, без пробелов'
[[ $ladno_dir != */../* && $ladno_dir != */.. ]] || fail 'Компоненты .. в пути запрещены'
((EUID==0)) || fail 'Этот скрипт должен выполнять администратор через sudo'
[[ -r /etc/os-release ]] || fail 'Не найдена информация об ОС'
# Read system-owned OS metadata, not an application/environment file.
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || fail 'Этот комплект проверяется для Debian 13'
for ladno_cmd in curl python3; do
  command -v "$ladno_cmd" >/dev/null || fail "Нужен $ladno_cmd. Установите: apt-get update && apt-get install -y curl ca-certificates python3"
done
python3 - "$ladno_upstream" "$ladno_dir" <<'PY'
import ipaddress,sys
from pathlib import Path
ipaddress.IPv4Address(sys.argv[1])
p=Path(sys.argv[2])
if p.resolve()!=p:
    raise SystemExit('Путь исходников не должен проходить через символические ссылки')
PY
cleanup() { if [[ -n $ladno_temp ]]; then rm -rf -- "$ladno_temp"; fi; }
trap cleanup EXIT
curl_https() { curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --show-error --silent --location --connect-timeout 10 --max-time 180 "$@"; }
verify_local() {
  ladno_temp=${ladno_temp:-$(mktemp -d /tmp/ladno-setup.XXXXXXXX)}
  curl --fail --show-error --silent --connect-timeout 3 --max-time 10 "http://$ladno_upstream:$ladno_port/health" > "$ladno_temp/local-health.json"
  python3 - "$ladno_temp/local-health.json" <<'PY'
import json,sys,uuid
v=json.load(open(sys.argv[1]))
assert v.get('ok') is True and v.get('protocol')==1, 'Порт не возвращает health Ладно'
uuid.UUID(v['deviceId'])
PY
}
build_image() {
  command -v docker >/dev/null || fail 'Docker должен быть установлен и настроен администратором узла Wings'
  docker info >/dev/null
  [[ -f $ladno_dir/deploy/pterodactyl/Dockerfile && -f $ladno_dir/server/pubspec.lock ]] || fail 'Нет подготовленных исходников. Сначала выполните prepare'
  bash "$ladno_dir/deploy/admin/build-image.sh"
}
fetch_sources() {
    [[ ! -e $ladno_dir && ! -L $ladno_dir ]] || fail "Каталог $ladno_dir уже существует. Для повторной сборки используйте build; данные не перезаписываются"
    ladno_temp=$(mktemp -d /tmp/ladno-setup.XXXXXXXX)
    printf '%s\n' 'Загрузка проверенного комплекта Ладно 0.3.0…'
    curl_https --max-filesize 10485760 --output "$ladno_temp/source.zip" "$ladno_url"
    python3 - "$ladno_temp/source.zip" "$ladno_sha" "$ladno_temp" <<'PY'
import hashlib,stat,sys,zipfile
from pathlib import PurePosixPath
archive,expected,directory=sys.argv[1:]
with open(archive,'rb') as source:
    if hashlib.file_digest(source,'sha256').hexdigest()!=expected:
        raise SystemExit('SHA-256 не совпадает; установка остановлена')
with zipfile.ZipFile(archive) as z:
    for member in z.infolist():
        p=PurePosixPath(member.filename)
        if p.is_absolute() or '..' in p.parts or '\\' in member.filename or not p.parts or p.parts[0]!='ladno-pterodactyl' or stat.S_ISLNK(member.external_attr >> 16):
            raise SystemExit('Недопустимый путь в архиве')
    z.extractall(directory)
print('SHA-256 и пути архива проверены')
PY
    mkdir -p -- "$(dirname -- "$ladno_dir")"
    mkdir -- "$ladno_dir"
    cp -a -- "$ladno_temp/ladno-pterodactyl/." "$ladno_dir/"
}
case "$ladno_stage" in
  prepare)
    command -v docker >/dev/null || fail 'Сначала администратор должен настроить Docker/Wings'
    docker info >/dev/null
    fetch_sources
    build_image
    printf '\nОбраз готов. Дальше в административной панели:\n'
    printf '1. Импортировать EGG: %s/deploy/pterodactyl/egg-ladno.json\n' "$ladno_dir"
    printf '%s\n' '2. Создать сервер с образом ladno-backend:pterodactyl и свободным allocation.'
    printf '%s\n' '3. Выделить от 1 ГБ RAM и 15 ГБ диска, запустить сервер.'
    printf '%s\n' '4. Закрыть внешний прямой HTTP-доступ к allocation, сохранив доступ Nginx с хоста.'
    printf '5. Выполнить этап proxy с реальными портом, IP и путями сертификата.\n'
    ;;
  build)
    build_image
    ;;
  sources)
    fetch_sources
    printf "Исходники для Nginx подготовлены в %s; Docker не требуется.\n" "$ladno_dir"
    ;;
  proxy)
    for ladno_cmd in nginx systemctl; do command -v "$ladno_cmd" >/dev/null || fail "Нужен существующий $ladno_cmd"; done
    [[ -f $ladno_dir/deploy/admin/configure-nginx.sh ]] || fail 'Сначала выполните prepare на узле Wings или sources на машине Nginx'
    [[ -s $ladno_cert && -s $ladno_key ]] || fail 'Сертификат/ключ отсутствует или пуст'
    nginx -t
    ladno_existing_nginx=$(nginx -T 2>/dev/null)
    if grep -Eq 'server_name[^;]*makar[.]frogville[.]fun' <<< "$ladno_existing_nginx"; then
      fail 'Сайт makar.frogville.fun уже есть. Администратор должен объединить конфигурацию вручную; другой сайт не перезаписан'
    fi
    unset ladno_existing_nginx
    verify_local
    bash "$ladno_dir/deploy/admin/configure-nginx.sh" --apply --port "$ladno_port" --upstream-host "$ladno_upstream" --cert "$ladno_cert" --key "$ladno_key" --output "$ladno_temp/nginx.conf"
    printf '%s\n' 'Сайт Nginx добавлен. Теперь выполните check с тем же портом и IP.'
    ;;
  check)
    verify_local
    curl_https --output "$ladno_temp/public-health.json" https://makar.frogville.fun/health
    python3 - "$ladno_temp/local-health.json" "$ladno_temp/public-health.json" <<'PY'
import json,sys
local=json.load(open(sys.argv[1]));public=json.load(open(sys.argv[2]))
assert public.get('ok') is True and public.get('protocol')==1 and public.get('deviceId')==local.get('deviceId'), 'Домен ведёт не к этому контейнеру'
print('HTTPS-сертификат проверен; домен и allocation ведут к одному бэкенду')
PY
    printf '%s\n' 'В приватной консоли Pterodactyl: invite. Код ввести в приложении 0.3.0; для каждого устройства отдельный код.'
    ;;
esac
