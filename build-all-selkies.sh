#!/bin/bash
set -e

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Selkies Components Build Script${NC}"
echo -e "${GREEN}With ICE/WebRTC Optimizations${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Определение версии из pyproject.toml или git тега
if [ -f "pyproject.toml" ]; then
    VERSION=$(grep -oP 'version = "\K[^"]+' pyproject.toml | head -n1)
fi

if [ -z "${VERSION}" ]; then
    VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo '')
    VERSION="${VERSION#v}"  # Убрать префикс 'v' если есть
fi

if [ -z "${VERSION}" ]; then
    VERSION="1.0.0"
    echo -e "${YELLOW}⚠ Version not found, using default: ${VERSION}${NC}"
fi

UBUNTU_VERSION="${UBUNTU_VERSION:-$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '\"')}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"

echo -e "${BLUE}Build Configuration:${NC}"
echo "  Version: ${VERSION}"
echo "  Ubuntu: ${UBUNTU_VERSION}"
echo "  Architecture: ${ARCH}"
echo ""

# Создать директорию для артефактов
mkdir -p dist
cd "$(dirname "$0")"
REPO_ROOT="$(pwd)"

echo -e "${YELLOW}Repository root: ${REPO_ROOT}${NC}"
echo ""

# =======================
# 1. Сборка Python wheel
# =======================
echo -e "${GREEN}[1/4] Building Python wheel package...${NC}"
python3 -m pip install --user --upgrade build wheel setuptools 2>/dev/null || \
    pip3 install --upgrade build wheel setuptools

if ! python3 -m build --wheel 2>&1 | tee /tmp/build-wheel.log; then
    echo -e "${YELLOW}⚠ Python build tool failed, trying direct setup.py${NC}"
    python3 setup.py bdist_wheel || {
        echo -e "${RED}✗ Failed to build Python wheel${NC}"
        cat /tmp/build-wheel.log
        exit 1
    }
fi

WHL_FILE=$(ls -t dist/selkies_gstreamer-*.whl 2>/dev/null | head -n1)
if [ -n "${WHL_FILE}" ]; then
    WHL_SIZE=$(du -h "${WHL_FILE}" | cut -f1)
    echo -e "${GREEN}✓ Python wheel built successfully${NC}"
    echo "  File: $(basename ${WHL_FILE})"
    echo "  Size: ${WHL_SIZE}"
else
    echo -e "${RED}✗ Failed to build Python wheel${NC}"
    exit 1
fi
echo ""

# ============================
# 2. Сборка Web интерфейса
# ============================
echo -e "${GREEN}[2/4] Building web interface...${NC}"
cd "${REPO_ROOT}/addons/gst-web"

# Проверка наличия оптимизаций
if grep -q "iceCandidatePoolSize" src/app.js; then
    echo -e "${GREEN}  ✓ ICE optimizations detected in code${NC}"
else
    echo -e "${YELLOW}  ⚠ ICE optimizations not found - did you apply patches?${NC}"
fi

WEB_ARCHIVE="${REPO_ROOT}/dist/selkies-gstreamer-web_v${VERSION}.tar.gz"
echo "  Creating archive: $(basename ${WEB_ARCHIVE})"

# Упаковать src/ директорию
tar -czf "${WEB_ARCHIVE}" --transform='s|^src/||' src/

if [ -f "${WEB_ARCHIVE}" ]; then
    WEB_SIZE=$(du -h "${WEB_ARCHIVE}" | cut -f1)
    echo -e "${GREEN}✓ Web interface archive created${NC}"
    echo "  File: $(basename ${WEB_ARCHIVE})"
    echo "  Size: ${WEB_SIZE}"
    
    # Проверить содержимое
    echo "  Contents:"
    tar -tzf "${WEB_ARCHIVE}" | head -n5
    echo "  ..."
else
    echo -e "${RED}✗ Failed to create web archive${NC}"
    exit 1
fi
echo ""

# ============================
# 3. Сборка JS Interposer
# ============================
echo -e "${GREEN}[3/4] Building JS Interposer DEB package...${NC}"
cd "${REPO_ROOT}/addons/js-interposer"

