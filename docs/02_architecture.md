# 02 — Архитектура и паттерны

## Высокоуровневая архитектура

**Модульный монолит** (single-process FastAPI-приложение) с выраженной **слоистой архитектурой** и **плагин-слоем** адаптеров провайдеров. Микросервисов, очередей и внешних хранилищ нет; горизонтальное масштабирование штатно не поддерживается (состояние — в памяти процесса, см. ниже).

```
┌─────────────────────────────────────────────────────────────────────┐
│ HTTP-слой (FastAPI routers)                                         │
│   src/router.py        — OpenAI-совместимый API (/v1/*)             │
│   src/admin.py         — админ-API, чат-API, раздача статики        │
├─────────────────────────────────────────────────────────────────────┤
│ Слой ядра (orchestration)                                           │
│   src/model_dispatcher.py  — маршрутизация, retry/failover,         │
│                              session affinity, сборка messages      │
├─────────────────────────────────────────────────────────────────────┤
│ Слой выбора и квотирования                                      │
│   src/model_selector.py    — стратегии выбора провайдера            │
│   src/api_provider.py      — выбор модели внутри провайдера         │
│   src/api_limits_tracker.py— скользящие окна rate-limit             │
├─────────────────────────────────────────────────────────────────────┤
│ Вспомогательные подсистемы                                          │
│   src/context_manager.py, src/response_normalizer.py,               │
│   src/style_config.py, src/usage_tracker.py,                        │
│   src/conversation_store.py, src/model_metadata.py                  │
├─────────────────────────────────────────────────────────────────────┤
│ Плагин-слой адаптеров провайдеров                                   │
│   src/api_clients/*.py — по одному классу на провайдера,            │
│   все реализуют src/api_clients/api_interface.py::ApiInterface      │
└─────────────────────────────────────────────────────────────────────┘
```

Точка входа — `src/server.py`: создаёт `FastAPI(lifespan=lifespan)`, подключает `CORSMiddleware`, монтирует `api_router` и `admin_router`, запускает `uvicorn`.

## Основные паттерны проектирования

| Паттерн | Где реализован | Описание |
|---|---|---|
| **Service Registry / автообнаружение** | `src/provider_registry.py::ProviderRegistry.auto_discover()` | Сканирует пакет `src/api_clients/` через `pkgutil.iter_modules` + `inspect` и регистрирует все подклассы `ApiInterface` с непустым `PROVIDER_NAME`. Добавление провайдера = новый файл без правки реестра. |
| **Template Method / контракт** | `src/api_clients/api_interface.py::ApiInterface` | ABC с абстрактными `call_model_api()` и `list_models()`; атрибуты-флаги `PROVIDER_NAME`, `supports_multimodal`. |
| **Adapter** | каждый `src/api_clients/*_client.py` | Приводит разнородные SDK/REST API провайдеров к единой сигнатуре `call_model_api(messages, model, temperature, max_tokens, stream)`. |
| **Dependency Injection (ручной)** | `src/server.py::lifespan` → `app.state` | Объекты `registry`, `selector`, `dispatcher`, `conversation_store`, `usage_tracker` создаются один раз и внедряются через `request.app.state`; роуты получают их через хелперы `get_dispatcher()` и т.п. в `src/router.py`. |
| **Strategy** | `src/model_selector.py` (`provider_strategy`, `model_strategy`: `roundrobin`/`random`); `src/context_manager.py` (режимы `static`/`dynamic`/`reservoir`/`adaptive`/`disabled`) | Выбор поведения во время выполнения по конфигурации. |
| **Sliding Window rate limiter** | `src/api_limits_tracker.py` | 7 дек (`deque`) с timestamp-ами запросов/токенов по окнам 1с/1м/1ч/1сут; `can_handle()`, `get_wait_time()`, `record_usage()`. |
| **Circuit Breaker (упрощённый)** | `ApiLimitsTracker.trigger_cooldown()` + `ModelSelector.trigger_circuit_breaker()` | При `RateLimitError` модель переводится в cooldown на 60с (прочие ошибки — 30с); `can_handle()` возвращает `False` до истечения `cooldown_until`. |
| **Retry с failover (fallback chain)** | `src/model_dispatcher.py::ModelDispatcher.chat()` | Цикл до `MAX_RETRIES` попыток; каждая неудача добавляет провайдера в `exclude_providers`, следующая попытка уходит к другому провайдеру. |
| **Factory** | `src/models.py::build_response()`, `build_error_response()` | Сборка OpenAI-совместимого ответа из сырых значений. |
| **Singleton (мягкий)** | `src/config.py` (`settings = Settings()` на уровне модуля) | Единый объект конфигурации, импортируется всеми модулями. |
| **Layered configuration** | `src/config.py::Settings.__init__` | Дефолты → `settings.json` → переменные окружения (ENV перекрывает всё). |

