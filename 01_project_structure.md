# 01 — Карта проекта (Project Structure)

## Назначение проекта

**RelayFreeLLM** — OpenAI-совместимый LLM-шлюз (gateway), агрегирующий бесплатные тарифы нескольких AI-провайдеров (Gemini, Groq, Mistral, Cerebras, NVIDIA, DeepSeek, Cloudflare, локальный Ollama) в единую конечную точку `POST /v1/chat/completions`. Клиент обращается к шлюзу как к «одной модели» (`meta-model`), а система сама выбирает провайдера с доступной квотой, выполняет failover при ошибках/лимитах и возвращает ответ в стандартном формате OpenAI.

Дополнительные подсистемы: управление контекстом многооборотных диалогов (4 режима, включая экстрактивную суммаризацию), session affinity (привязка сессии к провайдеру), нормализация стиля ответов, веб-интерфейсы `/chat` и `/admin` (управление лимитами, мониторинг использования, серверное хранение диалогов).

## Дерево проекта

```
RelayFreeLLM/
├── src/                            # Исходный код сервера (Python, FastAPI)
│   ├── server.py                   # Точка входа: FastAPI app, lifespan (инициализация registry/selector/dispatcher), CORS, подключение роутеров, запуск uvicorn.
│   ├── router.py                   # HTTP-слой: OpenAI-совместимые эндпоинты /v1/chat/completions, /v1/models, /v1/usage, health. SSE-стриминг.
│   ├── admin.py                    # Админ-роутер: UI /admin и /chat, REST API лимитов (/admin/api/limits), статистики (/admin/api/usage) и диалогов (/api/conversations*). Раздача /static/*.
│   ├── config.py                   # Конфигурация Settings: 3 слоя (дефолты → settings.json → ENV). Синглтон `settings`.
│   ├── models.py                   # Pydantic-модели запроса/ответа (ChatCompletionRequest/Response, ChatMessage) и фабрики build_response/build_error_response.
│   ├── exceptions.py               # Типизированная иерархия ошибок: ProviderError, RateLimitError, AuthenticationError, ModelNotFoundError, ProviderUnavailableError, AllProvidersExhaustedError.
│   ├── logging_util.py             # ProjectLogger + CompressedTimedRotatingFileHandler: консоль + файл с ротацией, gzip-сжатием и архивацией.
│   │
│   ├── model_dispatcher.py         # ЯДРО: ModelDispatcher — выбор пути (specific/meta), retry-цикл с failover, session affinity, сборка messages, вызов провайдера, обёртка стриминга _stream_with_meta.
│   ├── model_selector.py           # ModelSelector — выбор провайдера/модели по стратегиям roundrobin/random с фильтрами (type/scale/name/modality), circuit breaker, hot-reload, refresh_registry.
│   ├── api_provider.py             # ApiProvider — выбор модели внутри одного провайдера (roundrobin/random) с учётом лимитов.
│   ├── api_limits_tracker.py       # ApiLimitsTracker — скользящие окна (deque) по 7 метрикам лимитов (req/sec|min|hr|day, tok/min|hr|day), can_handle/get_wait_time/trigger_cooldown/record_usage.
│   ├── provider_registry.py        # ProviderRegistry — автообнаружение клиентов: сканирует src/api_clients/ и регистрирует подклассы ApiInterface.
│   ├── model_metadata.py           # Эвристики определения типа модели (text/coding/image/...) и масштаба (large/medium/small) по имени.
│   ├── context_manager.py          # ContextManager — 4+1 режима отбора истории (static/dynamic/reservoir/adaptive/disabled) и экстрактивная TF-суммаризация старых сообщений.
│   ├── response_normalizer.py      # ResponseNormalizer — удаление preamble-фраз, починка JSON, стандартизация markdown/whitespace.
│   ├── style_config.py             # UNIVERSAL_STYLE_GUIDE и get_style_directive() — инъекция единого стиля в system prompt.
│   ├── conversation_store.py       # ConversationStore — серверное хранение диалогов чат-UI в conversations.json (threading.Lock, полная перезапись файла).
│   ├── usage_tracker.py            # UsageTracker — персистентная статистика запросов/токенов в usage_stats.json (запись на каждый запрос).
│   │
│   ├── provider_model_limits.json  # Реестр провайдеров/моделей: лимиты, type, scale, Max_Context_Length, modality. Редактируется через /admin, читается ModelSelector.
│   │
│   ├── api_clients/                # Адаптеры провайдеров (плагин-слой)
│   │   ├── api_interface.py        # ApiInterface (ABC): call_model_api(), list_models(), PROVIDER_NAME, supports_multimodal.
│   │   ├── client_config.py        # ClientConfig.GEMINI_SAFETY_SETTINGS — настройки безопасности Gemini.
│   │   ├── gemini_client.py        # Gemini (google-genai SDK, async-режим client.aio, мультимодальность, google_search tool).
│   │   ├── groq_client.py          # Groq (синхронный SDK Groq внутри async-функций).
│   │   ├── mistral_client.py       # Mistral (mistralai SDK; sync complete, async stream).
│   │   ├── cerebras_client.py      # Cerebras (синхронный SDK cerebras_cloud_sdk).
│   │   ├── nvidia_client.py        # NVIDIA (httpx, OpenAI-совместимый REST, стриминг).
│   │   ├── deepseek_client.py      # DeepSeek (httpx REST; без поддержки stream в сигнатуре — спящий дефект, см. 04).
│   │   ├── cloudflare_client.py    # Cloudflare Workers AI (httpx REST; без stream — спящий дефект).
│   │   └── ollama_client.py        # Ollama (httpx к локальному экземпляру, OpenAI-совместимый API).
│   │
│   └── static/                     # Фронтенд (vanilla JS/CSS/HTML, без сборки)
│       ├── admin.html/js/css       # Админ-дашборд: вкладки Limits (редактор лимитов) и Usage (статистика).
│       └── chat.html/js/css        # Чат-UI: стриминг, история (localStorage/сервер), изображения, markdown, темы.
│
├── tests/
│   ├── unit/                       # Юнит-тесты: models, context_manager, normalizer, usage_tracker, locking, фильтры выбора, system-prompt-режимы.
│   │   └── providers/              # Тесты каждого клиента провайдера на базе общего миксина _base.py (mock SDK/HTTP).
│   ├── integration/                # Интеграция dispatcher и контекста на моках.
│   ├── e2e/                        # E2E через TestClient: agent-framework-заголовки, роутинг, стриминг (частично отключены, см. 04).
│   ├── manual/                     # Ручные/live-скрипты против реального сервера и API (требуют ключей).
│   ├── performance/                # Стабильность: 100 последовательных запросов /v1/models.
│   ├── test_models_availability.py   # Проверка доступности всех моделей из реестра реальными вызовами.
│   └── api.http                    # Коллекция HTTP-запросов для ручной проверки.
│
├── settings.json                   # Поведенческие настройки: session, context, summarization, routing, http (загружается src/config.py).
├── .env.example                    # Шаблон API-ключей провайдеров.
├── requirements.txt                # Зависимости БЕЗ фиксации версий.
├── Dockerfile                      # python:3.12-slim, pip install, CMD python -m src.server.
├── .dockerignore
├── run_tests.py                    # Оффлайн-сьют pytest (исключает manual/performance/часть e2e).
├── run_tests_live.py               # Сьют, требующий запущенный сервер.
└── README.md                       # Пользовательская документация.
```

