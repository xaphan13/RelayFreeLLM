# 03 — Логика и работа кода (Execution Flow)

## Жизненный цикл приложения

### Инициализация и запуск

Точка входа — `python -m src.server` (`src/server.py`, блок `__main__`): `uvicorn.run(app, port=settings.PORT, host=settings.HOST)`.

Порядок событий при старте:

1. **Импорт модулей.** При импорте `src/config.py` создаётся синглтон `settings = Settings()`: `load_dotenv(.env)` → `_set_defaults()` → `_load_from_json()` (`settings.json`) → `_load_from_env()`. При импорте `src/router.py` на уровне модуля вызывается `ProjectLogger.configure(level=logging.INFO)` — из-за флага `_is_configured` последующий вызов в `src/server.py` (с `settings.LOG_LEVEL`) становится no-op, т.е. `LOG_LEVEL` фактически игнорируется (см. `04_code_quality.md`).
2. **`lifespan(app)`** (`src/server.py::lifespan`) — startup-фаза:
   - `ProviderRegistry().auto_discover()` (`src/provider_registry.py`): сканирование `src/api_clients/` через `pkgutil.iter_modules`, импорт каждого модуля, поиск подклассов `ApiInterface` с непустым `PROVIDER_NAME`, инстанцирование. Ошибки инстанцирования (например, отсутствует API-ключ → `ValueError` из `Settings.get_api_key`, или `AttributeError` из-за `settings.REQUEST_TIMEOUT_SECONDS`) логируются как warning, клиент **пропускается**.
   - `ModelSelector()` (`src/model_selector.py`): чтение `src/provider_model_limits.json` → построение `dict[provider_name → ApiProvider]`, где каждая модель обёрнута в `ApiLimitsTracker`. Ошибка чтения/парсинга JSON не обрабатывается — падение при старте.
   - **Синхронизация двух реестров**: пересечение зарегистрированных клиентов и провайдеров из JSON. Лишние клиенты удаляются (`registry.unregister`), провайдеры без кода/ключей — из селектора (`selector.remove_provider`). Пустое пересечение → `logger.critical(...)` + `sys.exit(1)`.
   - Создание `ConversationStore` (загрузка `conversations.json`), `UsageTracker` (загрузка `usage_stats.json`), `ModelDispatcher(registry, selector, usage_tracker)`.
   - Инъекция всех объектов в `app.state`.
3. **Middleware и роутеры**: `CORSMiddleware` (allow-all), `app.include_router(api_router)` (`src/router.py`), `app.include_router(admin_router)` (`src/admin.py`).
4. `yield` в `lifespan` — сервер обслуживает запросы.

### Завершение работы

Единственное действие после `yield` — лог `=== RelayFreeLLM shutting down ===`. Graceful-закрытие HTTP-клиентов, сброс буферов и финальная персистентность не выполняются (всё состояние, живущее в памяти — usage-окна, affinity, cooldown — теряется; JSON-файлы к этому моменту уже записаны синхронно в момент каждого события).

## Ключевые бизнес-процессы

### Процесс 1: Meta-routing (`model="meta-model"`, без стриминга)

1. `src/router.py::chat_completions`: парсинг JSON → `ChatCompletionRequest` (Pydantic-валидация), чтение заголовков `X-Session-ID` (default `"default"`) и `X-Use-ServerSide-System-Prompt` (`_parse_bool_header` → `True/False/None`), `conversation_history = messages[:-1]`.
2. `ModelDispatcher.chat()` (`src/model_dispatcher.py`):
   - Извлечение `user_prompt` (текст), `user_content` (оригинальный content последнего user-сообщения, может быть list для мультимодальности), `has_images` (`_request_contains_images`), `sys_prompt`, параметров.
   - Разрешение `effective_use_ss`: override из заголовка либо `settings.USE_SERVER_SIDE_SYSTEM_PROMPT`. При `False` — `client_messages = request.messages` (verbatim-путь).
   - **Session affinity** (если включена и `session_id != "default"`): под `asyncio.Lock` — pruning просроченных (`SESSION_TTL_HOURS`) и лишних (`SESSION_MAX_SESSIONS`, удаляются наименее активные), чтение привязки `preferred_provider`/`affinity_model_name`, обновление `last_active`.
   - **Цикл попыток** `while attempt < MAX_RETRIES` (default 3):
     - `ModelSelector.select()` (`src/model_selector.py`): порядок провайдеров — `preferred` первым (только attempt 0), далее roundrobin (от `last_provider_index + 1`) или random, минус `exclude_providers`. Для каждого провайдера — `ApiProvider.select_within()` (`src/api_provider.py`): фильтры `model_type`/`model_scale`/`model_name` (substring)/`modality`, затем roundrobin/random по моделям с проверкой `ApiLimitsTracker.can_handle()`.
     - Если ни одна модель не проходит по лимитам — возвращается минимальный `wait_time`. При `wait_time > MAX_QUOTA_WAIT` — немедленный `build_error_response`; иначе `asyncio.sleep(wait_time)` и `continue` (счётчик попыток **не** увеличивается).
     - Успешный выбор → `record_usage()` на трекере модели (квота списывается **до** фактического вызова) → `call_provider_api()`.
   - **Обработка исключений в цикле**: `AuthenticationError` / `ProviderError` / `RateLimitError` / прочие → `attempt += 1`, провайдер добавляется в `exclude_providers`; для `RateLimitError` — circuit breaker на 60с, для прочих — 30с (`selector.trigger_circuit_breaker`). После исчерпания попыток — `build_error_response` (возвращается как HTTP 200).
   - Успех → `UsageTracker.record_usage()` (синхронная запись `usage_stats.json`), обновление affinity, `build_response()` с `meta` (provider/model/latency/attempt).

