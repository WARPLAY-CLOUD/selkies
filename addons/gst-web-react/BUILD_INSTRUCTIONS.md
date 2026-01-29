# 🔨 Инструкция по сборке с build.sh

## 📋 Обзор

Скрипт `build.sh` в корне проекта теперь поддерживает выбор между двумя вариантами web интерфейса:

- **gst-web-react** (React + TypeScript) - **по умолчанию** ✨
- **gst-web** (Vue.js) - оригинальная версия

## 🚀 Быстрый старт

### По умолчанию (gst-web-react)

```bash
./build.sh
```

Соберет проект с **gst-web-react** (React + TypeScript) по умолчанию.

### Оригинальная версия (gst-web)

```bash
WEB_VARIANT=gst-web ./build.sh
```

Соберет проект с оригинальным **gst-web** (Vue.js).

### Явно указать React версию

```bash
WEB_VARIANT=gst-web-react ./build.sh
```

## 📦 Что собирается

По умолчанию скрипт собирает:

1. ✅ **Python wheel** - обязательный компонент
2. ✅ **Web интерфейс** - gst-web-react или gst-web (на выбор)
3. 🎬 **GStreamer bundle** - опционально (~45 мин, можно пропустить)

## 🎯 Примеры использования

### 1. Собрать всё с gst-web-react (по умолчанию)

```bash
./build.sh
```

**Результат:**
- `dist/selkies_gstreamer-1.6.2+w-py3-none-any.whl`
- `dist/selkies-gstreamer-web_v1.6.2+w.tar.gz` (содержит gst-web-react)

### 2. Собрать с оригинальным gst-web

```bash
WEB_VARIANT=gst-web ./build.sh
```

**Результат:**
- `dist/selkies_gstreamer-1.6.2+w-py3-none-any.whl`
- `dist/selkies-gstreamer-web_v1.6.2+w.tar.gz` (содержит gst-web)

### 3. Собрать только web интерфейс (gst-web-react)

```bash
BUILD_PYTHON=false BUILD_GSTREAMER=false ./build.sh
```

### 4. Собрать только web интерфейс (gst-web)

```bash
WEB_VARIANT=gst-web BUILD_PYTHON=false BUILD_GSTREAMER=false ./build.sh
```

### 5. Пропустить GStreamer (долгая сборка)

```bash
BUILD_GSTREAMER=false ./build.sh
```

### 6. Кастомная версия с gst-web-react

```bash
SELKIES_VERSION=1.7.0 WEB_VARIANT=gst-web-react ./build.sh
```

## 🔧 Переменные окружения

| Переменная | Значения | По умолчанию | Описание |
|------------|----------|--------------|----------|
| `WEB_VARIANT` | `gst-web-react`, `gst-web` | `gst-web-react` | Вариант web интерфейса |
| `BUILD_PYTHON` | `true`, `false` | `true` | Собрать Python wheel |
| `BUILD_WEB` | `true`, `false` | `true` | Собрать web интерфейс |
| `BUILD_GSTREAMER` | `true`, `false` | `true` | Собрать GStreamer bundle |
| `SELKIES_VERSION` | любая строка | `1.6.2+w` | Версия пакета |
| `DISTRIB_RELEASE` | `22.04`, `24.04` и др. | `24.04` | Ubuntu версия |

## 📂 Структура результата

После успешной сборки в папке `dist/` будет:

```
dist/
├── selkies_gstreamer-1.6.2+w-py3-none-any.whl
├── selkies-gstreamer-web_v1.6.2+w.tar.gz
│   └── gst-web-react/          # или gst-web/
│       ├── index.html
│       └── assets/
│           ├── index-*.js
│           └── index-*.css
└── gstreamer-selkies_gpl_v1.6.2+w_ubuntu24.04_amd64.tar.gz (если собран)
```

## 🔍 Проверка варианта web интерфейса

### Проверить что в архиве

```bash
tar -tzf dist/selkies-gstreamer-web_v*.tar.gz | head -20
```

**Для gst-web-react:**
```
gst-web-react/
gst-web-react/index.html
gst-web-react/assets/
gst-web-react/assets/index-*.js
gst-web-react/assets/index-*.css
```

