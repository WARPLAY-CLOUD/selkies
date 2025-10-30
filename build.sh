#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
DISTRIB_IMAGE="${DISTRIB_IMAGE:-ubuntu}"
DISTRIB_RELEASE="${DISTRIB_RELEASE:-24.04}"
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

# Параметры сборки
BUILD_PYTHON=${BUILD_PYTHON:-true}
BUILD_WEB=${BUILD_WEB:-true}
BUILD_JS_INTERPOSER=${BUILD_JS_INTERPOSER:-false}
BUILD_GSTREAMER=${BUILD_GSTREAMER:-false}

# Проверка на root (для Linux не обязательно, но желательно иметь доступ к docker)
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
echo "  [$([ "$BUILD_PYTHON" = "true" ] && echo "x" || echo " ")] Python wheel"
echo "  [$([ "$BUILD_WEB" = "true" ] && echo "x" || echo " ")] Web интерфейс"
echo "  [$([ "$BUILD_JS_INTERPOSER" = "true" ] && echo "x" || echo " ")] JS Interposer (DEB)"
echo "  [$([ "$BUILD_GSTREAMER" = "true" ] && echo "x" || echo " ")] GStreamer bundle (займет 30-60 мин!)"
echo ""

# Создать директорию dist
mkdir -p "${REPO_ROOT}/dist"

# ========================================
# 1. Python wheel
# ========================================
if [ "$BUILD_PYTHON" = "true" ]; then
    echo -e "${GREEN}[1/4] Сборка Python wheel...${NC}"
    echo -e "${CYAN}  → Запуск Docker контейнера с Python 3.11${NC}"
    
    docker run --rm \
        -v "${REPO_ROOT}:/workspace" \
        -w /workspace \
        python:3.11-slim bash -c "
            set -e
            echo '  → Установка build инструментов...'
            pip install --no-cache-dir --quiet build wheel setuptools
            
            echo '  → Патчим версию в pyproject.toml...'
            sed -i 's/^version = .*/version = \"${VERSION}\"/' pyproject.toml
            
            echo '  → Запуск python -m build --wheel...'
            python -m build --wheel
            
            echo '  → Python wheel собран!'
        " 2>&1 | grep -v "WARNING\|Requirement already satisfied" || true
    
    # Найти созданный wheel
    WHL_FILE=$(ls -t "${REPO_ROOT}/dist/"*.whl 2>/dev/null | head -n1)
    
    if [ -n "${WHL_FILE}" ]; then
        WHL_NAME=$(basename "${WHL_FILE}")
        echo -e "${GREEN}  ✓ Python wheel: ${WHL_NAME}${NC}"
        
        # Проверка структуры (опционально)
        if command -v python3 >/dev/null 2>&1; then
            if python3 -m zipfile -l "${WHL_FILE}" 2>/dev/null | grep -q "selkies_gstreamer/__main__.py"; then
                echo -e "${GREEN}    ✓ Структура корректна (найден selkies_gstreamer/__main__.py)${NC}"
            else
                echo -e "${YELLOW}    ⚠ Структура пакета может отличаться${NC}"
            fi
        fi
    else
        echo -e "${RED}  ✗ Не удалось собрать Python wheel${NC}"
        exit 1
    fi
    echo ""
fi

# ========================================
# 2. Web интерфейс
# ========================================
if [ "$BUILD_WEB" = "true" ]; then
    echo -e "${GREEN}[2/4] Сборка Web интерфейса...${NC}"
    echo -e "${CYAN}  → Использование Dockerfile для gst-web${NC}"
    
    # Собрать Docker образ с web интерфейсом
    docker build \
        -t gst-web:latest \
        -f "${REPO_ROOT}/addons/gst-web/Dockerfile" \
        "${REPO_ROOT}/addons/gst-web" \
        2>&1 | grep -E "(Step|Successfully)" || true
    
    # Извлечь архив из образа
    echo -e "${CYAN}  → Извлечение gst-web.tar.gz из образа...${NC}"
    CONTAINER_ID=$(docker create gst-web:latest)
    docker cp "${CONTAINER_ID}:/opt/gst-web.tar.gz" "${REPO_ROOT}/dist/gst-web_v${VERSION}.tar.gz"
    docker rm "${CONTAINER_ID}" >/dev/null
    
    if [ -f "${REPO_ROOT}/dist/gst-web_v${VERSION}.tar.gz" ]; then
        echo -e "${GREEN}  ✓ Web интерфейс: gst-web_v${VERSION}.tar.gz${NC}"
        
        # Проверка структуры
        if tar -tzf "${REPO_ROOT}/dist/gst-web_v${VERSION}.tar.gz" | grep -q "gst-web/index.html"; then
            echo -e "${GREEN}    ✓ Структура корректна (найден gst-web/index.html)${NC}"
        else
            echo -e "${YELLOW}    ⚠ Структура архива может отличаться${NC}"
        fi
    else
        echo -e "${RED}  ✗ Не удалось создать архив web интерфейса${NC}"
        exit 1
    fi
    echo ""
