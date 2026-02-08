# TDD — amnezia-client-image

Technical Design Document для Docker-образа клиента AmneziaWG VPN.

---

## 1. Цели проекта

Создать минимальный Docker-образ с userspace-клиентом AmneziaWG, пригодный для запуска в:

- Docker (standalone)
- Docker Compose
- Kubernetes
- Home Assistant (Add-on)

Образ работает как VPN-шлюз: маршрутизирует трафик других контейнеров/устройств через AmneziaWG-туннель.

---

## 2. Архитектура

### 2.1 Upstream-зависимости

| Компонент       | Репозиторий                              | Что даёт                                            |
| --------------- | ---------------------------------------- | --------------------------------------------------- |
| amneziawg-go    | `github.com/amnezia-vpn/amneziawg-go`    | Userspace VPN-демон на Go (бинарник `amneziawg-go`) |
| amneziawg-tools | `github.com/amnezia-vpn/amneziawg-tools` | CLI: `awg` (C-бинарник) + `awg-quick` (bash-скрипт) |

Собственный VPN-код не пишется. Всё берётся из upstream.

### 2.2 Базовый образ

**Alpine Linux** — минимальный размер (~5 MB base), есть shell, `ip`, `iptables` — всё, что нужно для `awg-quick`.

Причина отказа от scratch/distroless: `awg-quick` — bash-скрипт, зависящий от `ip`, `iptables`, `sysctl`, `resolvconf`.

### 2.3 Целевые архитектуры

| Платформа      | Устройства                             |
| -------------- | -------------------------------------- |
| `linux/amd64`  | x86_64 серверы, десктопы               |
| `linux/arm64`  | Raspberry Pi 4/5, Apple Silicon (в VM) |
| `linux/arm/v7` | Raspberry Pi 3, старые ARM SBC         |
| `linux/arm/v6` | Raspberry Pi Zero/1                    |

### 2.4 Структура репозитория

```
amnezia-client-image/
├── AGENTS.md                    # Инструкции для AI-агентов
├── CLAUDE.md                    # Ссылка на AGENTS.md
├── TDD.md                       # Этот документ
├── Makefile                     # Единая точка входа (build, test, clean, push)
├── .env.example                 # Пример переменных окружения
├── .gitignore
├── .goreleaser.yml              # Конфигурация goreleaser (changelog, release)
├── Dockerfile                   # Multi-stage сборка образа
├── rootfs/
│   └── etc/
│       ├── s6-overlay/          # (опционально, если потребуется init)
│       └── cont-init.d/        # (опционально)
├── scripts/
│   ├── entrypoint.sh            # Основной entrypoint контейнера
│   └── healthcheck.sh           # Скрипт health check
├── examples/
│   ├── docker-compose.yml       # Пример для Docker Compose
│   └── kubernetes/
│       ├── deployment.yaml      # K8s Deployment
│       └── configmap.yaml       # K8s ConfigMap (без секретов)
├── homeassistant/
│   ├── config.yaml              # HA Add-on конфигурация
│   ├── build.yaml               # HA Add-on build config
│   ├── DOCS.md                  # Документация add-on
│   ├── CHANGELOG.md             # Changelog add-on
│   ├── icon.png                 # Иконка add-on
│   ├── logo.png                 # Логотип add-on
│   └── translations/
│       ├── en.yaml              # Английская локализация
│       └── ru.yaml              # Русская локализация
├── .github/
│   ├── workflows/
│   │   ├── build.yml            # CI: build + smoke test на каждый push/PR
│   │   ├── release.yml          # CD: goreleaser + Docker push при tag
│   │   └── dependabot-auto.yml  # (опционально) auto-merge для Dependabot
│   └── dependabot.yml           # Автообновление upstream
├── README.md                    # Документация (английский)
└── README.ru.md                 # Документация (русский)
```

### 2.5 Multi-stage Dockerfile

