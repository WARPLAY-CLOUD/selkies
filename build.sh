#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Скрипт сборки Selkies-GStreamer
#
# Использование:
#   ./build.sh                                    # Собрать всё (gst-web-react по умолчанию)
#   WEB_VARIANT=gst-web ./build.sh                # Собрать с оригинальным gst-web (Vue.js)
#   WEB_VARIANT=gst-web-react ./build.sh          # Собрать с gst-web-react (React+TS, по умолчанию)
#   BUILD_GSTREAMER=false ./build.sh              # Пропустить GStreamer полностью
#   GSTREAMER_BUNDLE_SOURCE=cdn ./build.sh        # Скачать GStreamer bundle с CDN (кэш в dist/)
#   GSTREAMER_BUNDLE_SOURCE=build ./build.sh      # Всегда собирать GStreamer локально (медленно)
#   GSTREAMER_BUNDLE_SOURCE=auto ./build.sh       # (по умолчанию) взять локальный bundle -> CDN -> build
#   SELKIES_VERSION=1.7.0 ./build.sh              # Задать свою версию
#   DISTRIB_RELEASE=22.04 ./build.sh              # Для Ubuntu 22.04

set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Конфигурация
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${SELKIES_VERSION:-1.6.2+w}"
PYPI_PACKAGE="${PYPI_PACKAGE:-selkies_gstreamer}"
DISTRIB_IMAGE="${DISTRIB_IMAGE:-ubuntu}"
DISTRIB_RELEASE="${DISTRIB_RELEASE:-24.04}"
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

# Параметры сборки
BUILD_PYTHON=${BUILD_PYTHON:-true}
BUILD_WEB=${BUILD_WEB:-true}
BUILD_GSTREAMER=${BUILD_GSTREAMER:-true}
WEB_VARIANT=${WEB_VARIANT:-gst-web-react}  # gst-web-react (по умолчанию) или gst-web
# Где брать GStreamer bundle:
# - auto (default): reuse local tarball if present, otherwise download from CDN, otherwise build
# - cdn: download from CDN (cache in dist/)
# - build: build locally (slow)
GSTREAMER_BUNDLE_SOURCE=${GSTREAMER_BUNDLE_SOURCE:-auto}

# Ubuntu version fallback (prefer exact, otherwise fall back down).
release_fallbacks() {
    case "${DISTRIB_RELEASE}" in
        "24.04") echo "24.04 22.04 20.04" ;;
        "22.04") echo "22.04 20.04" ;;
        "20.04") echo "20.04" ;;
        *)
            # Keep user-provided value first, then common supported baselines.
            echo "${DISTRIB_RELEASE} 24.04 22.04 20.04" | awk '{for(i=1;i<=NF;i++) if(!seen[$i]++){printf "%s%s",$i,(i==NF?RS:OFS)}}'
            ;;
    esac
}

# Проверка варианта web интерфейса
if [ "$WEB_VARIANT" != "gst-web" ] && [ "$WEB_VARIANT" != "gst-web-react" ]; then
    echo -e "${RED}✗ Неверный WEB_VARIANT: ${WEB_VARIANT}${NC}"
    echo "  Допустимые значения: gst-web, gst-web-react"
    exit 1
fi

if [ ! -d "${REPO_ROOT}/addons/${WEB_VARIANT}" ]; then
    echo -e "${RED}✗ Директория ${WEB_VARIANT} не найдена в addons/${NC}"
    exit 1
fi

# Проверка Docker
if ! docker ps >/dev/null 2>&1; then
    echo -e "${RED}✗ Docker не доступен или не запущен${NC}"
    echo "  Убедитесь, что Docker установлен и у вас есть права на его использование"
    echo "  sudo usermod -aG docker \$USER"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Selkies-GStreamer Build Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Конфигурация:${NC}"