fi

# ========================================
# 3. JS Interposer (опционально)
# ========================================
if [ "$BUILD_JS_INTERPOSER" = "true" ]; then
    echo -e "${GREEN}[3/4] Сборка JS Interposer...${NC}"
    echo -e "${CYAN}  → Сборка DEB пакета для ${DISTRIB_IMAGE}${DISTRIB_RELEASE}${NC}"
    
    if [ ! -f "${REPO_ROOT}/addons/js-interposer/Dockerfile.debpkg" ]; then
        echo -e "${YELLOW}  ⚠ Dockerfile.debpkg не найден, пропускаем${NC}"
    else
        # Собрать образ
        docker build \
            --build-arg DISTRIB_IMAGE="${DISTRIB_IMAGE}" \
            --build-arg DISTRIB_RELEASE="${DISTRIB_RELEASE}" \
            --build-arg PKG_NAME="selkies-js-interposer" \
            --build-arg PKG_VERSION="${VERSION}" \
            --build-arg DEBFULLNAME="Build User" \
            --build-arg DEBEMAIL="build@localhost" \
            -t selkies-js-interposer-builder \
            -f "${REPO_ROOT}/addons/js-interposer/Dockerfile.debpkg" \
            "${REPO_ROOT}/addons/js-interposer" \
            2>&1 | grep -E "(Step|Successfully)" || true
        
        # Извлечь .deb и .tar.gz
        echo -e "${CYAN}  → Извлечение артефактов...${NC}"
        CONTAINER_ID=$(docker create selkies-js-interposer-builder)
        
        docker cp "${CONTAINER_ID}:/opt/selkies-js-interposer_${VERSION}.deb" \
            "${REPO_ROOT}/dist/selkies-js-interposer_${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" 2>/dev/null || \
            echo -e "${YELLOW}    ⚠ Не удалось извлечь .deb${NC}"
        
        docker cp "${CONTAINER_ID}:/opt/selkies-js-interposer_${VERSION}.tar.gz" \
            "${REPO_ROOT}/dist/selkies-js-interposer_${VERSION}.tar.gz" 2>/dev/null || \
            echo -e "${YELLOW}    ⚠ Не удалось извлечь .tar.gz${NC}"
        
        docker rm "${CONTAINER_ID}" >/dev/null
        
        if [ -f "${REPO_ROOT}/dist/selkies-js-interposer_${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" ]; then
            echo -e "${GREEN}  ✓ JS Interposer: selkies-js-interposer_${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb${NC}"
        else
            echo -e "${YELLOW}  ⚠ JS Interposer не собран (это опциональный компонент)${NC}"
        fi
    fi
    echo ""
fi

