# Руководство по разработке

Документ описывает процесс работы с репозиторием: от локальной разработки до выпуска релиза.

## Структура репозитория

```
.
├── Dockerfile                  # Многоступенчатая сборка образа
├── Makefile                    # Единая точка входа для всех операций
├── scripts/
│   ├── entrypoint.sh           # Скрипт запуска контейнера
│   └── healthcheck.sh          # Проверка здоровья VPN
├── examples/
│   ├── docker-compose.yml      # Пример для Docker Compose
│   └── kubernetes/             # Примеры манифестов K8s
├── amneziawg-client/           # Конфигурация Home Assistant add-on
├── .github/
│   ├── workflows/
│   │   ├── build.yml           # CI: линтинг, сборка, smoke-тесты
│   │   └── release.yml         # CD: сборка и публикация при создании тега
│   └── dependabot.yml          # Автообновление зависимостей
├── AGENTS.md                   # Инструкции для AI-агентов
├── TDD.md                      # Technical Design Document
├── README.md / README.ru.md    # Документация пользователя
├── .goreleaser.yml             # Конфигурация goreleaser
├── .hadolint.yaml              # Настройки линтера Dockerfile
├── .env.example                # Шаблон переменных окружения
└── config/                     # Директория для .conf-файлов (gitignored)
```

## Быстрый старт

### Предварительные требования

- Docker с поддержкой Buildx
- GNU Make
- ShellCheck (для `make lint`)
- Файл конфигурации AmneziaWG (`.conf`)

### Первый запуск

```bash
# 1. Клонировать репозиторий
git clone https://github.com/windemiatrix/amnezia-client-image.git
cd amnezia-client-image

# 2. Скопировать шаблон переменных окружения
cp .env.example .env

# 3. Положить конфиг VPN
cp /path/to/your/wg0.conf config/

# 4. Собрать образ
make build

# 5. Запустить контейнер
make run

# 6. Проверить логи
make logs
```

## Команды Makefile

`make` (или `make help`) — выводит список всех доступных целей:

### Build

| Команда            | Описание                                          |
| ------------------ | ------------------------------------------------- |
| `make build`       | Сборка образа для текущей платформы               |
| `make build-multi` | Сборка мультиплатформенного образа (без загрузки) |

### Test

| Команда     | Описание                                                    |
| ----------- | ----------------------------------------------------------- |
| `make test` | Сборка + smoke-тесты (наличие бинарников, обработка ошибок) |
| `make lint` | Hadolint (Dockerfile) + ShellCheck (bash-скрипты)           |

### Release

| Команда        | Описание                                               |
| -------------- | ------------------------------------------------------ |
| `make push`    | Сборка и публикация мультиплатформенного образа в GHCR |
| `make release` | Запуск goreleaser (требуется `GITHUB_TOKEN`)           |

### Development

| Команда      | Описание                                |
| ------------ | --------------------------------------- |
| `make run`   | Сборка + запуск контейнера в фоне       |
| `make stop`  | Остановка и удаление контейнера         |
| `make logs`  | Просмотр логов контейнера (follow)      |
| `make shell` | Открыть bash-оболочку внутри контейнера |

### Clean

| Команда      | Описание                               |
| ------------ | -------------------------------------- |
| `make clean` | Остановка контейнера + удаление образа |

### Переменные окружения

Все переменные задаются через `.env` или передаются при вызове `make`:

```bash
# Через .env
IMAGE_TAG=dev

# Или через командную строку
make build IMAGE_TAG=dev
```

Доступные переменные (см. `.env.example`):

| Переменная                | По умолчанию                                        |
| ------------------------- | --------------------------------------------------- |
| `IMAGE_NAME`              | `ghcr.io/windemiatrix/amnezia-client-image`         |
| `IMAGE_TAG`               | `latest`                                            |
| `PLATFORMS`               | `linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6` |
| `CONFIG_DIR`              | `./config`                                          |
| `AMNEZIAWG_GO_VERSION`    | `v0.2.16`                                           |
| `AMNEZIAWG_TOOLS_VERSION` | `v1.0.20250903`                                     |

## Процесс разработки

### Ветвление

Проект использует feature-branch workflow:

1. Создать ветку от `main`:
   ```bash
   git checkout main
   git pull
   git checkout -b feat/my-feature
   ```
2. Внести изменения, убедиться что образ собирается:
   ```bash
   make lint
   make test
   ```