## Схема потока данных (Data Flow)

### `POST /v1/chat/completions` (не-стриминг)

```
Клиент
  │  JSON body + заголовки X-Session-ID, X-Use-ServerSide-System-Prompt
  ▼
src/router.py::chat_completions
  │  request.json() → ChatCompletionRequest (валидация Pydantic, src/models.py)
  │  conversation_history = messages[:-1]
  ▼
src/model_dispatcher.py::ModelDispatcher.chat()
  │
  ├─ model содержит "/" (specific routing)?
  │    да → разбор provider/model, коррекция провайдера по имени модели,
  │         vision-fallback при изображениях → сразу call_provider_api()
  │    нет → meta routing:
  │         ├─ session affinity: чтение session_affinity_map (asyncio.Lock),
  │         │   pruning просроченных сессий (SESSION_TTL_HOURS)
  │         └─ цикл attempt < MAX_RETRIES:
  │              ▼
  │  src/model_selector.py::ModelSelector.select()
  │    порядок провайдеров: preferred → roundrobin/random, минус exclude_providers
  │    фильтры: model_type / model_scale / model_name / modality
  │              ▼
  │  src/api_provider.py::ApiProvider.select_within()
  │              ▼
  │  src/api_limits_tracker.py::can_handle() — скользящие окна + cooldown
  │    ├─ да  → record_usage() → (provider, model, 0.0)
  │    └─ нет → минимальный wait_time → asyncio.sleep(wait) → повторная попытка
  │
  ▼
src/model_dispatcher.py::call_provider_api()
  │  1. ContextManager.select_context_for_request() — отбор истории по режиму
  │  2. Сборка messages:
  │     - verbatim-путь (client_messages, при USE_SERVER_SIDE_SYSTEM_PROMPT=false):
  │       массив клиента как есть, без инъекций
  │     - legacy-путь: [system + STANDARD_SYSTEM_PROMPT + style_directive,
  │       ...context, user]
  │  3. Деградация мультимодальности: для не-vision моделей image_url-части
  │     отбрасываются, текст склеивается
  │  4. Опциональная сериализация: GLOBAL_PROVIDER_LOCK → asyncio.Lock на провайдера
  │              ▼
  │  src/provider_registry.py::get_client(provider) → ApiInterface-клиент
  │              ▼
  │  src/api_clients/<provider>_client.py::call_model_api()
  │     → внешний API провайдера (SDK или httpx)
  │     → исключения маппятся в RateLimitError / AuthenticationError / ProviderError
  │              ▼
  │  5. ResponseNormalizer.normalize() (только не-стриминг)
  │  6. ContextManager.update_usage() (для dynamic-режима)
  │  7. UsageTracker.record_usage() → запись в usage_stats.json
  │  8. Обновление session_affinity_map
  ▼
build_response() → ChatCompletionResponse (Pydantic)
  ▼
src/router.py → JSONResponse (HTTP 200)
```

### Стриминг (SSE)

`dispatcher.chat()` при `stream=True` возвращает асинхронный генератор, обёрнутый в `_stream_with_meta()` (первым элементом идёт dict `{"type": "meta", provider, model}`). `src/router.py::stream_generator()` преобразует элементы в SSE-кадры `chat.completion.chunk` и завершает поток `data: [DONE]`. Ошибки внутри потока сериализуются как chunk с `"finish_reason": "error"`.