### Процесс 2: Specific routing (`model="provider/model"`)

1. Разбор `provider/model` (`split("/", 1)`). Если модель не найдена у указанного провайдера — поиск по всем провайдерам и коррекция (`Corrected provider ...`).
2. **Vision-fallback**: при `has_images` и `modality != "vision"` у запрошенной модели — поиск vision-модели в том же провайдере (`_find_vision_model`), иначе `selector.select(modality="vision")` у любого провайдера; нет vision-моделей → `build_error_response`.
3. Один вызов `call_provider_api()` **без retry**; любое исключение → `build_error_response` (HTTP 200, `finish_reason="error"`).

### Процесс 3: Вызов провайдера (`call_provider_api`)

1. `registry.get_client(provider_name)`.
2. **Формирование messages**:
   - *Verbatim-путь* (`client_messages is not None`): отбор через `ContextManager.select_context_for_request()` (жёсткий token-кап), фильтрация пустых сообщений (`get_text().strip()`), без инъекции системных промптов.
   - *Legacy-путь*: `ContextManager` для `conversation_history`, затем `[system = sys_prompt + STANDARD_SYSTEM_PROMPT + style_directive, ...context, user]`. Системный промпт добавляется только если клиент прислал system-сообщение (`if system_prompt:`).
   - Расчёт бюджета контекста: `_calculate_target_context_tokens()` = `max_context_length модели − max_tokens − 500 (system overhead) − 100 (safety)`.
3. **Деградация мультимодальности**: если модель не vision и клиент не `supports_multimodal` — content-списки уплощаются в текст (image-части отбрасываются).
4. **Вызов**: при `settings.GLOBAL_PROVIDER_LOCK` — под `asyncio.Lock` провайдера (полная сериализация запросов к провайдеру), иначе напрямую. `api_client.call_model_api(messages, model, temperature|0.8, max_tokens|4000, stream)`.
5. **Постобработка** (только не-стриминг): `ResponseNormalizer.normalize()` (preamble, пустые блоки, whitespace, markdown/JSON-фикс), `ContextManager.update_usage()` для dynamic-режима.

### Процесс 4: Стриминг (SSE)

1. Клиенты провайдеров при `stream=True` возвращают async-генератор текстовых чанков (Gemini — нативный async; Groq/Cerebras — **синхронный** SDK-итератор внутри async-генератора; Mistral — `chat.stream_async`; NVIDIA/Ollama — парсинг SSE через `httpx`; DeepSeek/Cloudflare параметр `stream` **не принимают** — см. `04`).
2. `ModelDispatcher._stream_with_meta()` оборачивает генератор: первым элементом идёт `{"type": "meta", provider, model}`, далее `{"type": "content", data}`.
3. `src/router.py::stream_generator()` транслирует в SSE-кадры `chat.completion.chunk` (в каждый кадр добавляется нестандартное поле `provider`), завершает `data: [DONE]`. Исключение внутри потока → chunk с `"finish_reason": "error"` + `[DONE]`.
4. Для стриминга **не выполняются**: нормализация ответа, запись `UsageTracker`, обновление affinity при specific routing.

### Процесс 5: Управление контекстом (`src/context_manager.py`)

Режим задаётся `CONTEXT_MANAGEMENT_MODE` (в `settings.json` репозитория — `reservoir`):