# ========================================
# 4. GStreamer bundle (долгая сборка!)
# ========================================
if [ "$BUILD_GSTREAMER" = "true" ]; then
    echo -e "${GREEN}[4/4] Сборка GStreamer bundle...${NC}"
    echo -e "${YELLOW}  ⚠ ВНИМАНИЕ: Это займет 30-60 минут!${NC}"
    echo -e "${YELLOW}  ⚠ Нажмите Ctrl+C в течение 5 секунд, чтобы отменить...${NC}"
    sleep 5
    
    echo -e "${CYAN}  → Сборка для ${DISTRIB_IMAGE}:${DISTRIB_RELEASE}${NC}"
    
    if [ ! -f "${REPO_ROOT}/addons/gstreamer/Dockerfile" ]; then
        echo -e "${RED}  ✗ Dockerfile для GStreamer не найден${NC}"
        exit 1
    fi
    
    # Собрать образ GStreamer
    echo -e "${CYAN}  → Компиляция GStreamer (может занять очень долго)...${NC}"
    docker build \
        --build-arg DISTRIB_IMAGE="${DISTRIB_IMAGE}" \
        --build-arg DISTRIB_RELEASE="${DISTRIB_RELEASE}" \
        -t selkies-gstreamer-builder:latest \
        -f "${REPO_ROOT}/addons/gstreamer/Dockerfile" \
        "${REPO_ROOT}/addons/gstreamer" 2>&1 | \
        tee /tmp/gstreamer-build.log | \
        grep -E "(Step|Successfully|ERROR)" || true
    
    # Проверить успешность сборки
    if ! docker images | grep -q "selkies-gstreamer-builder"; then
        echo -e "${RED}  ✗ Сборка GStreamer не удалась, смотрите /tmp/gstreamer-build.log${NC}"
        exit 1
    fi
    
    # Извлечь tarball
    echo -e "${CYAN}  → Извлечение tarball из образа...${NC}"
    CONTAINER_ID=$(docker create selkies-gstreamer-builder:latest)
    docker cp "${CONTAINER_ID}:/opt/selkies-gstreamer-latest.tar.gz" \
        "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz"
    docker rm "${CONTAINER_ID}" >/dev/null
    
    if [ -f "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" ]; then
        echo -e "${GREEN}  ✓ GStreamer bundle: gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz${NC}"
        
        # Показать размер
        SIZE=$(du -h "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" | cut -f1)
        echo -e "${GREEN}    Размер: ${SIZE}${NC}"
    else
        echo -e "${RED}  ✗ Не удалось извлечь GStreamer tarball${NC}"
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

ARTIFACT_COUNT=0

if [ -f "${REPO_ROOT}/dist/"*.whl ]; then
    WHL=$(ls -t "${REPO_ROOT}/dist/"*.whl 2>/dev/null | head -n1)
    SIZE=$(du -h "${WHL}" | cut -f1)
    echo -e "  ${GREEN}✓${NC} $(basename ${WHL}) (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi

if [ -f "${REPO_ROOT}/dist/gst-web_v${VERSION}.tar.gz" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/gst-web_v${VERSION}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} gst-web_v${VERSION}.tar.gz (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi

if [ -f "${REPO_ROOT}/dist/selkies-js-interposer_${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/selkies-js-interposer_${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb" | cut -f1)
    echo -e "  ${GREEN}✓${NC} selkies-js-interposer_${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.deb (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi

if [ -f "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" ]; then
    SIZE=$(du -h "${REPO_ROOT}/dist/gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} gstreamer-selkies_gpl_v${VERSION}_${DISTRIB_IMAGE}${DISTRIB_RELEASE}_${ARCH}.tar.gz (${SIZE})"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
fi

echo ""
echo -e "${BLUE}Статус:${NC} ${ARTIFACT_COUNT} артефакт(ов) собрано"
echo ""

# Минимально необходимые компоненты
REQUIRED_COUNT=0
[ -f "${REPO_ROOT}/dist/"*.whl ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
[ -f "${REPO_ROOT}/dist/gst-web_v${VERSION}.tar.gz" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))

if [ ${REQUIRED_COUNT} -eq 2 ]; then
    echo -e "${GREEN}✓ Минимально необходимые артефакты готовы!${NC}"
    echo ""
    echo -e "${BLUE}Следующие шаги:${NC}"
    echo "  1. Скопировать артефакты на целевую систему"
    echo "  2. Установить GStreamer (из системных репозиториев или собранный bundle)"
    echo "  3. Установить Python wheel:"
    WHL=$(ls -t "${REPO_ROOT}/dist/"*.whl 2>/dev/null | head -n1)
    echo "     pip3 install $(basename ${WHL})"
    echo "  4. Развернуть web интерфейс в /opt/gst-web"
    echo ""
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