echo "  Корневой каталог: ${REPO_ROOT}"
echo "  Версия: ${VERSION}"
echo "  Дистрибутив: ${DISTRIB_IMAGE} ${DISTRIB_RELEASE}"
echo "  Архитектура: ${ARCH}"
echo "  Web вариант: ${WEB_VARIANT} $([ "$WEB_VARIANT" = "gst-web-react" ] && echo "(React+TypeScript)" || echo "(Vue.js)")"
echo "  GStreamer bundle source: ${GSTREAMER_BUNDLE_SOURCE}"
echo "  Ubuntu fallback order: $(release_fallbacks)"
echo ""
echo -e "${BLUE}Что будет собрано:${NC}"
echo "  [$([ "$BUILD_PYTHON" = "true" ] && echo "x" || echo " ")] Python wheel (обязательный)"
echo "  [$([ "$BUILD_WEB" = "true" ] && echo "x" || echo " ")] Web интерфейс (обязательный) - ${WEB_VARIANT}"
echo "  [x] Warplay control server (обязательный, Rust)"
echo "  [$([ "$BUILD_GSTREAMER" = "true" ] && echo "x" || echo " ")] GStreamer bundle (опционально, ~45 мин, можно пропустить)"
echo ""
if [ "$BUILD_GSTREAMER" = "true" ]; then
    echo -e "${CYAN}Подсказка: Для GStreamer будет 10-секундная пауза для отмены${NC}"
    echo ""
fi

# Создать директорию dist
mkdir -p "${REPO_ROOT}/dist"

# ========================================
# 1. Python wheel - py-build образ
# ========================================
if [ "$BUILD_PYTHON" = "true" ]; then
    echo -e "${GREEN}[1/4] Сборка Python wheel...${NC}"
    
    # Собрать Docker образ py-build
    docker build \
        --build-arg PYPI_PACKAGE="${PYPI_PACKAGE}" \
        --build-arg PACKAGE_VERSION="${VERSION}" \
        -t selkies-gstreamer-py-build:latest \
        -f "${REPO_ROOT}/Dockerfile" \
        "${REPO_ROOT}" 2>&1 | grep -E "(Step|Successfully built|writing)" || true
    
    # Извлечь wheel из образа
    echo -e "${CYAN}  → Извлечение wheel из образа...${NC}"
    CONTAINER_ID=$(docker create selkies-gstreamer-py-build:latest)
    docker cp "${CONTAINER_ID}:/opt/pypi/dist/${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl" \
        "${REPO_ROOT}/dist/" || {
        echo -e "${RED}  ✗ Не удалось извлечь wheel файл${NC}"
        docker rm "${CONTAINER_ID}" >/dev/null
        exit 1
    }
    docker rm "${CONTAINER_ID}" >/dev/null
    
    WHL_FILE="${REPO_ROOT}/dist/${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl"
    if [ -f "${WHL_FILE}" ]; then
        echo -e "${GREEN}  ✓ Python wheel: ${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl${NC}"
        
        # Проверка структуры
        if command -v python3 >/dev/null 2>&1; then
            if python3 -m zipfile -l "${WHL_FILE}" 2>/dev/null | grep -q "selkies_gstreamer/__main__.py"; then
                echo -e "${GREEN}    ✓ Структура корректна${NC}"
            fi
        fi
    else
        echo -e "${RED}  ✗ Не удалось создать Python wheel${NC}"
        exit 1
    fi
    echo ""
fi

# ========================================
# 2. Web интерфейс - gst-web или gst-web-react
# ========================================
if [ "$BUILD_WEB" = "true" ]; then
    echo -e "${GREEN}[2/4] Сборка Web интерфейса (${WEB_VARIANT})...${NC}"
    
    # Определяем Dockerfile и образ
    if [ "$WEB_VARIANT" = "gst-web-react" ]; then
        DOCKERFILE="${REPO_ROOT}/addons/gst-web-react/Dockerfile"
        WEB_IMAGE="gst-web-react:latest"
        WEB_DIR="gst-web-react"
        ARCHIVE_NAME="gst-web-react.tar.gz"
    else
        DOCKERFILE="${REPO_ROOT}/addons/gst-web/Dockerfile"
        WEB_IMAGE="gst-web:latest"
        WEB_DIR="gst-web"
        ARCHIVE_NAME="gst-web.tar.gz"
    fi
    
    # Проверяем наличие Dockerfile
    if [ ! -f "${DOCKERFILE}" ]; then
        echo -e "${YELLOW}  ⚠ Dockerfile не найден для ${WEB_VARIANT}, создаем...${NC}"
        
        # Создаем Dockerfile для gst-web-react если его нет
        if [ "$WEB_VARIANT" = "gst-web-react" ]; then
            cat > "${DOCKERFILE}" << 'EOF'