- `static` — последние `CONTEXT_STATIC_RECENT_KEEP` (10) сообщений как есть.
- `dynamic` — по истории использования сессии (`_usage_history`, до 10 выборок) вычисляется `adjusted_target` (utilization target 0.8, boost до 1.5, min 0.3), затем грубый перевод токенов в число сообщений (`/50` — эвристика).
- `reservoir` — последние `CONTEXT_RESERVOIR_RECENT_KEEP` (15) сообщений + экстрактивная суммаризация старых: разбивка на предложения → TF-скоринг (нормализованная частота токенов без стоп-слов) → position bias (+20% первому предложению сообщения) → length factor → жадный отбор в бюджет `CONTEXT_RESERVOIR_SUMMARY_BUDGET` (400 токенов) с восстановлением исходного порядка; результат вставляется как system-сообщение `[Earlier conversation summary]`.
- `adaptive` — детект «кода» по ключевым словам (`def `, `class `, ` ``` ` и т.д.) во всей истории: код → reservoir, иначе → static.
- `disabled`/неизвестный → `[]`/static.

### Процесс 6: Админ-операции (`src/admin.py`)

- `PUT /admin/api/limits`: структурная валидация (`providers[]`, `name`, `models[]`, `limits`) → запись `src/provider_model_limits.json` → hot-reload: повторный `load_api_limits_from_json()` и замена `selector.providers`/`provider_sequence` in-place. Cooldown и usage-окна старых трекеров при этом **сбрасываются** (создаются новые объекты).
- `GET/POST /admin/api/usage`, `POST /admin/api/usage/reset` — операции с `UsageTracker`.
- `/api/conversations*` — CRUD диалогов через `ConversationStore`; авторизация — только по заголовку `X-Device-ID` (клиентский, угадываемый идентификатор).

## Роутинг и middleware

| Метод | Путь | Обработчик | Назначение |
|---|---|---|---|
| GET | `/` | `router.py::health` | Plain-text "Healthy". |
| GET | `/health` | `router.py::health_detail` | JSON: статус, имя meta-модели, список провайдеров. |
| POST | `/v1/chat/completions` | `router.py::chat_completions` | Основной OpenAI-совместимый эндпоинт. |
| GET | `/v1/models` | `router.py::list_models_openai` | Список моделей + `meta-model`; фильтры `?type=&scale=`; поля `status`, `cooldown_remaining_sec`. |
| GET | `/v1/usage` | `router.py::get_usage_v1` | Агрегированная статистика. |
| GET | `/admin`, `/chat` | `admin.py` | HTML-страницы из `src/static/`. |
| GET | `/static/{filename}` | `admin.py::serve_static` | Раздача статики; защита только проверкой `".." in filename`; чтение файлов в текстовом режиме. |
| GET/PUT | `/admin/api/limits` | `admin.py` | Чтение/запись лимитов + hot-reload. |
| GET/POST | `/admin/api/usage`, `/admin/api/usage/reset` | `admin.py` | Статистика и сброс. |
| CRUD | `/api/conversations*` | `admin.py` | Диалоги чат-UI (нужен `X-Device-ID`). |

Middleware единственный — `CORSMiddleware` с `allow_origins=["*"]` и `allow_credentials=True` (несовместимая комбинация по спецификации CORS: браузеры отклоняют credentials при wildcard). Аутентификация/rate-limiting на уровне шлюза отсутствуют.

Зависимости роутам передаются через `request.app.state` (хелперы `get_dispatcher/get_selector/get_usage_tracker` в `src/router.py`, `get_conversation_store` в `src/admin.py`); `health_detail` импортирует `app` из `src/server.py` внутри функции (обход циклического импорта).

## Обработка ошибок и логирование

### Иерархия исключений (`src/exceptions.py`)

`ProviderError` (база, хранит `provider`) → `RateLimitError` (429), `AuthenticationError` (401/403), `ModelNotFoundError`, `ProviderUnavailableError`; отдельно `AllProvidersExhaustedError` (определена, но **нигде не выбрасывается**).

### Классификация ошибок провайдеров

Каждый клиент в `src/api_clients/` маппит исключения SDK/HTTP в типизированные. Для SDK-клиентов (Gemini/Groq/Mistral/Cerebras) классификация — по подстрокам текста ошибки (`"429" in error_str`, `"rate"`, `"api key"` и т.п.); для httpx-клиентов (NVIDIA/DeepSeek/Cloudflare/Ollama) — по HTTP-статусам. Подстрочный подход хрупок (зависит от формулировок SDK).

### Уровни обработки

1. **Клиент провайдера** — маппинг в типизированные исключения.
2. **`ModelDispatcher.chat()`** — retry/failover по типу исключения; специфичные проверки через `"provider_name" in locals()`.
3. **`src/router.py`** — catch-all: лог + `HTTPException(500, detail=f"Error: {ex}")` (внутренние детали попадают клиенту). Ошибки бизнес-уровня (все провайдеры исчерпаны) возвращаются как **HTTP 200** с `build_error_response` (`finish_reason="error"`, `provider="none"`) — отклонение от OpenAI-конвенции (там ожидается HTTP 4xx/5xx с объектом `error`).
4. **Стриминг** — ошибка сериализуется в SSE-кадр с `"finish_reason": "error"`.

### Логирование (`src/logging_util.py`)

`ProjectLogger.configure()` — идемпотентная настройка root-логгера: консоль + файл `logs/RelayFreeLLM_YYYY-MM-DD.log` через `CompressedTimedRotatingFileHandler` (ротация в полночь, gzip после ротации, перенос архивов старше `retention_days=7` в `logs/archive/`). Формат: `%(asctime)s - %(name)s - %(levelname)s - %(message)s`. Именованные логгеры — `ProjectLogger.get_logger(__name__)` в каждом модуле. Известные дефекты: `LOG_LEVEL` из ENV не применяется (конфигурация в `src/router.py` при импорте выполняется раньше и блокирует повторную), в логи попадает содержимое промптов (`chat() — user_prompt: ...`).
