#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Скрипт сборки Selkies-GStreamer
#
# Использование:
#   ./build.sh                                    # Собрать всё (с возможностью пропустить GStreamer)
#   BUILD_GSTREAMER=false ./build.sh              # Пропустить GStreamer полностью
#   BUILD_JS_INTERPOSER=false ./build.sh          # Пропустить JS Interposer
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
PKG_NAME="${PKG_NAME:-selkies-js-interposer}"
DISTRIB_IMAGE="${DISTRIB_IMAGE:-ubuntu}"
DISTRIB_RELEASE="${DISTRIB_RELEASE:-24.04}"
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

# Параметры сборки
BUILD_PYTHON=${BUILD_PYTHON:-true}
BUILD_WEB=${BUILD_WEB:-true}
BUILD_JS_INTERPOSER=${BUILD_JS_INTERPOSER:-true}
BUILD_GSTREAMER=${BUILD_GSTREAMER:-true}

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
echo ""
echo -e "${BLUE}Что будет собрано:${NC}"
echo "  [$([ "$BUILD_PYTHON" = "true" ] && echo "x" || echo " ")] Python wheel (обязательный)"
echo "  [$([ "$BUILD_WEB" = "true" ] && echo "x" || echo " ")] Web интерфейс (обязательный)"
echo "  [$([ "$BUILD_JS_INTERPOSER" = "true" ] && echo "x" || echo " ")] JS Interposer (опционально, ~30 сек)"
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
# 2. Web интерфейс - gst-web образ
# ========================================
if [ "$BUILD_WEB" = "true" ]; then
    echo -e "${GREEN}[2/4] Сборка Web интерфейса...${NC}"
    
    # Собрать Docker образ gst-web
    docker build \
        -t gst-web:latest \
        -f "${REPO_ROOT}/addons/gst-web/Dockerfile" \
        "${REPO_ROOT}/addons/gst-web" 2>&1 | grep -E "(Step|Successfully)" || true
    
    # Извлечь архив из образа
    echo -e "${CYAN}  → Извлечение архива из образа...${NC}"
    CONTAINER_ID=$(docker create gst-web:latest)
    docker cp "${CONTAINER_ID}:/opt/gst-web.tar.gz" \
        "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" || {
        echo -e "${RED}  ✗ Не удалось извлечь web архив${NC}"
        docker rm "${CONTAINER_ID}" >/dev/null
        exit 1
    }
    docker rm "${CONTAINER_ID}" >/dev/null
    
    if [ -f "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" ]; then
        echo -e "${GREEN}  ✓ Web интерфейс: selkies-gstreamer-web_v${VERSION}.tar.gz${NC}"
        
        # Проверка структуры
        if tar -tzf "${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz" 2>/dev/null | grep -q "gst-web/index.html"; then
            echo -e "${GREEN}    ✓ Структура корректна${NC}"
        fi
    else
        echo -e "${RED}  ✗ Не удалось создать web архив${NC}"
        exit 1
    fi
    echo ""
fi

# ========================================
# 3. JS Interposer (DEB пакет)
# ========================================
if [ "$BUILD_JS_INTERPOSER" = "true" ]; then
    echo -e "${GREEN}[3/4] Сборка JS Interposer...${NC}"
    
    # Собрать Docker образ с JS Interposer
    docker build \
        --build-arg DISTRIB_IMAGE="${DISTRIB_IMAGE}" \
        --build-arg DISTRIB_RELEASE="${DISTRIB_RELEASE}" \
        --build-arg PKG_NAME="${PKG_NAME}" \
        --build-arg PKG_VERSION="${VERSION}" \
        --build-arg DEBFULLNAME="Build User" \
        --build-arg DEBEMAIL="build@localhost" \
        -t selkies-js-interposer-builder:latest \
        -f "${REPO_ROOT}/addons/js-interposer/Dockerfile.debpkg" \
        "${REPO_ROOT}/addons/js-interposer" 2>&1 | grep -E "(Step|Successfully)" || true
    
    # Извлечь .deb из образа
    echo -e "${CYAN}  → Извлечение .deb пакета...${NC}"
    CONTAINER_ID=$(docker create selkies-js-interposer-builder:latest)
    docker cp "${CONTAINER_ID}:/opt/${PKG_NAME}_${VERSION}.deb" \
        "${REPO_ROOT}/dist/selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" 2>/dev/null || {
        echo -e "${YELLOW}  ⚠ Не удалось извлечь .deb (опциональный компонент)${NC}"
        docker rm "${CONTAINER_ID}" >/dev/null 2>&1
    }
    docker rm "${CONTAINER_ID}" >/dev/null 2>&1
    
    if [ -f "${REPO_ROOT}/dist/selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" ]; then
        echo -e "${GREEN}  ✓ JS Interposer: selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb${NC}"
    else
        echo -e "${YELLOW}  ⚠ JS Interposer не собран (опциональный компонент)${NC}"
    fi
    echo ""