FROM node:18-alpine AS builder

WORKDIR /app

# Копируем package.json и package-lock.json
COPY package*.json ./

# Устанавливаем зависимости
RUN npm ci

# Копируем исходники
COPY . .

# Собираем проект
RUN npm run build

# Создаем финальный образ
FROM alpine:latest

WORKDIR /opt

# Копируем собранные файлы
COPY --from=builder /app/dist /opt/gst-web-react

# Создаем tar.gz архив
RUN cd /opt && tar -czf gst-web-react.tar.gz gst-web-react

CMD ["sh"]
EOF
            echo -e "${GREEN}    ✓ Dockerfile создан${NC}"
        fi
    fi
    
    # Собрать Docker образ
    echo -e "${CYAN}  → Сборка Docker образа...${NC}"
    docker build \
        -t "${WEB_IMAGE}" \
        -f "${DOCKERFILE}" \
        "${REPO_ROOT}/addons/${WEB_VARIANT}" 2>&1 | grep -E "(Step|Successfully)" || true
    
    # Извлечь архив из образа
    echo -e "${CYAN}  → Извлечение архива из образа...${NC}"
    CONTAINER_ID=$(docker create "${WEB_IMAGE}")
    docker cp "${CONTAINER_ID}:/opt/${ARCHIVE_NAME}" \
        "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" || {
        echo -e "${RED}  ✗ Не удалось извлечь web архив${NC}"
        docker rm "${CONTAINER_ID}" >/dev/null
        exit 1
    }
    docker rm "${CONTAINER_ID}" >/dev/null
    
    if [ -f "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" ]; then
        echo -e "${GREEN}  ✓ Web интерфейс: selkies-gstreamer-web_v${VERSION}.tar.gz${NC}"
        
        # Проверка структуры
        if tar -tzf "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" 2>/dev/null | grep -q "index.html"; then
            echo -e "${GREEN}    ✓ Структура корректна (${WEB_VARIANT})${NC}"
        fi
    else
        echo -e "${RED}  ✗ Не удалось создать web архив${NC}"
        exit 1
    fi
    echo ""
fi

