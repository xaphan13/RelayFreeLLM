# 05 — Предложения по развитию (Optimization Roadmap)

Приоритеты: **P0** — корректность/надёжность, **P1** — производительность и масштабирование, **P2** — качество кода и DX.

## Архитектурные улучшения

### A1. Внешнее хранилище состояния (P1)
Состояние лимитов (`ApiLimitsTracker`), cooldown, session affinity и usage-статистика живут в памяти одного процесса → горизонтальное масштабирование невозможно, рестарт обнуляет rate-limit-окна (roadmap-пункт «Persistent rate limit state»).
- Минимальный шаг: SQLite/Redis-бэкенд за интерфейсом `LimitsStore` (абстрагировать `src/api_limits_tracker.py`): скользящие окна через атомарные операции (`ZADD`/`ZREMRANGEBYBYSCORE` в Redis или `UPDATE ... WHERE ts > ?` в SQLite).
- Session affinity (`ModelDispatcher.session_affinity_map`) — туда же; это разблокирует запуск N реплик за балансировщиком.
- Промежуточная альтернатива без внешних зависимостей: периодический дамп/восстановление окон в JSON при старте/остановке.

### A2. Разделение ответственности `ModelDispatcher` (P1)
`src/model_dispatcher.py` (~660 строк) совмещает маршрутизацию, retry, сборку messages, мультимодальную деградацию и учёт. Целевая декомпозиция:
- `MessageAssembler` (verbatim/legacy-пути, инъекция промптов, деградация мультимодальности) — выносится из `call_provider_api()`;
- `RetryPolicy`/`FailoverController` (цикл попыток, `exclude_providers`, circuit breaker) — сейчас логика размазана между dispatcher и selector;
- `ModelDispatcher` остаётся тонким оркестратором.
Это устранит хрупкие проверки `"provider_name" in locals()` и упростит тестирование retry-сценариев.

### A3. Очередь задач для фоновой персистентности (P1)
`UsageTracker` и `ConversationStore` пишут JSON синхронно на каждую операцию. Схема: события складываются в `asyncio.Queue`, единственный фоновый воркер (запускается в `lifespan`) батчами пишет на диск (или в БД из A1). Заодно решается атомарность (tmp-файл + `os.replace`).

### A4. Подключение мёртвой подсистемы автообнаружения моделей (P2)
`ModelDispatcher.list_all_provider_models()` и `ModelSelector.refresh_registry()` реализованы, но не вызываются. Варианты: периодическая задача в `lifespan` (например, раз в час) или админ-эндпоинт `POST /admin/api/refresh`. Без этого реестр `src/provider_model_limits.json` устаревает при смене модельного ряда провайдеров.

### A5. Единый контракт стриминга (P0)
`DeepSeekClient.call_model_api` и `CloudflareClient.call_model_api` не принимают `stream` (нарушение LSP, потенциальный `TypeError`). Либо реализовать SSE-парсинг по образцу `nvidia_client.py::_stream_response`, либо явно поднять `NotImplementedError`/вернуть ошибку до вызова. При активации этих провайдеров через админку текущий код упадёт на первом же стрим-запросе.

## Оптимизация производительности

### B1. Разблокировать event loop (P0)
Синхронные SDK внутри async-обработчиков блокируют весь воркер:
- `src/api_clients/groq_client.py`, `cerebras_client.py` — перевести на async-варианты (`groq.AsyncGroq`, `cerebras.cloud.sdk.AsyncCerebras`) либо обернуть в `asyncio.to_thread()`;
- `mistral_client.py::chat.complete` → `chat.complete_async`; `gemini_client.py::list_models` → `client.aio.models.list`.

### B2. Переиспользуемые HTTP-клиенты (P1)
Во всех httpx-клиентах (`nvidia_client.py`, `deepseek_client.py`, `cloudflare_client.py`, `ollama_client.py`) `httpx.AsyncClient` создаётся на каждый запрос → лишний TCP/TLS-handshake. Создать один клиент на время жизни приложения (в конструкторе клиента провайдера, закрывать в shutdown `lifespan`), с `httpx.Timeout(connect=..., read=...)` вместо единого скаляра.

### B3. Асинхронная/батчевая запись статистики (P0)
`src/usage_tracker.py::record_usage` делает `json.dump` всего файла под `Lock` на каждый запрос. См. A3; как быстрый фикс — дебаунс записи (не чаще раза в N секунд) + атомарный `os.replace`.

### B4. Кэширование суммаризации (P1)
`src/context_manager.py::_extractive_summarize` пересчитывает суммаризацию всей «старой» истории на каждом запросе (режим `reservoir`). Кэшировать результат по ключу `(session_id, hash(older_messages))`: хвост истории неизменен между запросами, инкрементально суммаризировать только новые сообщения.

### B5. Пересмотр `GLOBAL_PROVIDER_LOCK` (P1)
В штатном `settings.json` включена полная сериализация запросов на провайдера — потолок 1 RPS/провайдер. Скользящие окна `ApiLimitsTracker` уже предотвращают превышение лимитов; рекомендация — выключить по умолчанию (`false`), оставить как аварийный режим, либо заменить на семафор с лимитом > 1 (например, `requests_per_second` провайдера).