**Для gst-web:**
```
gst-web/
gst-web/index.html
gst-web/js/
gst-web/css/
...
```

## 📊 Сравнение вариантов

| Параметр | gst-web-react | gst-web |
|----------|---------------|---------|
| Фреймворк | React 18 | Vue.js 2 |
| Язык | TypeScript | JavaScript |
| Размер bundle | ~190 KB | ~150 KB |
| Время сборки | ~30 сек | ~20 сек |
| Типизация | ✅ Полная | ❌ Нет |
| Режим отладки | ✅ Встроен | ⚠️ Ограничен |
| Конфигурация | URL + Props | Hostname |

## 💡 Рекомендации

### Когда использовать gst-web-react:

✅ Новые проекты  
✅ Нужна полная типизация  
✅ Планируется кастомизация  
✅ Нужен режим отладки  
✅ Разработка на TypeScript  

### Когда использовать gst-web:

✅ Существующие проекты на Vue.js  
✅ Минимальный размер bundle  
✅ Быстрая сборка  
✅ Обратная совместимость  

## 🐛 Отладка

### Проблема: "Dockerfile не найден"

**Решение:** Скрипт автоматически создаст Dockerfile для gst-web-react если его нет.

### Проблема: "Не удалось извлечь web архив"

**Решение:**
1. Проверьте Docker логи
2. Убедитесь что `npm run build` работает локально
3. Проверьте наличие файлов в `dist/` после сборки

```bash
# Проверить локально
cd addons/gst-web-react
npm install
npm run build
ls -la dist/
```

### Проблема: Сборка Docker образа не запускается

**Решение:**
```bash
# Проверить Docker
docker ps

# Проверить права
sudo usermod -aG docker $USER
newgrp docker

# Попробовать снова
./build.sh
```

## 📝 Логи

Логи сборки сохраняются в:
- `/tmp/gstreamer-build.log` - для GStreamer (если собирается)
- stdout - для остальных компонентов

## 🔄 Переключение между вариантами

Вы можете переключаться между вариантами при каждой сборке:

```bash
# День 1: собираем React версию
./build.sh

# День 2: собираем Vue версию для сравнения
WEB_VARIANT=gst-web ./build.sh

# День 3: возвращаемся к React
./build.sh
```

Оба варианта создают одинаковое имя архива, так что используйте версию для различия:

```bash
# Разные версии для разных вариантов
SELKIES_VERSION=1.7.0-react WEB_VARIANT=gst-web-react ./build.sh
SELKIES_VERSION=1.7.0-vue WEB_VARIANT=gst-web ./build.sh
```

## 🚀 Развертывание

После сборки разверните web интерфейс:

```bash
# Распаковать
sudo tar -xzf dist/selkies-gstreamer-web_v*.tar.gz -C /opt

# Проверить
ls -la /opt/gst-web-react/  # или /opt/gst-web/
```

Затем настройте веб-сервер (Nginx, Apache) для обслуживания статических файлов.

См. также:
- [DEPLOY.md](./DEPLOY.md) - развертывание на сервере
- [README.md](./README.md) - основная документация
- [QUICK_START_RU.md](./QUICK_START_RU.md) - быстрый старт на русском

## ✅ Проверочный чеклист

После сборки проверьте:

- [ ] Файл `dist/selkies-gstreamer-web_v*.tar.gz` создан
- [ ] Архив содержит `gst-web-react/` или `gst-web/` директорию
- [ ] В директории есть `index.html`
- [ ] Есть директория `assets/` с JS и CSS файлами
- [ ] Размер архива адекватный (несколько сотен KB)

```bash
# Быстрая проверка
tar -tzf dist/selkies-gstreamer-web_v*.tar.gz | grep -E "(index.html|.js|.css)" | head -5
```

## 📞 Поддержка

Если возникли проблемы:

1. Проверьте что Docker запущен: `docker ps`
2. Проверьте локальную сборку: `cd addons/gst-web-react && npm run build`
3. Проверьте логи: `/tmp/gstreamer-build.log`
4. Создайте issue с описанием проблемы и логами

---

**Готово!** Теперь вы можете выбирать вариант web интерфейса при каждой сборке. 🎉
