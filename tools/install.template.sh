#!/bin/sh
# Keenetic TUN Panel. Entware must already be installed on USB.
set -eu
umask 077
export PATH=/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:$PATH
APP_COMMIT=bcffb595af46bac72727c8a5b05ea82635b58efa
APP_SHA=d06448df4d7ab95da20ee7ecfc90c2283545e4955d21b10d07538af1e8f616eb
CORE_VERSION=v1.19.32
CORE_SHA=9dd862e28b46ff7d775f169cceebc28deccaa0a9e804237d421cd2571e0caba0
PAYLOAD_SHA=@PAYLOAD_SHA@
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
MODE=${1:-install}
case "$MODE" in install|--check|--restore|--extract) ;; *) die 'Использование: install.sh [--check | --restore ПУТЬ | --extract КАТАЛОГ]' ;; esac
if [ "$MODE" != --extract ]; then
    [ "$(id -u)" = 0 ] || die 'Запустите от root в SSH Entware.'
    [ -x /opt/bin/opkg ] && [ -d /opt/etc/init.d ] || die 'Сначала установите Entware на USB.'
    [ "$(uname -m)" = aarch64 ] || die 'Эта сборка проверена только для ARM64 (aarch64).'
    command -v ndmc >/dev/null || die 'Требуется KeeneticOS с командой ndmc.'
    [ -c /dev/net/tun ] || die 'Нет /dev/net/tun. Установите компонент поддержки TUN/TAP в KeeneticOS.'
    DEVICE=$(df -P /opt | awk 'END {print $1}')
    case "$DEVICE" in /dev/sd*) ;; *) die "Entware должен находиться на USB, сейчас /opt: $DEVICE" ;; esac
fi
if [ "$MODE" = install ]; then
    FREE=$(df -Pk /opt | awk 'END {print $4}')
    [ "$FREE" -ge 262144 ] || die 'Нужно не менее 256 МБ свободного места на USB.'
    echo 'Установка зависимостей Entware…'
    opkg update
    opkg install curl ca-bundle python3-light python3-urllib python3-openssl python3-logging python3-unittest python3-uuid python3-yaml python3-sqlite3 python3-codecs ip-full iptables ipset conntrack coreutils-nohup
fi
if [ "$MODE" = --extract ]; then
    [ "$#" -eq 2 ] || die 'Укажите новый каталог для распаковки.'
    [ ! -e "$2" ] || die 'Каталог уже существует.'
    mkdir -p "$2"
    STAGE=$2
else
    mkdir -p /opt/tmp
    STAGE=$(mktemp -d /opt/tmp/keenetic-tun.XXXXXX)
    cleanup() { rm -rf "$STAGE"; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
# Extract from this saved file, never from shell stdin (interactive prompts need tty).
sed '1,/^__PAYLOAD_BELOW__$/d' "$0" | base64 -d > "$STAGE/addon.tar.gz"
printf '%s  %s\n' "$PAYLOAD_SHA" "$STAGE/addon.tar.gz" | sha256sum -c - >/dev/null || die 'Повреждён встроенный архив.'
tar -xzf "$STAGE/addon.tar.gz" -C "$STAGE"
[ "$MODE" != --extract ] || { echo "Распаковано: $STAGE"; exit 0; }
if [ "$MODE" = --check ]; then
    python3 "$STAGE/installer.py" --check
    exit
fi
if [ "$MODE" = --restore ]; then
    [ "$#" -eq 2 ] || die 'Укажите каталог резервной копии.'
    python3 "$STAGE/installer.py" --restore "$2"
    exit
fi
echo 'Загрузка закреплённых версий панели и Mihomo…'
curl --proto '=https' --proto-redir '=https' -fLsS --retry 3 --connect-timeout 20 --max-time 240 "https://codeload.github.com/avatarDD/zapret-gui/tar.gz/$APP_COMMIT" -o "$STAGE/gui.tar.gz"
printf '%s  %s\n' "$APP_SHA" "$STAGE/gui.tar.gz" | sha256sum -c - >/dev/null || die 'SHA256 панели не совпал.'
curl --proto '=https' --proto-redir '=https' -fLsS --retry 3 --connect-timeout 20 --max-time 240 "https://github.com/MetaCubeX/mihomo/releases/download/$CORE_VERSION/mihomo-linux-arm64-$CORE_VERSION.gz" -o "$STAGE/mihomo.gz"
printf '%s  %s\n' "$CORE_SHA" "$STAGE/mihomo.gz" | sha256sum -c - >/dev/null || die 'SHA256 Mihomo не совпал.'
mkdir "$STAGE/upstream"
tar -xzf "$STAGE/gui.tar.gz" -C "$STAGE/upstream" --strip-components=1
gzip -dc "$STAGE/mihomo.gz" > "$STAGE/mihomo"
chmod 755 "$STAGE/mihomo"
# Ensure vendored Bottle can import on modular Entware Python before stopping anything.
python3 "$STAGE/installer.py" --deps "$STAGE/upstream"
python3 "$STAGE/installer.py" --install "$STAGE"
exit 0
__PAYLOAD_BELOW__