3. Закоммитить изменения (формат коммитов ниже).
4. Открыть Pull Request в `main`.
5. После прохождения CI — merge.

### Формат коммитов

```
<тип>: <описание>
```

Типы:

| Тип     | Когда использовать                    |
| ------- | ------------------------------------- |
| `feat`  | Новая функциональность                |
| `fix`   | Исправление бага                      |
| `docs`  | Изменения в документации              |
| `chore` | Служебные изменения (CI, зависимости) |

Примеры:
```
feat: add IPv6 support for kill switch
fix: handle missing DNS in config
docs: add Kubernetes deployment example
chore: update Alpine base image to 3.21
```

Goreleaser использует эти префиксы для группировки changelog: `feat:` → Features, `fix:` → Bug Fixes, `docs:` → Documentation. Коммиты с `chore:`, `ci:`, `test:` исключаются из changelog.

## CI/CD

### CI — `build.yml`

Запускается на каждый push и Pull Request:

```
Push / PR → Lint (Hadolint + ShellCheck) → Build (linux/amd64) → Smoke tests
```

Smoke-тесты проверяют:
- наличие бинарников `amneziawg-go`, `awg`, `awg-quick`
- корректную версию бинарников
- что entrypoint завершается с ошибкой при отсутствии конфига
- наличие healthcheck-скрипта

### CD — `release.yml`

Запускается при создании тега формата `v*.*.*`:

```
Tag push → Build multi-arch → Push to GHCR → GitHub Release (goreleaser)
```

Образ публикуется с тегами semver:
- `1.0.0` (точная версия)
- `1.0` (minor)
- `1` (major)
- `latest`

### Dependabot

Еженедельно проверяет обновления:
- Базовых Docker-образов в `Dockerfile`
- GitHub Actions в `.github/workflows/`

## Процесс релиза

### Шаги

1. Убедиться, что все изменения в `main`, CI зелёный.
2. Создать и отправить тег:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. GitHub Actions автоматически:
   - соберёт мультиплатформенный образ (amd64, arm64, armv7, armv6),
   - опубликует его в GHCR (`ghcr.io/windemiatrix/amnezia-client-image`),
   - создаст GitHub Release с changelog.
4. Обновить версию в `amneziawg-client/config.yaml` при необходимости.

### Semver

Следуйте [Semantic Versioning](https://semver.org/):

- **MAJOR** (`v2.0.0`) — несовместимые изменения API/конфигурации
- **MINOR** (`v1.1.0`) — новая функциональность с обратной совместимостью
- **PATCH** (`v1.0.1`) — исправления багов

## Ключевые файлы проекта

### AGENTS.md

Файл с инструкциями для AI-агентов (Claude, Copilot и т.д.). Содержит:

- **Цель проекта** — что делает образ и зачем.
- **Upstream-зависимости** — откуда берётся VPN-код (amneziawg-go, amneziawg-tools).
- **Runtime-требования** — какие capabilities и параметры нужны контейнеру.
- **Соглашения Makefile** — как оформлять targets, чтобы `make help` работал.
- **Стиль коммитов** — формат `<тип>: <описание>`.
- **Безопасность** — запрет на коммит `.conf`-файлов с приватными ключами.

Файл `CLAUDE.md` ссылается на `AGENTS.md` через директиву `@AGENTS.md` — это подключает его как системный промпт для Claude Code.

**Зачем нужен**: AI-агент, работающий с кодом, получает полный контекст проекта и следует его соглашениям. Без этого файла агент может предложить неподходящую структуру, нарушить формат коммитов или пропустить требования безопасности.

### TDD.md

Technical Design Document — полная спецификация проекта: архитектура, сетевая модель, kill switch, health check, CI/CD, тестирование, развёртывание. Является источником истины для всех архитектурных решений.

### .goreleaser.yml

Конфигурация goreleaser. Не собирает бинарники (это делает Docker) — только генерирует GitHub Release с changelog из conventional commits.

## Отладка

### Логи контейнера

```bash
make logs
# или
docker logs -f amneziawg
```

Для подробных логов установите `LOG_LEVEL=debug` в конфиге или переменной окружения.

### Shell внутри контейнера

```bash
make shell
```

### Проверка VPN вручную

```bash
# Внутри контейнера
awg show
ping -I wg0 1.1.1.1
```