# ========================================
# 3. Warplay control server (Rust) - warplay-linux-control (обязательный)
# ========================================
echo -e "${GREEN}[3/4] Сборка Warplay control server (warplay-linux-control)...${NC}"

    CONTROL_IMAGE="warplay-control-build:latest"
    CONTROL_BIN_NAME="warplay-linux-control"
    CONTROL_OUT="${REPO_ROOT}/dist/${CONTROL_BIN_NAME}"

    CONTROL_CONTEXT="${REPO_ROOT}/.."
    CONTROL_DOCKERFILE="${REPO_ROOT}/addons/warplay-control/Dockerfile"

    if [ ! -f "${CONTROL_DOCKERFILE}" ]; then
        echo -e "${RED}  ✗ Dockerfile для control server не найден: ${CONTROL_DOCKERFILE}${NC}"
        exit 1
    fi

    echo -e "${CYAN}  → Сборка Docker образа control server...${NC}"
    CONTROL_LOG="${REPO_ROOT}/dist/warplay-control-docker-build.log"
    docker build \
        -t "${CONTROL_IMAGE}" \
        -f "${CONTROL_DOCKERFILE}" \
        "${CONTROL_CONTEXT}" 2>&1 | tee "${CONTROL_LOG}"
    BUILD_STATUS="${PIPESTATUS[0]}"
    if [ "${BUILD_STATUS}" -ne 0 ]; then
        echo -e "${RED}  ✗ Docker build control server failed${NC}"
        echo -e "${RED}    Лог: ${CONTROL_LOG}${NC}"
        exit 1
    fi

    echo -e "${CYAN}  → Извлечение бинарника из образа...${NC}"
    CONTAINER_ID=$(docker create "${CONTROL_IMAGE}")
    docker cp "${CONTAINER_ID}:/opt/${CONTROL_BIN_NAME}" "${CONTROL_OUT}" || {
        echo -e "${RED}  ✗ Не удалось извлечь ${CONTROL_BIN_NAME}${NC}"
        docker rm "${CONTAINER_ID}" >/dev/null
        exit 1
    }
    docker rm "${CONTAINER_ID}" >/dev/null
    chmod +x "${CONTROL_OUT}" || true

    echo -e "${GREEN}  ✓ Control binary: ${CONTROL_OUT}${NC}"

    OVERLAY_DIR="${REPO_ROOT}/dist/copy_to_docker/usr/local/bin"
    mkdir -p "${OVERLAY_DIR}"
    cp -f "${CONTROL_OUT}" "${OVERLAY_DIR}/${CONTROL_BIN_NAME}"

    tar -czf "${REPO_ROOT}/dist/${CONTROL_BIN_NAME}_v${VERSION}_${ARCH}.tar.gz" -C "${REPO_ROOT}/dist" "${CONTROL_BIN_NAME}"
    echo -e "${GREEN}  ✓ Overlay: dist/copy_to_docker/usr/local/bin/${CONTROL_BIN_NAME}${NC}"
    echo -e "${GREEN}  ✓ Tarball: dist/${CONTROL_BIN_NAME}_v${VERSION}_${ARCH}.tar.gz${NC}"
    echo ""
echo ""

# ========================================
# 4. GStreamer bundle (долгая сборка!)
# ========================================
SELKIES_CDN_BASE_URL=${SELKIES_CDN_BASE_URL:-"https://cdn.warplay.cloud/drivers/linux/system/selkies/releases/download/v${VERSION}"}

validate_gstreamer_bundle() {
    local f="$1"
    if [ ! -f "$f" ]; then return 1; fi
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    [ "${sz}" -ge 10000000 ] || return 1
    gzip -t "$f" >/dev/null 2>&1 || return 1
    return 0
}

# Pick best available release for GStreamer bundle for current Ubuntu (prefer exact, then fall back).
GSTREAMER_EFFECTIVE_RELEASE="${DISTRIB_RELEASE}"
GSTREAMER_TARBALL_NAME=""
GSTREAMER_TARBALL=""
GSTREAMER_CDN_URL=""

select_gstreamer_release() {
    for REL in $(release_fallbacks); do
        local name="gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${REL}_${ARCH}.tar.gz"
        local cand="${REPO_ROOT}/dist/${name}"
        if validate_gstreamer_bundle "${cand}"; then
            GSTREAMER_EFFECTIVE_RELEASE="${REL}"
            GSTREAMER_TARBALL_NAME="${name}"
            GSTREAMER_TARBALL="${cand}"
            GSTREAMER_CDN_URL="${SELKIES_CDN_BASE_URL}/${name}"
            return 0
        fi
    done
    # Default to first choice for download/build attempts.
    GSTREAMER_TARBALL_NAME="gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz"
    GSTREAMER_TARBALL="${REPO_ROOT}/dist/${GSTREAMER_TARBALL_NAME}"
    GSTREAMER_CDN_URL="${SELKIES_CDN_BASE_URL}/${GSTREAMER_TARBALL_NAME}"
    return 1
}

# Initialize candidate vars (may update later after we find/download/build)
select_gstreamer_release || true

