#!/bin/sh
# 维护者用：构建两个镜像并导出成可发布的离线 tar。
#
#   sh scripts/build-and-save-images.sh [VERSION]      # 默认 1.0.0
#
# 产物：dist/wg-portal-userspace-images-v<VERSION>.tar.gz
#   内含 wg-backend:<VERSION> + wg-portal:<VERSION> 两个镜像，
#   使用者一条 `gunzip -c … | docker load` 即可（见 README「离线部署」）。
#
# 注意：本脚本需要**能联网**（backend 要 apt 装 wireguard-go/wireguard-tools，
# portal 要 npm ci + go mod download）。受限网络可给 docker 配代理，或按 README
# 的说明换成国内镜像源后再构建。
set -eu

VERSION="${1:-1.0.0}"
OUT_DIR="${OUT_DIR:-dist}"

cd "$(dirname "$0")/.."
mkdir -p "$OUT_DIR"

echo "==> building wg-backend:$VERSION"
docker build -t "wg-backend:$VERSION" ./backend

echo "==> building wg-portal:$VERSION"
docker build -t "wg-portal:$VERSION" --build-arg "BUILD_VERSION=$VERSION" ./portal

TAR="$OUT_DIR/wg-portal-userspace-images-v$VERSION.tar.gz"
echo "==> saving to $TAR"
docker save "wg-backend:$VERSION" "wg-portal:$VERSION" | gzip -9 > "$TAR"

echo "==> done: $TAR ($(du -h "$TAR" | cut -f1))"
echo "    docker load -i $TAR   # 在目标机器上"