```
┌──────────────────────────────────────┐
│  Stage 1: builder-go                 │
│  golang:1.24-alpine                  │
│  → Компиляция amneziawg-go           │
│  → Статический бинарник              │
│    CGO_ENABLED=0 GOOS=linux          │
└──────────────┬───────────────────────┘
               │
┌──────────────┴───────────────────────┐
│  Stage 2: builder-tools              │
│  alpine:3.21                         │
│  → Компиляция awg из C-исходников    │
│  → Копирование awg-quick (bash)      │
└──────────────┬───────────────────────┘
               │
┌──────────────┴───────────────────────┐
│  Stage 3: runtime                    │
│  alpine:3.21                         │
│  → apk: bash, iproute2, iptables,    │
│    ip6tables, openresolv             │
│  → COPY --from=builder-go            │
│  → COPY --from=builder-tools         │
│  → COPY scripts/entrypoint.sh        │
│  → COPY scripts/healthcheck.sh       │
│  → HEALTHCHECK                       │
│  → ENTRYPOINT ["/entrypoint.sh"]     │
└──────────────────────────────────────┘
```

**Ключевые решения по сборке:**

- `amneziawg-go`: компиляция с `CGO_ENABLED=0` для статического бинарника. `GOARCH` задаётся через Docker buildx `--platform`.
- `amneziawg-tools`: `awg` компилируется из C через `make` с musl-libc Alpine. `awg-quick` копируется как есть (bash-скрипт).
- Версии upstream фиксируются через `ARG` в Dockerfile (теги или коммиты).

---

## 3. Конфигурация контейнера

### 3.1 Переменные окружения

| Переменная          | Умолчание          | Описание                                              |
| ------------------- | ------------------ | ----------------------------------------------------- |
| `WG_CONFIG_FILE`    | `/config/wg0.conf` | Путь к конфигурационному файлу AmneziaWG              |
| `LOG_LEVEL`         | `info`             | Уровень логирования: `debug`, `info`, `warn`, `error` |
| `HEALTH_CHECK_HOST` | `1.1.1.1`          | IP-адрес для проверки доступности через VPN           |
| `KILL_SWITCH`       | `1`                | Блокировать трафик мимо VPN: `1` — вкл, `0` — выкл    |

### 3.2 Монтирование конфигурации

Пользователь монтирует том с одним `.conf`-файлом:

```
-v /path/to/configs:/config
```

Контейнер работает с **одним туннелем**. Имя файла определяет имя интерфейса: `wg0.conf` → интерфейс `wg0`.

Entrypoint копирует конфиг с правами `600` во временную директорию перед передачей в `awg-quick`.

### 3.3 Runtime-параметры (обязательные)

| Параметр    | Значение                             | Зачем                                       |
| ----------- | ------------------------------------ | ------------------------------------------- |
| `--device`  | `/dev/net/tun:/dev/net/tun`          | TUN-устройство для VPN                      |
| `--cap-add` | `NET_ADMIN`                          | Управление сетевыми интерфейсами и iptables |
| `--cap-add` | `SYS_MODULE`                         | Загрузка модулей ядра (опционально)         |
| `--sysctl`  | `net.ipv4.conf.all.src_valid_mark=1` | Корректная маршрутизация с fwmark           |
| `--sysctl`  | `net.ipv4.ip_forward=1`              | Форвардинг трафика (VPN-шлюз)               |

---

## 4. Сетевая модель

### 4.1 VPN-шлюз

Контейнер выступает как VPN-шлюз для других контейнеров. Схема:

```
┌───────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Container    │────▶│  amnezia-client  │────▶│  AmneziaWG   │
│  (app)        │     │  (VPN gateway)   │     │  Server      │
│  network:     │     │  iptables NAT    │     │  (remote)    │
│  service:vpn  │     │  MASQUERADE      │     │              │
└───────────────┘     └──────────────────┘     └──────────────┘
```

**Entrypoint** настраивает iptables MASQUERADE:

```bash
iptables -t nat -A POSTROUTING -o "$WG_INTERFACE" -j MASQUERADE
```

Другие контейнеры подключаются через `network_mode: service:vpn` (Compose) или sidecar (K8s).

### 4.2 Kill Switch

Когда `KILL_SWITCH=1` (по умолчанию), entrypoint добавляет iptables-правила:

1. Разрешить трафик на loopback.
2. Разрешить трафик к AmneziaWG endpoint (IP:port из `.conf`).
3. Разрешить трафик через VPN-интерфейс (`wg0`).
4. Разрешить DNS-трафик к серверам из `.conf` (если указан DNS).
5. Разрешить established/related соединения.
6. **DROP** всего остального.

Это предотвращает утечку трафика при падении VPN-туннеля.

### 4.3 DNS Leak Protection

Если в `.conf` указан `DNS`, entrypoint:

1. Записывает DNS-серверы в `/etc/resolv.conf` контейнера.
2. Добавляет iptables-правила, перенаправляющие все DNS-запросы (UDP/TCP 53) через VPN-интерфейс.
3. Блокирует DNS-запросы мимо VPN (при включённом kill switch).

`awg-quick` обрабатывает DNS через `resolvconf`, если доступен. Entrypoint дополнительно обеспечивает защиту.

---

## 5. Health Check

### 5.1 Механизм

```dockerfile
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD /healthcheck.sh
```

**healthcheck.sh** выполняет:

1. Проверяет существование VPN-интерфейса (`ip link show "$WG_INTERFACE"`).
2. Проверяет наличие latest handshake через `awg show "$WG_INTERFACE" latest-handshakes`.
3. Пингует `HEALTH_CHECK_HOST` через VPN-интерфейс (`ping -c 1 -W 5 -I "$WG_INTERFACE" "$HEALTH_CHECK_HOST"`).

Если любой шаг неуспешен — контейнер помечается как `unhealthy`.

---

## 6. Graceful Shutdown

Entrypoint перехватывает `SIGTERM`:

```bash
trap 'awg-quick down "$WG_INTERFACE"; exit 0' SIGTERM SIGINT
```

Последовательность остановки:

1. Перехват `SIGTERM` от Docker.
2. Вызов `awg-quick down` — удаление интерфейса, маршрутов, iptables-правил.
3. Выход с кодом 0.

Docker ожидает graceful shutdown 10 секунд (по умолчанию), затем `SIGKILL`.

---

## 7. Home Assistant Add-on

### 7.1 config.yaml

```yaml
name: "AmneziaWG Client"
version: "1.0.0"
slug: amneziawg-client
description: "AmneziaWG VPN client as a Home Assistant Add-on"
url: "https://github.com/<owner>/amnezia-client-image"
arch:
  - amd64
  - aarch64
  - armv7
  - armhf
init: false
startup: services
image: "ghcr.io/<owner>/amnezia-client-image/{arch}"
privileged:
  - NET_ADMIN
  - SYS_MODULE
map:
  - config:rw
options:
  config_file: "wg0.conf"
  log_level: "info"
  health_check_host: "1.1.1.1"
  kill_switch: true
schema:
  config_file: str
  log_level: "list(debug|info|warn|error)"
  health_check_host: str
  kill_switch: bool
```

### 7.2 Translations

**translations/en.yaml:**

```yaml
configuration:
  config_file:
    name: Config File
    description: Name of the AmneziaWG config file in /config
  log_level:
    name: Log Level
    description: Logging verbosity (debug, info, warn, error)
  health_check_host:
    name: Health Check Host
    description: IP address to ping through VPN tunnel for health checks
  kill_switch:
    name: Kill Switch
    description: Block all traffic if VPN tunnel is down
```

**translations/ru.yaml:**

```yaml
configuration:
  config_file:
    name: Файл конфигурации
    description: Имя файла конфигурации AmneziaWG в /config
  log_level:
    name: Уровень логирования
    description: Детализация логов (debug, info, warn, error)
  health_check_host:
    name: Хост проверки
    description: IP-адрес для пинга через VPN-туннель
  kill_switch:
    name: Аварийный выключатель
    description: Блокировать весь трафик при падении VPN-туннеля
```

---

## 8. CI/CD

### 8.1 GitHub Actions Workflows

#### build.yml — CI (каждый push и PR)

Триггер: `push` на все ветки, `pull_request`.

Шаги:

1. Checkout.
2. Setup Docker Buildx + QEMU.
3. `docker buildx build --platform linux/amd64` (только одна платформа для скорости).
4. Smoke test: запуск контейнера, проверка наличия бинарников (`amneziawg-go`, `awg`, `awg-quick`), проверка entrypoint (без реального VPN).
5. Hadolint (линтинг Dockerfile).
6. ShellCheck (линтинг bash-скриптов).

#### release.yml — CD (при push tag `v*`)

Триггер: `push` tag `v*.*.*`.

Шаги:

1. Checkout с `fetch-depth: 0` (для goreleaser changelog).
2. Setup Docker Buildx + QEMU.
3. Login в GHCR (`ghcr.io`).
4. `docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6 --push` — сборка и публикация multi-arch образа.
5. Goreleaser: создание GitHub Release с changelog из conventional commits.

Теги образа при релизе `v1.2.3`:

- `ghcr.io/<owner>/amnezia-client-image:1.2.3`
- `ghcr.io/<owner>/amnezia-client-image:1.2`
- `ghcr.io/<owner>/amnezia-client-image:1`
- `ghcr.io/<owner>/amnezia-client-image:latest`

### 8.2 goreleaser

Goreleaser используется **только для управления релизами**, не для сборки Docker-образов (сборка через `docker buildx`):

- Генерация changelog из conventional commits (`feat:`, `fix:`, `docs:`, `chore:`).
- Создание GitHub Release с changelog.
- Шаблон `.goreleaser.yml` без секции `builds` и `dockers`.

```yaml
version: 2

project_name: amnezia-client-image

# Нет Go-сборки — только release management
builds: []

changelog:
  use: github
  groups:
    - title: "Features"
      regexp: '^.*?feat(\([[:word:]]+\))??!?:.+$'
      order: 0
    - title: "Bug Fixes"
      regexp: '^.*?fix(\([[:word:]]+\))??!?:.+$'
      order: 1
    - title: "Documentation"
      regexp: '^.*?docs(\([[:word:]]+\))??!?:.+$'
      order: 2
    - title: "Other"
      order: 999
  filters:
    exclude:
      - "^chore:"
      - "^ci:"
      - "^test:"

release:
  github:
    owner: "<owner>"
    name: "amnezia-client-image"
  prerelease: auto
  name_template: "{{ .Tag }}"
```

### 8.3 Версионирование

- **SemVer**: `MAJOR.MINOR.PATCH` (например, `v1.0.0`).
- Релиз создаётся при push git tag `v*.*.*`.
- Changelog генерируется goreleaser из conventional commits.
- Формат коммитов: `<тип>: <описание>` (`feat:`, `fix:`, `docs:`, `chore:`).

---

## 9. Тестирование

### 9.1 Build Test (CI)

- `docker buildx build` проходит без ошибок для `linux/amd64`.

### 9.2 Smoke Test (CI)

Запуск контейнера в CI без реального VPN-сервера. Проверки:

1. Бинарники на месте:
   - `docker run --rm <image> which amneziawg-go` → `/usr/bin/amneziawg-go`
   - `docker run --rm <image> which awg` → `/usr/bin/awg`
   - `docker run --rm <image> which awg-quick` → `/usr/bin/awg-quick`
2. Версии:
   - `docker run --rm <image> amneziawg-go --version`
   - `docker run --rm <image> awg --version`
3. Entrypoint стартует и корректно завершается при отсутствии конфигурации (с понятным сообщением об ошибке).
4. Health check скрипт существует и исполняем.

### 9.3 Локальное тестирование

```bash
make build          # Сборка образа
make test           # Build + smoke test
make run            # Запуск с тестовым конфигом (требует .conf)
```

---

## 10. Примеры деплоя

### 10.1 Docker Run

```bash
docker run -d \
  --name=amneziawg \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --device=/dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv4.ip_forward=1 \
  -v /path/to/config:/config \
  -e KILL_SWITCH=1 \
  --restart=unless-stopped \
  ghcr.io/<owner>/amnezia-client-image:latest
```

### 10.2 Docker Compose (examples/docker-compose.yml)

```yaml
services:
  vpn:
    image: ghcr.io/<owner>/amnezia-client-image:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    volumes:
      - ./config:/config
    environment:
      - KILL_SWITCH=1
      - LOG_LEVEL=info
      - HEALTH_CHECK_HOST=1.1.1.1
    restart: unless-stopped

  # Пример: контейнер, использующий VPN как шлюз
  app:
    image: curlimages/curl:latest
    network_mode: service:vpn
    depends_on:
      vpn:
        condition: service_healthy
    command: ["curl", "-s", "https://ifconfig.me"]
```

### 10.3 Kubernetes (examples/kubernetes/)

**deployment.yaml** — Deployment с sidecar-паттерном или отдельный Pod с VPN.

**configmap.yaml** — пример (без секретов; приватные ключи — через Secret).

---

## 11. Документация

### 11.1 Файлы

| Файл           | Язык    | Содержание                                                    |
| -------------- | ------- | ------------------------------------------------------------- |
| `README.md`    | English | Основной README: описание, quick start, конфигурация, примеры |
| `README.ru.md` | Русский | Полный перевод README.md                                      |

### 11.2 Структура README