# Попытка 1: Использовать build_deb.sh
if [ -f "./build_deb.sh" ]; then
    echo "  Using build_deb.sh script..."
    chmod +x ./build_deb.sh
    if ./build_deb.sh 2>&1 | tee /tmp/build-js-interposer.log; then
        DEB_FILE=$(ls -t selkies-js-interposer_*.deb 2>/dev/null | head -n1)
        if [ -n "${DEB_FILE}" ]; then
            mv "${DEB_FILE}" "${REPO_ROOT}/dist/"
            echo -e "${GREEN}✓ JS Interposer DEB package built${NC}"
            echo "  File: $(basename ${DEB_FILE})"
        fi
    fi
fi

# Попытка 2: Использовать Makefile
DEB_FILE=$(ls -t "${REPO_ROOT}/dist/selkies-js-interposer_*.deb" 2>/dev/null | head -n1)
if [ -z "${DEB_FILE}" ] && [ -f "Makefile" ]; then
    echo "  Trying Makefile..."
    if make 2>&1 | tee -a /tmp/build-js-interposer.log; then
        DEB_BUILT=$(ls -t *.deb 2>/dev/null | head -n1)
        if [ -n "${DEB_BUILT}" ]; then
            mv "${DEB_BUILT}" "${REPO_ROOT}/dist/"
            echo -e "${GREEN}✓ JS Interposer DEB package built${NC}"
        fi
    fi
fi

# Попытка 3: Docker build
DEB_FILE=$(ls -t "${REPO_ROOT}/dist/selkies-js-interposer_*.deb" 2>/dev/null | head -n1)
if [ -z "${DEB_FILE}" ] && [ -f "Dockerfile.debpkg" ]; then
    echo "  Trying Docker build..."
    if docker build -f Dockerfile.debpkg -t selkies-js-interposer-builder . 2>&1 | tail -n20; then
        docker run --rm -v "${REPO_ROOT}/dist:/output" selkies-js-interposer-builder \
            bash -c "cp /tmp/selkies-js-interposer_*.deb /output/ 2>/dev/null || \
                     cp *.deb /output/ 2>/dev/null || \
                     echo 'No DEB found in container'" && \
        echo -e "${GREEN}✓ JS Interposer DEB package built via Docker${NC}"
    fi
fi

# Проверка результата
DEB_FILE=$(ls -t "${REPO_ROOT}/dist/selkies-js-interposer_*.deb" 2>/dev/null | head -n1)
if [ -n "${DEB_FILE}" ]; then
    DEB_SIZE=$(du -h "${DEB_FILE}" | cut -f1)
    echo -e "${GREEN}✓ JS Interposer package available${NC}"
    echo "  File: $(basename ${DEB_FILE})"
    echo "  Size: ${DEB_SIZE}"
else
    echo -e "${YELLOW}⚠ JS Interposer DEB package build failed or skipped${NC}"
    echo "  You can try building manually or download from releases"
    echo "  Build log available at: /tmp/build-js-interposer.log"
fi
echo ""

# ============================
# 4. Сборка GStreamer бандла
# ============================
echo -e "${GREEN}[4/4] Building GStreamer bundle...${NC}"
cd "${REPO_ROOT}"

GSTREAMER_FILE="gstreamer-selkies_gpl_v${VERSION}_ubuntu${UBUNTU_VERSION}_${ARCH}.tar.gz"

# Проверить наличие существующего файла
if [ -f "dist/${GSTREAMER_FILE}" ]; then
    echo -e "${GREEN}✓ GStreamer bundle already exists in dist/${NC}"
    echo "  File: ${GSTREAMER_FILE}"
    echo "  Size: $(du -h "dist/${GSTREAMER_FILE}" | cut -f1)"
    echo "  Skipping rebuild (delete to force rebuild)"