**Особенности стриминг-пути:** нормализация ответа, `UsageTracker` и обновление affinity для стриминга частично отсутствуют (см. `04_code_quality.md`).

### Админ-контур

`PUT /admin/api/limits` (`src/admin.py::update_limits`) → валидация структуры → запись `src/provider_model_limits.json` → **hot-reload**: `ModelSelector.load_api_limits_from_json()` и атомарная замена `selector.providers`/`provider_sequence` без перезапуска сервера.

## Управление состоянием

| Состояние | Где хранится | Механизм |
|---|---|---|
| Лимиты/usage-окна моделей | память процесса (`ApiLimitsTracker.deque_*`) | скользящие окна, не переживают рестарт (в roadmap — персистентность) |
| Session affinity | память (`ModelDispatcher.session_affinity_map`) | `asyncio.Lock`, TTL `SESSION_TTL_HOURS`, лимит `SESSION_MAX_SESSIONS` с LRU-pruning |
| Сериализация запросов к провайдеру | память (`ModelDispatcher.provider_locks`, `defaultdict(asyncio.Lock)`) | включается `routing.global_provider_lock` в `settings.json` |
| История использования контекста (dynamic-режим) | память (`ContextManager._usage_history`) | последние 10 значений на сессию |
| Реестр моделей/лимитов | `src/provider_model_limits.json` | чтение при старте (`ModelSelector`), запись из `/admin` и `save_registry_to_json()` |
| Статистика использования | `usage_stats.json` | `UsageTracker`, синхронная запись на каждый запрос |
| Диалоги чат-UI | `conversations.json` | `ConversationStore`, `threading.Lock`, полная перезапись файла |
| Конфигурация поведения | `settings.json` | читается **один раз** при старте (`Settings._load_from_json`) |

**Кэширование ответов отсутствует** (в roadmap — prompt caching layer). Единственный кэш-эффект даёт session affinity (привязка к провайдеру ради provider-side context caching).

## Управление конфигурациями

Три слоя в `src/config.py::Settings` (порядок применения: каждый следующий перекрывает предыдущий):

1. **Дефолты** — `_set_defaults()`: ключи пусты, `HOST=0.0.0.0`, `PORT=8000`, `PROVIDER_STRATEGY=roundrobin`, `MAX_RETRIES=3`, `MAX_QUOTA_WAIT=3600`, системные промпты, параметры контекста, HTTP-таймауты (`HTTP_TIMEOUT` и др.).
2. **`settings.json`** (корень проекта) — `_load_from_json()`: точечный маппинг `session.*`, `context.*`, `summarization.max_tokens`, `routing.*`, `http.timeout_seconds`.
3. **Переменные окружения / `.env`** — `_load_from_env()` через `python-dotenv`: API-ключи (`GEMINI_APIKEY`, `GROQ_APIKEY`, …), `HOST`/`PORT`, `SESSION_AFFINITY_ENABLED`, `CONTEXT_MANAGEMENT_MODE`, `GLOBAL_PROVIDER_LOCK`, `REGISTRY_FILE`.

Нюансы, влияющие на разработку:

- Атрибут `settings.REQUEST_TIMEOUT_SECONDS` **не имеет дефолта** и появляется только если в `settings.json` задан `http.timeout_seconds`; его используют `groq_client.py`, `cerebras_client.py`, `mistral_client.py`, `deepseek_client.py`, `cloudflare_client.py`, `ollama_client.py`. `nvidia_client.py` использует `settings.HTTP_TIMEOUT`.
- Часть ключей конфигурации не читается нигде: `WAIT_FOR_QUOTA`, `CONTEXT_TASK_AWARE_ENABLED`, `CONTEXT_TASK_DEFAULT`, `HTTP_CONNECT_TIMEOUT`, `HTTP_READ_TIMEOUT`, а из `settings.json` — `summarization.enabled/mode/timeout_ms/fallback_to_extractive`.
- Заголовки протокола настраиваемы: `SESSION_ID_HEADER` (`X-Session-ID`), `USE_SERVER_SIDE_SYSTEM_PROMPT_HEADER` (`X-Use-ServerSide-System-Prompt`).