# 4a) Reuse local bundle / download from CDN (cache in dist/) before attempting a long local build.
if [ "${GSTREAMER_BUNDLE_SOURCE}" != "build" ]; then
    if select_gstreamer_release; then
        echo -e "${BLUE}[4/4] GStreamer bundle уже есть в dist/ (Ubuntu ${GSTREAMER_EFFECTIVE_RELEASE}), пропускаем сборку${NC}"
        BUILD_GSTREAMER=false
    fi

	    if [ "$BUILD_GSTREAMER" = "true" ]; then
	        # Try to find a valid local bundle in neighboring docker repo (prefer exact, then fall back)
	        for REL in $(release_fallbacks); do
	            for CAND in \
	                "${REPO_ROOT}/../docker-selkies-egl-desktop/install_to_docker/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${REL}_${ARCH}.tar.gz" \
	                "${REPO_ROOT}/../docker-selkies-egl-desktop/install_to_docker/selkies/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${REL}_${ARCH}.tar.gz" \
                "${REPO_ROOT}/../docker-selkies-egl-desktop/install_to_docker/gstreamer-selkies_gpl_v${VERSION}_ubuntu${REL}_${ARCH}.tar.gz" \
                "${REPO_ROOT}/../docker-selkies-egl-desktop/install_to_docker/selkies/gstreamer-selkies_gpl_v${VERSION}_ubuntu${REL}_${ARCH}.tar.gz" \
                ; do
                if validate_gstreamer_bundle "${CAND}"; then
                    GSTREAMER_EFFECTIVE_RELEASE="${REL}"
                    GSTREAMER_TARBALL_NAME="gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${REL}_${ARCH}.tar.gz"
                    GSTREAMER_TARBALL="${REPO_ROOT}/dist/${GSTREAMER_TARBALL_NAME}"
                    GSTREAMER_CDN_URL="${SELKIES_CDN_BASE_URL}/${GSTREAMER_TARBALL_NAME}"
                    echo -e "${BLUE}[4/4] Найден локальный GStreamer bundle (Ubuntu ${REL}): ${CAND}${NC}"
                    mkdir -p "${REPO_ROOT}/dist"
                    cp -f "${CAND}" "${GSTREAMER_TARBALL}" || true
                    if validate_gstreamer_bundle "${GSTREAMER_TARBALL}"; then
                        echo -e "${GREEN}  ✓ Используем локальный bundle (кэшировано в dist/)${NC}"
                        BUILD_GSTREAMER=false
                        break 2
                    else
                        rm -f "${GSTREAMER_TARBALL}" || true
                    fi
                fi
            done
        done
    fi

    if [ "$BUILD_GSTREAMER" = "true" ]; then
        echo -e "${CYAN}[4/4] GStreamer bundle не найден, пробуем скачать с CDN...${NC}"
        for REL in $(release_fallbacks); do
            GSTREAMER_EFFECTIVE_RELEASE="${REL}"
            GSTREAMER_TARBALL_NAME="gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${REL}_${ARCH}.tar.gz"
            GSTREAMER_TARBALL="${REPO_ROOT}/dist/${GSTREAMER_TARBALL_NAME}"
            GSTREAMER_CDN_URL="${SELKIES_CDN_BASE_URL}/${GSTREAMER_TARBALL_NAME}"
            echo -e "${CYAN}  → ${GSTREAMER_CDN_URL}${NC}"
            mkdir -p "${REPO_ROOT}/dist"
            if curl -fSL --retry 5 --retry-delay 3 --retry-connrefused -o "${GSTREAMER_TARBALL}" "${GSTREAMER_CDN_URL}"; then
                if validate_gstreamer_bundle "${GSTREAMER_TARBALL}"; then
                    SIZE_H=$(du -h "${GSTREAMER_TARBALL}" | cut -f1)
                    echo -e "${GREEN}  ✓ GStreamer bundle скачан и закэширован (Ubuntu ${REL}): ${GSTREAMER_TARBALL_NAME} (${SIZE_H})${NC}"
                    BUILD_GSTREAMER=false
                    break
                else
                    echo -e "${YELLOW}  ⚠ Скачанный bundle поврежден/маленький, удаляем${NC}"
                    rm -f "${GSTREAMER_TARBALL}" || true
                fi
            fi
        done

        if [ "$BUILD_GSTREAMER" = "true" ] && [ "${GSTREAMER_BUNDLE_SOURCE}" = "cdn" ]; then
            echo -e "${RED}  ✗ GSTREAMER_BUNDLE_SOURCE=cdn: CDN download failed for all fallback releases${NC}"
            exit 1
        fi
    fi
