# Скрипт сборки Selkies для Windows
# Использует Docker для кросс-платформенной сборки

param(
    [string]$UbuntuVersion = "22.04",
    [switch]$SkipGStreamer = $false,
    [switch]$SkipJSInterposer = $false
)

Write-Host "========================================" -ForegroundColor Green
Write-Host "Selkies Build Script (Windows)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

$ErrorActionPreference = "Stop"
$DistDir = Join-Path $PSScriptRoot "dist"

# Создать dist/ папку
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir | Out-Null
}

Write-Host "Configuration:" -ForegroundColor Blue
Write-Host "  Ubuntu Version: $UbuntuVersion"
Write-Host "  Output: $DistDir"
Write-Host ""

# ========================================
# 1. Python wheel
# ========================================
Write-Host "[1/4] Building Python wheel..." -ForegroundColor Green

docker run --rm `
    -v "${PSScriptRoot}:/workspace" `
    -w /workspace `
    python:3.11 bash -c @"
        pip install --no-cache-dir build wheel setuptools && \
        python -m build --wheel && \
        cp dist/*.whl /workspace/dist/ && \
        echo 'Python wheel built successfully'
"@

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to build Python wheel" -ForegroundColor Red
    exit 1
}

$whlFiles = Get-ChildItem -Path $DistDir -Filter "*.whl" -ErrorAction SilentlyContinue
if ($whlFiles) {
    Write-Host "✓ Python wheel: $($whlFiles[0].Name)" -ForegroundColor Green
} else {
    Write-Host "✗ No wheel file found" -ForegroundColor Red
    exit 1
}

# ========================================
# 2. Web interface
# ========================================
Write-Host "[2/4] Building web interface..." -ForegroundColor Green

docker run --rm `
    -v "${PSScriptRoot}:/workspace" `
    -w /workspace/addons/gst-web `
    ubuntu:$UbuntuVersion bash -c @"
        apt-get update && apt-get install -y tar gzip && \
        tar -czf /workspace/dist/selkies-gstreamer-web_v1.0.0.tar.gz src/ && \
        echo 'Web interface archive created'
"@

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Failed to build web interface" -ForegroundColor Red
    exit 1
}

if (Test-Path (Join-Path $DistDir "selkies-gstreamer-web_v1.0.0.tar.gz")) {
    Write-Host "✓ Web interface: selkies-gstreamer-web_v1.0.0.tar.gz" -ForegroundColor Green
} else {
    Write-Host "✗ Web archive not found" -ForegroundColor Red
    exit 1
}

# ========================================
# 3. JS Interposer (опционально)
# ========================================
if (-not $SkipJSInterposer) {
    Write-Host "[3/4] Building JS Interposer..." -ForegroundColor Green
    
    $jsDockerfile = Join-Path $PSScriptRoot "addons\js-interposer\Dockerfile.debpkg"
    if (Test-Path $jsDockerfile) {
        docker build `
            --build-arg DISTRIB_RELEASE=$UbuntuVersion `
            --build-arg PKG_VERSION="1.0.0" `
            -t selkies-js-interposer:local `
            -f $jsDockerfile `
            (Join-Path $PSScriptRoot "addons\js-interposer")
        
        if ($LASTEXITCODE -eq 0) {
            # Извлечь .deb из образа
            $containerId = docker create selkies-js-interposer:local
            docker cp "${containerId}:/opt/" "$env:TEMP\js-extract"
            docker rm $containerId | Out-Null
            
            # Найти .deb файлы
            $debFiles = Get-ChildItem -Path "$env:TEMP\js-extract" -Filter "*.deb" -Recurse -ErrorAction SilentlyContinue
            if ($debFiles) {
                Copy-Item $debFiles[0].FullName -Destination $DistDir
                Write-Host "✓ JS Interposer: $($debFiles[0].Name)" -ForegroundColor Green
            } else {
                Write-Host "⚠ JS Interposer not built (optional)" -ForegroundColor Yellow
            }
            
            Remove-Item -Recurse -Force "$env:TEMP\js-extract" -ErrorAction SilentlyContinue
        } else {
            Write-Host "⚠ JS Interposer build failed (optional)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠ JS Interposer Dockerfile not found (skipping)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[3/4] Skipping JS Interposer..." -ForegroundColor Yellow
}

# ========================================
# 4. GStreamer (опционально, долго!)
# ========================================
if (-not $SkipGStreamer) {
    Write-Host "[4/4] Building GStreamer bundle (30-60 minutes)..." -ForegroundColor Green
    Write-Host "  Press Ctrl+C within 5 seconds to skip..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    
    $gstDockerfile = Join-Path $PSScriptRoot "addons\gstreamer\Dockerfile"
    if (Test-Path $gstDockerfile) {
        docker build `
            --build-arg DISTRIB_RELEASE=$UbuntuVersion `
            -t selkies-gstreamer:local `
            -f $gstDockerfile `
            (Join-Path $PSScriptRoot "addons\gstreamer")
        
        if ($LASTEXITCODE -eq 0) {
            # Извлечь tarball
            $containerId = docker create selkies-gstreamer:local
            $arch = "amd64"  # Можно определить динамически
            $gstTarball = "gstreamer-selkies_gpl_v1.0.0_ubuntu${UbuntuVersion}_${arch}.tar.gz"
            
            docker cp "${containerId}:/opt/selkies-latest.tar.gz" (Join-Path $DistDir $gstTarball)
            docker rm $containerId | Out-Null
            
            if (Test-Path (Join-Path $DistDir $gstTarball)) {
                Write-Host "✓ GStreamer: $gstTarball" -ForegroundColor Green
            } else {
                Write-Host "⚠ GStreamer extraction failed (can use official release)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "⚠ GStreamer build failed (can use official release)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "⚠ GStreamer Dockerfile not found" -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/4] Skipping GStreamer (use official CDN release)..." -ForegroundColor Yellow
}

# ========================================
# Итоги
# ========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Build Summary" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Artifacts in dist/:" -ForegroundColor Blue

Get-ChildItem -Path $DistDir | ForEach-Object {
    Write-Host "  $($_.Name) ($([math]::Round($_.Length / 1MB, 2)) MB)"
}

Write-Host ""
Write-Host "✓ Build completed!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Integrate into docker-selkies-egl-desktop"
Write-Host "  2. Update Dockerfile to COPY from dist/"
Write-Host "  3. docker build -t selkies-ice:latest ."
Write-Host ""