1. Описание проекта и бейджи (build status, version, license).
2. Quick Start (docker run одной командой).
3. Конфигурация (таблица env vars, формат .conf).
4. Режим VPN-шлюза (Docker Compose пример).
5. Kubernetes (ссылка на examples/).
6. Home Assistant Add-on (инструкция установки).
7. Health Check.
8. Kill Switch.
9. Сборка из исходников (`make build`).
10. Troubleshooting.
11. Лицензия.

---

## 12. Безопасность

- `.conf`-файлы содержат приватные ключи — **никогда не коммитить**. `*.conf` в `.gitignore`.
- Конфиги внутри контейнера копируются с правами `600`.
- Контейнер работает от **root** — необходимо для `NET_ADMIN`.
- Kill switch по умолчанию включён — предотвращает утечку при падении VPN.
- DNS leak protection — DNS-запросы принудительно направляются через VPN.
- Образ использует минимальный набор пакетов Alpine.
- `HEALTHCHECK` позволяет оркестраторам обнаруживать сбой туннеля.

---

## 13. Автообновление зависимостей

### Dependabot (.github/dependabot.yml)

```yaml
version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

Для upstream-зависимостей (`amneziawg-go`, `amneziawg-tools`) — версии зафиксированы как `ARG` в Dockerfile. Dependabot не отслеживает произвольные git-репозитории, поэтому обновление upstream выполняется:

- Вручную (изменение `ARG` в Dockerfile).
- Через Renovate (если настроен, умеет отслеживать git tags в Dockerfile ARG).

Рекомендация: настроить **Renovate** для автоматических PR при обновлении upstream тегов.

---

## 14. Makefile

Единая точка входа. Основные targets:

```
##@ Build
build          ## Build Docker image for current platform
build-all      ## Build Docker image for all platforms (no push)

##@ Test
test           ## Build and run smoke tests
lint           ## Run Hadolint + ShellCheck

##@ Release
push           ## Build and push multi-arch image to GHCR
release        ## Run goreleaser (changelog + GitHub Release)

##@ Development
run            ## Run container locally with test config
stop           ## Stop running container
logs           ## Show container logs
shell          ## Open shell in running container

##@ Clean
clean          ## Remove built images and stopped containers
```

Переменные через `?=` (переопределяемые из `.env`):

```makefile
IMAGE_NAME  ?= ghcr.io/<owner>/amnezia-client-image
IMAGE_TAG   ?= dev
PLATFORMS   ?= linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6
CONFIG_DIR  ?= ./config
```

---

## 15. Entrypoint — логика работы

```
entrypoint.sh
│
├── Валидация: проверить наличие $WG_CONFIG_FILE
│   └── Нет файла → вывести ошибку, выход 1
│
├── Копировать конфиг в /tmp с правами 600
│
├── Определить имя интерфейса из имени файла (wg0.conf → wg0)
│
├── Если KILL_SWITCH=1:
│   ├── Извлечь Endpoint IP из .conf
│   ├── Извлечь DNS серверы из .conf (если есть)
│   └── Настроить iptables правила (kill switch + DNS protection)
│
├── Запустить awg-quick up $INTERFACE
│
├── Если KILL_SWITCH=1:
│   └── Настроить NAT (MASQUERADE) для VPN-шлюза
│
├── Установить trap для SIGTERM/SIGINT → awg-quick down
│
└── Ожидание (wait) — контейнер работает до SIGTERM
```

---

## 16. Диаграмма потоков данных

```
Пользователь
    │
    │ Монтирует .conf
    ▼
┌──────────────────────────────────────────────────┐
│  Docker Container (amnezia-client-image)         │
│                                                  │
│  entrypoint.sh                                   │
│    │                                             │
│    ├─▶ iptables (kill switch, NAT, DNS)          │
│    │                                             │
│    ├─▶ awg-quick up wg0                          │
│    │     │                                       │
│    │     ├─▶ amneziawg-go -f wg0 (userspace)     │
│    │     ├─▶ ip link / ip addr / ip route        │
│    │     └─▶ resolvconf (DNS)                    │
│    │                                             │
│    └─▶ wait (sleep / trap SIGTERM)               │
│                                                  │
│  healthcheck.sh (periodic)                       │
│    └─▶ ping $HEALTH_CHECK_HOST via wg0           │
└──────────────────────┬───────────────────────────┘
                       │ wg0 (TUN interface)
                       ▼
               AmneziaWG Server (remote)
```
