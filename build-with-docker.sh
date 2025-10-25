#!/bin/bash
set -e

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Selkies Docker Build Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.0.0"

echo -e "${BLUE}Configuration:${NC}"
echo "  Repository: ${REPO_ROOT}"
echo "  Version: ${VERSION}"
echo ""

mkdir -p dist

# ========================================
# 1. Python wheel - через Docker
# ========================================
echo -e "${GREEN}[1/4] Building Python wheel in Docker...${NC}"
docker run --rm \
    -v "${REPO_ROOT}:/workspace" \
    -w /workspace \
    python:3.11 bash -c "
        pip install --no-cache-dir build wheel setuptools && \
        python -m build --wheel && \
        echo 'Python wheel built successfully'
    "

WHL_FILE=$(ls -t dist/*.whl 2>/dev/null | head -n1)
if [ -n "${WHL_FILE}" ]; then
    echo -e "${GREEN}✓ Python wheel: $(basename ${WHL_FILE})${NC}"
else
    echo -e "${RED}✗ Failed to build Python wheel${NC}"
    exit 1
fi

# ========================================
# 2. Web интерфейс - через Docker
# ========================================
echo -e "${GREEN}[2/4] Building web interface in Docker...${NC}"
docker run --rm \
    -v "${REPO_ROOT}:/workspace" \
    -w /workspace/addons/gst-web \
    ubuntu:24.04 bash -c "
        tar -czf /workspace/dist/selkies-gstreamer-web_v${VERSION}.tar.gz src/ && \
        echo 'Web interface archive created'
    "

if [ -f "dist/selkies-gstreamer-web_v${VERSION}.tar.gz" ]; then
    echo -e "${GREEN}✓ Web interface: selkies-gstreamer-web_v${VERSION}.tar.gz${NC}"
else
    echo -e "${RED}✗ Failed to create web archive${NC}"
    exit 1
fi

# ========================================
# 3. JS Interposer (опционально)
# ========================================
echo -e "${GREEN}[3/4] Building JS Interposer (optional)...${NC}"
if [ -f "addons/js-interposer/Dockerfile.debpkg" ]; then
    echo "  Building DEB package via Docker..."
    
    # Сборка с обработкой ошибок
    if docker build \
        --build-arg DISTRIB_RELEASE="24.04" \
        --build-arg PKG_NAME="selkies-js-interposer" \
        --build-arg PKG_VERSION="1.0.0" \
        --build-arg DEBFULLNAME="Build User" \
        --build-arg DEBEMAIL="build@localhost" \
        -f addons/js-interposer/Dockerfile.debpkg \
        -t selkies-js-interposer-builder \
        addons/js-interposer/ 2>&1 | tee /tmp/js-build.log | tail -n20; then
        
        # Извлечь .deb из образа
        CONTAINER_ID=$(docker create selkies-js-interposer-builder)
        docker cp "${CONTAINER_ID}:/opt/" /tmp/js-interposer-extract/ 2>/dev/null || true
        docker rm "${CONTAINER_ID}" >/dev/null
        
        # Найти и скопировать .deb
        if find /tmp/js-interposer-extract -name "*.deb" -exec cp {} dist/ \; 2>/dev/null; then
            DEB_FILE=$(ls -t dist/selkies-js-interposer*.deb 2>/dev/null | head -n1)
            if [ -n "${DEB_FILE}" ]; then
                echo -e "${GREEN}✓ JS Interposer: $(basename ${DEB_FILE})${NC}"
            fi
        else
            echo -e "${YELLOW}  ⚠ JS Interposer .deb not found (optional)${NC}"
        fi
        rm -rf /tmp/js-interposer-extract
    else
        echo -e "${YELLOW}  ⚠ JS Interposer build failed (optional, can skip)${NC}"
        echo "  This component is optional for ICE optimizations."
    fi
else
    echo -e "${YELLOW}  ⚠ Skipping JS Interposer (no Dockerfile.debpkg)${NC}"
fi

# ========================================
# 4. GStreamer - через Docker (долго!)
# ========================================
echo -e "${GREEN}[4/4] Building GStreamer bundle...${NC}"
echo -e "${YELLOW}  ⚠ This will take 30-60 minutes!${NC}"
echo "  Press Ctrl+C within 5 seconds to skip GStreamer build..."
sleep 5

if [ -f "addons/gstreamer/Dockerfile" ]; then
    echo "  Building GStreamer via Docker..."
    
    # Определить Ubuntu версию
    UBUNTU_VERSION="24.04"
    ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
    
    # Собрать образ
    docker build \
        --build-arg DISTRIB_RELEASE="${UBUNTU_VERSION}" \
        -t selkies-gstreamer-builder \
        -f addons/gstreamer/Dockerfile \
        addons/gstreamer/ 2>&1 | tail -n50
    
    # Извлечь tarball из образа
    CONTAINER_ID=$(docker create selkies-gstreamer-builder)
    docker cp "${CONTAINER_ID}:/opt/selkies-latest.tar.gz" \
        "dist/gstreamer-selkies_gpl_v${VERSION}_ubuntu${UBUNTU_VERSION}_${ARCH}.tar.gz" && \
        echo -e "${GREEN}✓ GStreamer bundle created${NC}" || \
        echo -e "${YELLOW}⚠ Failed to extract GStreamer (can use official release)${NC}"
    docker rm "${CONTAINER_ID}"
else
    echo -e "${YELLOW}  ⚠ No GStreamer Dockerfile found${NC}"
    echo "  You can:"
    echo "    - Download from official releases"
    echo "    - Use CDN version in docker-selkies-egl-desktop"
fi

# ========================================
# Итоги
# ========================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Artifacts in dist/:"
ls -lh dist/ 2>/dev/null || echo "  (empty)"
echo ""

REQUIRED_COUNT=0
[ -f "dist/"*.whl ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))
[ -f "dist/selkies-gstreamer-web_"*".tar.gz" ] && REQUIRED_COUNT=$((REQUIRED_COUNT + 1))

echo "Status: ${REQUIRED_COUNT}/2 required artifacts built"
echo ""

if [ ${REQUIRED_COUNT} -eq 2 ]; then
    echo -e "${GREEN}✓ Minimum artifacts ready for docker-selkies-egl-desktop!${NC}"
    echo ""
    echo "Next steps:"
    echo "  cd ../docker-selkies-egl-desktop"
    echo "  # Update Dockerfile to use these artifacts"
    echo "  docker build -t selkies-ice:latest ."
elif [ ${REQUIRED_COUNT} -eq 1 ]; then
    echo -e "${YELLOW}⚠ Only 1/2 required artifacts built${NC}"
    echo "  Check errors above"
else
    echo -e "${RED}✗ Build failed - no artifacts created${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Build completed!${NC}"