elif [ -f "./dev/build-gstreamer-ubuntu${UBUNTU_VERSION}.sh" ]; then
    echo "  Using build script for Ubuntu ${UBUNTU_VERSION}..."
    echo "  This may take 30-60 minutes..."
    chmod +x "./dev/build-gstreamer-ubuntu${UBUNTU_VERSION}.sh"
    
    if "./dev/build-gstreamer-ubuntu${UBUNTU_VERSION}.sh" 2>&1 | tee /tmp/build-gstreamer.log; then
        # Поиск созданного файла
        BUILT_FILE=$(find . -name "gstreamer-selkies_gpl_*.tar.gz" -newer /tmp/build-gstreamer.log 2>/dev/null | head -n1)
        
        if [ -n "${BUILT_FILE}" ]; then
            mv "${BUILT_FILE}" "dist/${GSTREAMER_FILE}"
            echo -e "${GREEN}✓ GStreamer bundle built successfully${NC}"
        elif [ -f "${GSTREAMER_FILE}" ]; then
            mv "${GSTREAMER_FILE}" "dist/"
            echo -e "${GREEN}✓ GStreamer bundle built successfully${NC}"
        fi
    fi
    
    if [ -f "dist/${GSTREAMER_FILE}" ]; then
        GST_SIZE=$(du -h "dist/${GSTREAMER_FILE}" | cut -f1)
        echo "  File: ${GSTREAMER_FILE}"
        echo "  Size: ${GST_SIZE}"
    else
        echo -e "${YELLOW}⚠ GStreamer bundle build failed${NC}"
        echo "  This is a large build that may take significant time"
        echo "  Consider downloading from official releases"
        echo "  Build log: /tmp/build-gstreamer.log"
    fi
else
    echo -e "${YELLOW}⚠ GStreamer build script not found for Ubuntu ${UBUNTU_VERSION}${NC}"
    echo "  Available scripts:"
    ls -1 ./dev/build-gstreamer-*.sh 2>/dev/null | sed 's/^/    /' || echo "    None found"
    echo ""
    echo "  You can:"
    echo "    1. Download from official Selkies releases"
    echo "    2. Use a Docker-based build"
    echo "    3. Skip GStreamer (use pre-built from CDN)"
fi
echo ""

# =======================
# Вывод результатов
# =======================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Artifacts in dist/:"
echo ""

if [ -d "dist" ] && [ "$(ls -A dist/)" ]; then
    ls -lh dist/ | grep -v '^total' | awk '{printf "  %-10s  %s\n", $5, $9}'
    echo ""
    
    # Подсчёт статистики
    TOTAL_COUNT=$(ls -1 dist/ | wc -l)
    echo "Total artifacts: ${TOTAL_COUNT}"
    
    # Проверка обязательных артефактов
    REQUIRED_COUNT=0
    [ -f "dist/selkies_gstreamer-"*".whl" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
    [ -f "dist/selkies-gstreamer-web_"*".tar.gz" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
    [ -f "dist/gstreamer-selkies_gpl_"*".tar.gz" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
    [ -f "dist/selkies-js-interposer_"*".deb" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
    
    echo "Required artifacts: ${REQUIRED_COUNT}/4"
    echo ""
    
    if [ ${REQUIRED_COUNT} -eq 4 ]; then
        echo -e "${GREEN}✓ All artifacts built successfully!${NC}"
    elif [ ${REQUIRED_COUNT} -ge 2 ]; then
        echo -e "${YELLOW}⚠ Some artifacts missing (${REQUIRED_COUNT}/4)${NC}"
        echo "  You can still proceed with available artifacts"
    else
        echo -e "${RED}✗ Critical artifacts missing (${REQUIRED_COUNT}/4)${NC}"
        echo "  At least Python wheel and Web interface are required"
    fi
else
    echo -e "${RED}✗ No artifacts found in dist/${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Review artifacts in dist/ directory"
echo "  2. Upload to GitHub Releases:"
echo "     ${YELLOW}gh release create v${VERSION} dist/*${NC}"
echo "  3. Or copy to CDN:"
echo "     ${YELLOW}scp dist/* user@cdn.example.com:/path/${NC}"
echo "  4. Update docker-selkies-egl-desktop Dockerfile"
echo "  5. Build Docker image:"
echo "     ${YELLOW}cd docker-selkies-egl-desktop && docker build .${NC}"
echo ""
echo -e "${GREEN}✓ Build process completed!${NC}"
echo ""

