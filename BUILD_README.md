# Скрипт сборки Selkies-GStreamer

Простой bash-скрипт для сборки всех компонентов Selkies-GStreamer в Docker контейнерах.

## Быстрый старт

```bash
# Сделать скрипт исполняемым
chmod +x build.sh

# Запустить сборку
./build.sh
```

## Что собирается

### Обязательные компоненты (всегда включены):
1. **Python wheel** (`selkies_gstreamer-*.whl`) - основной код приложения
2. **Web интерфейс** (`gst-web_*.tar.gz`) - HTML5 клиент

### Опциональные компоненты (по умолчанию включены):
3. **JS Interposer** (`selkies-js-interposer_*.deb`) - оптимизация джойстиков (~30 секунд сборки)
4. **GStreamer bundle** (`gstreamer-selkies_*.tar.gz`) - кастомная сборка GStreamer (~45 минут!)

## Управление сборкой

### Пропустить GStreamer во время сборки
Когда скрипт дойдет до GStreamer, будет 10-секундный обратный отсчет:
```
[4/4] Сборка GStreamer bundle...
  ⚠ ВНИМАНИЕ: Это займет 30-60 минут!
  ⚠ Нажмите Ctrl+C в течение 10 секунд, чтобы пропустить...
  10...
```

**Нажмите Ctrl+C** чтобы пропустить GStreamer и продолжить сборку остальных компонентов.

### Отключить компоненты через переменные окружения

```bash
# Собрать только минимум (Python + Web)
BUILD_JS_INTERPOSER=false BUILD_GSTREAMER=false ./build.sh

# Собрать без GStreamer (но с JS Interposer)
BUILD_GSTREAMER=false ./build.sh

# Собрать без JS Interposer
BUILD_JS_INTERPOSER=false ./build.sh
```

### Изменить версию или дистрибутив

```bash
# Задать свою версию
SELKIES_VERSION=1.7.0 ./build.sh

# Для Ubuntu 22.04
DISTRIB_RELEASE=22.04 ./build.sh

# Для Debian 12
DISTRIB_IMAGE=debian DISTRIB_RELEASE=12 ./build.sh
```

## Результаты сборки

Все артефакты сохраняются в директорию `dist/`:

```
dist/
├── selkies_gstreamer-1.6.2+w-py3-none-any.whl            # Python пакет
├── gst-web_v1.6.2+w.tar.gz                               # Web интерфейс
├── selkies-js-interposer_1.6.2+w_ubuntu24.04_amd64.deb  # JS Interposer (опц.)
└── gstreamer-selkies_gpl_v1.6.2+w_ubuntu24.04_amd64.tar.gz  # GStreamer (опц.)
```

## Требования

- **Docker** установлен и запущен
- Права на запуск Docker (добавьте пользователя в группу `docker`)
- ~5 GB свободного места для сборки GStreamer
- Интернет соединение для загрузки зависимостей

## Время сборки

- Python wheel: ~30 секунд
- Web интерфейс: ~15 секунд
- JS Interposer: ~30 секунд
- GStreamer bundle: **30-60 минут** (можно пропустить)

**Итого без GStreamer:** ~1-2 минуты  
**Итого с GStreamer:** ~45-60 минут

## Альтернатива для GStreamer

Вместо сборки GStreamer bundle можно:

1. **Использовать системный GStreamer** (если версия >= 1.20):
   ```bash
   sudo apt install gstreamer1.0-*
   ```

2. **Скачать готовый bundle** из официальных релизов:
   https://github.com/selkies-project/selkies-gstreamer/releases

3. **Использовать Docker образ** с уже собранным GStreamer

## Установка артефактов

После успешной сборки:

```bash
# 1. Установить Python пакет
pip3 install dist/selkies_gstreamer-*.whl

# 2. Развернуть web интерфейс
sudo mkdir -p /opt/gst-web
sudo tar -xzf dist/gst-web_*.tar.gz -C /opt --strip-components=1

# 3. (Опционально) Установить JS Interposer
sudo dpkg -i dist/selkies-js-interposer_*.deb

# 4. (Опционально) Установить GStreamer bundle
sudo tar -xzf dist/gstreamer-selkies_*.tar.gz -C /opt
. /opt/gstreamer/gst-env
```

## Проблемы и решения

### Docker недоступен
```
✗ Docker не доступен или не запущен
```

**Решение:**
```bash
# Запустить Docker
sudo systemctl start docker

# Добавить пользователя в группу docker
sudo usermod -aG docker $USER
newgrp docker
```

### Недостаточно места
```
ERROR: No space left on device
```

**Решение:**
```bash
# Очистить неиспользуемые Docker образы
docker system prune -a

# Пропустить GStreamer
BUILD_GSTREAMER=false ./build.sh
```

## Лицензия

Mozilla Public License 2.0 (MPL-2.0)