### Runtime-артефакты (создаются в рабочей директории при запуске)

| Путь | Создаётся | Назначение |
|---|---|---|
| `logs/RelayFreeLLM_YYYY-MM-DD.log` | `src/logging_util.py` | Логи (ротация раз в сутки, gzip, архив `logs/archive/`). |
| `usage_stats.json` | `src/usage_tracker.py` | Накопленная статистика запросов/токенов. |
| `conversations.json` | `src/conversation_store.py` | Серверное хранение диалогов чат-UI. |

## Внешние зависимости

Базы данных и брокеры сообщений **отсутствуют** — вся персистентность реализована JSON-файлами на локальном диске.

### Сторонние API (провайдеры LLM)

| Провайдер | Клиент | Транспорт | Ключ (ENV) | Статус в реестре |
|---|---|---|---|---|
| Google Gemini | `src/api_clients/gemini_client.py` | SDK `google-genai` (async) | `GEMINI_APIKEY` | Активен (есть в `src/provider_model_limits.json`) |
| Groq | `src/api_clients/groq_client.py` | SDK `groq` (sync) | `GROQ_APIKEY` | Активен |
| Mistral | `src/api_clients/mistral_client.py` | SDK `mistralai` | `MISTRAL_APIKEY` | Активен |
| Cerebras | `src/api_clients/cerebras_client.py` | SDK `cerebras_cloud_sdk` (sync) | `CEREBRAS_APIKEY` | Активен |
| NVIDIA | `src/api_clients/nvidia_client.py` | `httpx` → `integrate.api.nvidia.com/v1` | `NVIDIA_APIKEY` | Активен |
| DeepSeek | `src/api_clients/deepseek_client.py` | `httpx` → `api.deepseek.com/v1` | `DEEPSEEK_APIKEY` | **Неактивен**: нет записей в JSON-реестре → pruning при старте |
| Cloudflare | `src/api_clients/cloudflare_client.py` | `httpx` → `api.cloudflare.com` | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | **Неактивен**: нет записей в JSON-реестре |
| Ollama | `src/api_clients/ollama_client.py` | `httpx` → `OLLAMA_BASE_URL` (default `http://localhost:11434`) | Не требуется | **Неактивен**: нет записей в JSON-реестре |

Провайдер становится активным только при выполнении **двух** условий: клиент зарегистрирован (есть валидный ключ) **и** провайдер присутствует в `src/provider_model_limits.json` (см. `src/server.py::lifespan`).

### Python-зависимости (`requirements.txt`, версии не зафиксированы)

| Пакет | Роль |
|---|---|
| `fastapi`, `uvicorn` | Веб-фреймворк и ASGI-сервер. |
| `pydantic` | Валидация запросов/ответов (`src/models.py`). |
| `httpx` | Асинхронные HTTP-вызовы (NVIDIA, DeepSeek, Cloudflare, Ollama). |
| `google-genai`, `groq`, `mistralai`, `cerebras_cloud_sdk` | Официальные SDK провайдеров. |
| `python-dotenv` | Загрузка `.env` (`src/config.py`). |
| `requests` | Только ручные тесты `tests/manual/`. |
| `pytest`, `iniconfig` | Тесты (`iniconfig` — транзитивная зависимость pytest, указана избыточно). |