fi

if [ "$BUILD_GSTREAMER" = "true" ] && [ "${GSTREAMER_BUNDLE_SOURCE}" != "cdn" ]; then
    echo -e "${GREEN}[4/4] Сборка GStreamer bundle...${NC}"
    echo -e "${YELLOW}  ⚠ ВНИМАНИЕ: Это займет 30-60 минут!${NC}"
    echo -e "${YELLOW}  ⚠ Нажмите Ctrl+C в течение 10 секунд, чтобы пропустить...${NC}"
    
    # Обработка Ctrl+C для пропуска GStreamer
    SKIP_GSTREAMER=false
    trap 'SKIP_GSTREAMER=true' INT
    
    for i in {10..1}; do
        if [ "$SKIP_GSTREAMER" = "true" ]; then
            break
        fi
        echo -ne "  ${i}...\r"
        sleep 1
    done
    
    # Восстановить обработчик Ctrl+C
    trap - INT
    
    if [ "$SKIP_GSTREAMER" = "true" ]; then
        echo -e "  ${YELLOW}⚠ Сборка GStreamer пропущена${NC}                    "
        echo ""
        BUILD_GSTREAMER=false
    else
	    echo -e "  ${GREEN}Запускаем сборку GStreamer...${NC}                    "
	fi
fi

# If we skipped the local build, try downloading from CDN (auto) so downstream steps can still use the tarball.
if [ "$BUILD_GSTREAMER" = "false" ] && [ "${GSTREAMER_BUNDLE_SOURCE}" = "auto" ]; then
    # No-op if we already have a valid tarball (from dist/neighbor/CDN/build).
    :
fi

if [ "$BUILD_GSTREAMER" = "true" ] && [ "${GSTREAMER_BUNDLE_SOURCE}" != "cdn" ]; then
    GS_BUILT=false
    for REL in $(release_fallbacks); do
        echo -e "${CYAN}  → Сборка для ${DISTRIB_IMAGE}:${REL}${NC}"

        docker build \
            --build-arg DISTRIB_IMAGE="${DISTRIB_IMAGE}" \
            --build-arg DISTRIB_RELEASE="${REL}" \
            -t selkies-gstreamer-builder:latest \
            -f "${REPO_ROOT}/addons/gstreamer/Dockerfile" \
            "${REPO_ROOT}/addons/gstreamer" 2>&1 | \
            tee /tmp/gstreamer-build.log | \
            grep -E "(Step|Successfully|ERROR|ninja)" || true

        if ! docker images | grep -q "selkies-gstreamer-builder"; then
            echo -e "${YELLOW}  ⚠ Сборка GStreamer для ${REL} не удалась, пробуем следующий release${NC}"
            continue
        fi

        echo -e "${CYAN}  → Извлечение tarball из образа...${NC}"
        GSTREAMER_EFFECTIVE_RELEASE="${REL}"
        GSTREAMER_TARBALL_NAME="gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${REL}_${ARCH}.tar.gz"
        GSTREAMER_TARBALL="${REPO_ROOT}/dist/${GSTREAMER_TARBALL_NAME}"
        GSTREAMER_CDN_URL="${SELKIES_CDN_BASE_URL}/${GSTREAMER_TARBALL_NAME}"

        CONTAINER_ID=$(docker create selkies-gstreamer-builder:latest)
        docker cp "${CONTAINER_ID}:/opt/selkies-gstreamer-latest.tar.gz" "${GSTREAMER_TARBALL}" || {
            echo -e "${YELLOW}  ⚠ Не удалось извлечь tarball для ${REL}, пробуем следующий release${NC}"
            docker rm "${CONTAINER_ID}" >/dev/null 2>&1 || true
            rm -f "${GSTREAMER_TARBALL}" || true
            continue
        }
        docker rm "${CONTAINER_ID}" >/dev/null 2>&1 || true

        if validate_gstreamer_bundle "${GSTREAMER_TARBALL}"; then
            echo -e "${GREEN}  ✓ GStreamer bundle: ${GSTREAMER_TARBALL_NAME}${NC}"
            SIZE=$(du -h "${GSTREAMER_TARBALL}" | cut -f1)
            echo -e "${GREEN}    Размер: ${SIZE}${NC}"
            GS_BUILT=true
            break
        else
            echo -e "${YELLOW}  ⚠ Полученный tarball поврежден/маленький, пробуем следующий release${NC}"
            rm -f "${GSTREAMER_TARBALL}" || true
        fi
    done

    if [ "${GS_BUILT}" != "true" ]; then
        echo -e "${RED}  ✗ Сборка GStreamer не удалась ни для одного fallback-release${NC}"
        echo "  Смотрите /tmp/gstreamer-build.log"
        exit 1
    fi

    echo ""