else
    echo -e "${BLUE}[3/4] JS Interposer пропущен (отключен)${NC}"
    echo ""
fi

# ========================================
# 4. GStreamer bundle (долгая сборка!)
# ========================================
if [ "$BUILD_GSTREAMER" = "true" ]; then
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

if [ "$BUILD_GSTREAMER" = "true" ]; then
    echo -e "${CYAN}  → Сборка для ${DISTRIB_IMAGE}:${DISTRIB_RELEASE}${NC}"
    
    # Собрать Docker образ с GStreamer
    docker build \
        --build-arg DISTRIB_IMAGE="${DISTRIB_IMAGE}" \
        --build-arg DISTRIB_RELEASE="${DISTRIB_RELEASE}" \
        -t selkies-gstreamer-builder:latest \
        -f "${REPO_ROOT}/addons/gstreamer/Dockerfile" \
        "${REPO_ROOT}/addons/gstreamer" 2>&1 | \
        tee /tmp/gstreamer-build.log | \
        grep -E "(Step|Successfully|ERROR|ninja)" || true
    
    # Проверить успешность сборки
    if ! docker images | grep -q "selkies-gstreamer-builder"; then
        echo -e "${RED}  ✗ Сборка GStreamer не удалась${NC}"
        echo "  Смотрите /tmp/gstreamer-build.log"
        exit 1
    fi
    
    # Извлечь tarball из образа
    echo -e "${CYAN}  → Извлечение tarball из образа...${NC}"
    CONTAINER_ID=$(docker create selkies-gstreamer-builder:latest)
    docker cp "${CONTAINER_ID}:/opt/selkies-gstreamer-latest.tar.gz" \
        "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" || {
        echo -e "${RED}  ✗ Не удалось извлечь GStreamer tarball${NC}"
        docker rm "${CONTAINER_ID}" >/dev/null
        exit 1
    }
    docker rm "${CONTAINER_ID}" >/dev/null
    
    if [ -f "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" ]; then
        echo -e "${GREEN}  ✓ GStreamer bundle: gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz${NC}"
        SIZE=$(du -h "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" | cut -f1)
        echo -e "${GREEN}    Размер: ${SIZE}${NC}"
    else
        echo -e "${RED}  ✗ Не удалось создать GStreamer tarball${NC}"
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

# JS Interposer
if [ -f "${REPO_ROOT}/dist/selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" | cut -f1)
    echo -e "  ${GREEN}✓${NC} selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb (${SIZE})"
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
    echo -e "${GREEN}✓ Минимально необходимые артефакты готовы!${NC}"
    echo ""
    echo -e "${BLUE}Следующие шаги:${NC}"
    echo "  1. Установить Python wheel:"
    echo "     pip3 install dist/${PYPI_PACKAGE}-${VERSION}-py3-none-any.whl"
    echo ""
    echo "  2. Развернуть web интерфейс:"
    echo "     sudo tar -xzf dist/selkies-gstreamer-web_v${VERSION}.tar.gz -C /opt"
    echo ""
    if [ -f "${REPO_ROOT}/dist/selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" ]; then
        echo "  3. Установить JS Interposer (опционально):"
        echo "     sudo dpkg -i dist/selkies-js-interposer_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb"
        echo ""
    fi
    if [ -f "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" ]; then
        echo "  4. Установить GStreamer bundle:"
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