### B6. Точечные мелочи (P2)
- `src/api_provider.py::_select_from_list_roundrobin`: `self.models.index(m)` (O(n)) внутри цикла → хранить индекс явно.
- `src/context_manager.py::_select_dynamic`: заменить эвристику «токены / 50» на реальный подсчёт по сообщениям.
- `src/api_clients/gemini_client.py`: убрать безусловный `tools=[GoogleSearch()]` и `seed=42` (или сделать конфигурируемыми) — снижает латентность и расход квоты.
- Убрать `await asyncio.sleep(0.5)` в `deepseek_client.py`/`cloudflare_client.py`; уважать переданный `temperature` в `cerebras_client.py`.

## Рефакторинг: первоочередные файлы

| Приоритет | Файл | Обоснование |
|---|---|---|
| 1 | `src/model_dispatcher.py` | Наибольшая концентрация ответственностей и хрупких мест (см. A2; `"provider_name" in locals()`, дубли импортов `asyncio`/`settings`, смешение стриминг/не-стриминг путей). |
| 2 | `src/config.py` | Дефолт для `REQUEST_TIMEOUT_SECONDS` (P0-фикс: сейчас его отсутствие роняет 6 клиентов при отсутствии ключа в `settings.json`); удалить мёртвые ключи (`WAIT_FOR_QUOTA`, `CONTEXT_TASK_*`, `HTTP_CONNECT_TIMEOUT`, `HTTP_READ_TIMEOUT`) и мёртвую копию `UNIVERSAL_STYLE_GUIDE`; валидация типов при загрузке JSON. |
| 3 | `src/router.py` | Убрать `ProjectLogger.configure()` на уровне модуля (ломает `LOG_LEVEL`), неиспользуемые `TODAY`/`CUR_FILE`, импорт `app` внутри `get_provider_list_from_state`; унифицировать коды ошибок (см. ниже). |
| 4 | `src/admin.py` | Разбить на `admin_limits.py` / `admin_usage.py` / `conversations_api.py` / `static_files.py`; для статики использовать `fastapi.staticfiles.StaticFiles` (решит path traversal и бинарные файлы). |
| 5 | `src/usage_tracker.py`, `src/conversation_store.py` | Атомарные записи, батчинг/дебаунс (A3); `threading.Lock` → `asyncio.Lock` или вынос в поток. |
| 6 | `src/api_clients/*` | Общий базовый класс для httpx-клиентов (единый SSE-парсинг, переиспользуемый клиент, классификация ошибок по статусам); общая утилита классификации ошибок SDK вместо подстрочного копипаста. |

## Семантика ошибок (P0, быстрый выигрыш)

- Возвращать ошибки как HTTP 4xx/5xx с OpenAI-совместимым объектом `error` вместо HTTP 200 + `finish_reason="error"` (`src/router.py`, `build_error_response`): 429 при исчерпании квот, 502/503 при недоступности всех провайдеров, 400 при невалидном запросе.
- Для specific routing добавить хотя бы один retry с fallback внутри провайдера (сейчас — ровно одна попытка).
- Выбрасывать `AllProvidersExhaustedError` (класс существует, но не используется) вместо возврата «ошибки как ответа».

## DX (Developer Experience)

### Тесты
- Создать `pyproject.toml`/`pytest.ini`: `asyncio_mode=auto`, `pythonpath=.`, маркеры `unit`/`integration`/`e2e`/`live` — устранит `sys.path`-хаки в каждом тест-файле и ручные списки исключений в `run_tests.py`.
- Зафиксировать версии зависимостей (pip-tools/uv lock): текущая расфиксировка уже привела к несовместимости FastAPI 0.115.x / Starlette ≥1.0 (shim в `tests/e2e/test_agent_framework_e2e.py`, отключённые тесты в `run_tests.py`).
- Покрыть пробелы: стриминг-путь dispatcher (usage/affinity), hot-reload лимитов, `_parse_bool_header`, fallback-логика vision-routing, ошибки 4xx/5xx после их внедрения.
- Добавить нагрузочный тест с мок-провайдерами (concurrent-запросы), чтобы ловить блокировки event loop.

### CI/CD
- Отсутствует (нет `.github/workflows/`). Минимальный pipeline: lint (`ruff`) + type-check (`mypy` или `pyright` — в проекте нет аннотаций возврата у части функций и нет mypy-конфига) + `run_tests.py` на матрице Python 3.11/3.12.
- Docker: non-root пользователь (`USER`), объявить `VOLUME` для `logs/`, `usage_stats.json`, `conversations.json`; healthcheck `CMD curl /health`.

### Локальный запуск
- `docker-compose.yml` с монтированием `.env` и volumes для runtime-файлов; опционально сервис Ollama для локального провайдера.
- `Makefile`/скрипты: `make run`, `make test`, `make test-live`, `make check-availability` (обёртка `python -m tests.test_models_availability`).
- Предзаполненный `provider_model_limits.json` записями DeepSeek/Cloudflare/Ollama (сейчас клиенты существуют, но провайдеры неактивны из-за отсутствия в реестре — неочевидное поведение для новых пользователей).

## Рекомендуемый порядок работ

1. **P0-фиксы** (малые, высокие последствия): дефолт `REQUEST_TIMEOUT_SECONDS`; перенос `ProjectLogger.configure` из `src/router.py`; контракт `stream` в DeepSeek/Cloudflare; HTTP-статусы ошибок.
2. **P1-производительность**: async-SDK (B1), переиспользуемые httpx-клиенты (B2), асинхронная персистентность (A3/B3), `GLOBAL_PROVIDER_LOCK=false` по умолчанию (B5).
3. **P1-архитектура**: декомпозиция dispatcher (A2), внешнее состояние (A1).
4. **P2**: CI/CD, фиксация версий, рефакторинг `src/admin.py`, подключение автообнаружения моделей (A4).