fi

# ========================================
# Итоговый отчет
# ========================================
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Сборка завершена!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Артефакты в dist/:${NC}"
echo ""

# Подсчет артефактов
ARTIFACT_COUNT=0
REQUIRED_COUNT=0

# Python wheel
if [ -f "${REPO_ROOT}/dist/${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl" | cut -f1)
    echo -e "  ${GREEN}✓${NC} ${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
    REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
fi

# Web интерфейс
if [ -f "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} selkies-gstreamer-web_v${VERSION}.tar.gz (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
    REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
fi

# Warplay control server (обязательный)
if [ -f "${REPO_ROOT}/dist/warplay-linux-control" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/warplay-linux-control" | cut -f1)
    echo -e "  ${GREEN}✓${NC} warplay-linux-control (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi
if [ -f "${REPO_ROOT}/dist/warplay-linux-control_v${VERSION}_${ARCH}.tar.gz" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/warplay-linux-control_v${VERSION}_${ARCH}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} warplay-linux-control_v${VERSION}_${ARCH}.tar.gz (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi

# GStreamer
if [ -f "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi

echo ""
echo -e "${BLUE}Статус:${NC} ${ARTIFACT_COUNT} артефакт(ов) собрано"
echo ""

# Проверка минимальных требований
if [ ${REQUIRED_COUNT} -eq 2 ]; then
    echo -e "${GREEN}✓ Минимально необходимые артефакты готовы (wheel + web)!${NC}"
    echo ""
    echo -e "${BLUE}Следующие шаги:${NC}"
    echo "  1. Установить Python wheel:"
    echo "     pip3 install dist/${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl"
    echo ""
    echo "  2. Развернуть web интерфейс:"
    echo "     sudo tar -xzf dist/selkies-gstreamer-web_v${VERSION}.tar.gz -C /opt"
    echo ""
    if [ -f "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" ]; then
        echo "  3. Установить GStreamer bundle:"
        echo "     sudo tar -xzf dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz -C /opt"
        echo "     . /opt/gstreamer/gst-env"
        echo ""
    fi
    echo -e "${BLUE}Документация:${NC}"
    echo "  https://selkies-project.github.io/selkies-gstreamer/"
elif [ ${ARTIFACT_COUNT} -eq 0 ]; then
    echo -e "${RED}✗ Не создано ни одного артефакта${NC}"
    echo "  Проверьте логи выше"
    exit 1
else
    echo -e "${YELLOW}⚠ Собрано ${REQUIRED_COUNT}/2 обязательных артефактов${NC}"
    echo "  Необходимы: Python wheel + Web интерфейс"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Готово!${NC}"
echo -e "${GREEN}========================================${NC}"
