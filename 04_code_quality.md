# 04 — Оценка качества кодовой базы

## Общая оценка

| Критерий | Оценка | Комментарий |
|---|---|---|
| Читаемость | 7/10 | Модули небольшие, докстринги и комментарии на английском присутствуют, имена осмысленные. Снижают оценку дубли импортов в `src/model_dispatcher.py` (`import asyncio` и `from .config import settings` — по два раза), неиспользуемые модульные константы (`TODAY`, `CUR_FILE` в `src/router.py`) и магические числа без констант. |
| Модульность | 8/10 | Чёткое расслоение: HTTP → dispatcher → selector/limits → адаптеры. Плагин-слой `src/api_clients/` добавляет провайдера одним файлом. Слабое место — `ModelDispatcher` совмещает маршрутизацию, retry, сборку messages, мультимодальную деградацию и учёт использования. |
| Связность | 6/10 | Ядро связано с конкретными структурами (`selector.providers` — `dict[str, ApiProvider]` — читается напрямую из dispatcher: `_get_model_modality`, `_find_vision_model`, `_calculate_target_context_tokens`). `src/router.py::get_provider_list_from_state` импортирует `app` из `src/server.py` внутри функции. |
| Тестируемость | 7/10 | Ядро покрыто unit/integration-тестами на моках (`tests/unit/`, `tests/integration/`), клиенты провайдеров — через общий миксин `tests/unit/providers/_base.py`. Проблемы: нет `pytest.ini`/`pyproject.toml`, `sys.path`-хаки в каждом тест-файле, часть e2e отключена из-за несовместимости FastAPI/Starlette (следствие незафиксированных версий). |

## Соответствие стандартам

### SOLID

- **S (Single Responsibility)** — нарушено в `src/model_dispatcher.py` (~660 строк, 5+ зон ответственности) и в `src/admin.py` (UI-роуты, limits API, usage API, conversations API, раздача статики в одном модуле).
- **O (Open/Closed)** — соблюдено на уровне провайдеров: новый клиент не требует правки существующего кода (`ProviderRegistry.auto_discover`).
- **L (Liskov)** — нарушено фактически: `DeepSeekClient.call_model_api` и `CloudflareClient.call_model_api` не принимают параметр `stream`, объявленный в контракте `ApiInterface.call_model_api`. Вызов со `stream=True` даст `TypeError`. Дефект спящий — оба провайдера отсутствуют в `src/provider_model_limits.json` и вычищаются при старте.
- **I (Interface Segregation)** — контракт `ApiInterface` минималистичен, замечаний нет.
- **D (Dependency Inversion)** — соблюдён частично: dispatcher зависит от абстракции `ApiInterface` через реестр, но напрямую читает внутренности `ModelSelector.providers` вместо методов селектора.

### DRY

- Эвристика оценки токенов `int(len(text.split()) * 1.3)` продублирована: `src/model_selector.py::estimate_tokens` и `src/context_manager.py::_estimate_tokens`.
- `UNIVERSAL_STYLE_GUIDE` существует в двух экземплярах: `src/style_config.py` (используется) и `src/config.py::Settings.UNIVERSAL_STYLE_GUIDE` (мёртвая копия).
- Классификация ошибок по подстрокам (`"429" in error_str`, `"rate"`, `"api key"`) скопирована в `gemini_client.py`, `groq_client.py`, `mistral_client.py`, `cerebras_client.py` почти дословно.
- SSE-парсинг (`data: ` / `[DONE]`) независимо реализован в `nvidia_client.py` и `ollama_client.py`.

### KISS

- В целом соблюдён; усложнения оправданы предметной областью (4 режима контекста, скользящие окна лимитов).
- Избыточность: `ModelSelector.refresh_registry` и `ModelDispatcher.list_all_provider_models` — мёртвый код (ни одного вызова в кодовой базе); настройки `WAIT_FOR_QUOTA`, `CONTEXT_TASK_AWARE_ENABLED`, `CONTEXT_TASK_DEFAULT`, `HTTP_CONNECT_TIMEOUT`, `HTTP_READ_TIMEOUT` определены, но не читаются; поля `summarization.enabled/mode/timeout_ms/fallback_to_extractive` в `settings.json` не маппятся в `src/config.py`.

### Идиомы Python

- Современный синтаксис используется (`X | Y`-типы, `list[str]`, `asynccontextmanager`).
- Антипаттерны: проверка `"provider_name" in locals()` для управления failover в `src/model_dispatcher.py` (хрупко: если `select()` бросит исключение до присваивания, в `exclude_providers` может попасть провайдер с прошлой итерации); `temperature or settings.DEFAULT_TEMPERATURE` и `max_tokens or settings.DEFAULT_MAX_TOKENS` — легитимные `0.0`/`0` подменяются дефолтами; `threading.Lock` в `ConversationStore`/`UsageTracker` внутри async-приложения.

## Технический долг и code smells

### Критичные (влияют на корректность)

1. **`settings.REQUEST_TIMEOUT_SECONDS` без дефолта** (`src/config.py`): атрибут появляется только при наличии `http.timeout_seconds` в `settings.json`. Шесть клиентов (`groq_client.py`, `cerebras_client.py`, `mistral_client.py`, `deepseek_client.py`, `cloudflare_client.py`, `ollama_client.py`) читают его в конструкторе. Без ключа в `settings.json` клиенты падают с `AttributeError`, `auto_discover` молча пропускает их — сервер стартует с урезанным набором провайдеров без явной ошибки.
2. **`LOG_LEVEL` игнорируется**: `src/router.py` вызывает `ProjectLogger.configure(level=logging.INFO)` на уровне модуля при импорте; повторный вызов в `src/server.py` с `settings.LOG_LEVEL` становится no-op (`_is_configured`).
3. **Ошибки возвращаются как HTTP 200**: исчерпание всех провайдеров → `build_error_response` со статусом 200 (`finish_reason="error"`). Клиенты, реагирующие на HTTP-статусы (OpenAI SDK, retry-механизмы), ошибку не увидят. Отклонение от OpenAI-конвенции (объект `error` + 4xx/5xx).
4. **Specific routing без retry**: `model="provider/model"` выполняет ровно одну попытку, тогда как meta-routing — до `MAX_RETRIES`. Несогласованная отказоустойчивость.
5. **Квота списывается до вызова** (`ApiProvider.select_within` → `record_usage`): неудачный запрос всё равно расходует лимит; при failover расходуются квоты нескольких провайдеров.
6. **Стриминг-путь неполноценен**: не вызываются `ResponseNormalizer`, `UsageTracker.record_usage`; при specific routing не обновляется session affinity.
7. **Потенциально бесконечный цикл ожидания**: в цикле retry при `0 < wait_time <= MAX_QUOTA_WAIT` (дефолт 3600с) выполняется `asyncio.sleep(wait_time); continue` без инкремента `attempt` — при хронической нехватке квоты запрос может «спать» неограниченно долго.

### Высокие (архитектурные)

8. **Синхронные SDK блокируют event loop**: `groq_client.py`, `cerebras_client.py` используют синхронные SDK (включая итерацию стриминга) внутри async-функций; `mistral_client.py::chat.complete` и `gemini_client.py::list_models` — синхронные вызовы. Один медленный запрос останавливает обработку всех остальных на данном воркере.
9. **Синхронная запись JSON на каждый запрос**: `UsageTracker.record_usage` под `Lock` выполняет `json.dump` всего файла на каждое обращение; `ConversationStore` переписывает весь `conversations.json` на каждую операцию. Записи не атомарны (сбой посреди записи → повреждение файла).
10. **Состояние только в памяти процесса**: usage-окна, cooldown, affinity не переживают рестарт (отмечено в roadmap); горизонтальное масштабирование невозможно — каждый инстанс ведёт собственный учёт лимитов.
11. **`GLOBAL_PROVIDER_LOCK=true` в штатном `settings.json`**: полная сериализация запросов к каждому провайдеру — искусственный потолок пропускной способности (1 одновременный запрос на провайдера).
12. **Мёртвые подсистемы**: `refresh_registry()`/`list_all_provider_models()` (автообновление реестра) не подключены ни к одному маршруту или таймеру.

### Средние (code smells)

13. `src/context_manager.py::_select_dynamic` переводит токены в сообщения делением на 50 — эвристика, не использующая реальный подсчёт токенов; `_select_static` игнорирует `target_context_tokens`.
14. `ContextManager._usage_history` — неограниченно растущий `dict` по сессиям (pruning отсутствует, в отличие от affinity-карты).
15. Reservoir-суммаризация пересчитывается на каждом запросе заново (O(история) по предложениям), кэширование отсутствует.
16. `ChatMessage.role: Literal["system", "user", "assistant"]` — роли `tool`/`function`/`developer` отклоняются валидацией; README декларирует их поддержку «в будущем».
17. `src/model_selector.py::_select_from_list_roundrobin` использует `self.models.index(m)` (O(n)) внутри цикла.
18. `GeminiClient` хардкодит `tools=[GoogleSearch()]`, `seed=42`, `top_k=1` — принудительный grounding каждым запросом (дополнительная латентность/расход квоты), не конфигурируется.
19. `CerebrasClient` игнорирует переданный `temperature` (хардкод `0.5`); `DeepSeekClient`/`CloudflareClient` содержат `await asyncio.sleep(0.5)` — фиксированный дроссель.
20. Новый `httpx.AsyncClient` создаётся на каждый запрос во всех httpx-клиентах — нет переиспользования соединений.
21. `requirements.txt` без версий: окружение невоспроизводимо, уже проявилось в несовместимости FastAPI 0.115.x / Starlette ≥1.0 (см. shim в `tests/e2e/test_agent_framework_e2e.py` и исключения в `run_tests.py`).

## Узкие места (bottlenecks)

| Место | Причина | Эффект |
|---|---|---|
| `src/usage_tracker.py::record_usage` | Синхронный `json.dump` под `Lock` на каждый запрос | Рост латентности и блокировка event loop под нагрузкой |
| `src/model_dispatcher.py` при `GLOBAL_PROVIDER_LOCK=true` | `asyncio.Lock` на провайдера | 1 конкурентный запрос на провайдера |
| `src/api_clients/groq_client.py`, `cerebras_client.py` | Синхронный SDK в async-контексте | Блокировка event loop на время генерации (в стриминге — на каждый чанк) |
| `src/context_manager.py::_extractive_summarize` | Пересчёт суммаризации на каждый запрос | CPU-расход, линейный от длины истории |
| `src/conversation_store.py` | Полная перезапись файла + `threading.Lock` | Деградация при росте `conversations.json` |
| httpx-клиенты | Новый клиент/соединение на запрос | Лишние TCP/TLS-handshake |

## Безопасность и надёжность

1. **Отсутствие аутентификации на шлюзе**: любой клиент с сетевым доступом вызывает `/v1/*` и `/admin/*`. `HOST=0.0.0.0` по умолчанию.
2. **Админ-панель без защиты**: `PUT /admin/api/limits` позволяет удалённо переписать реестр лимитов, `POST /admin/api/usage/reset` — обнулить статистику.
3. **CORS**: `allow_origins=["*"]` одновременно с `allow_credentials=True` — комбинация нарушает спецификацию (браузеры отклоняют credentials с wildcard) и сигнализирует об отсутствии продуманной политики.
4. **Идентификация устройств по `X-Device-ID`**: клиентский заголовок без проверки — зная/угадав ID, можно читать и изменять чужие диалоги (`/api/conversations*`).
5. **Раздача статики** (`src/admin.py::serve_static`): защита от path traversal — только проверка `".." in filename`; файл открывается в текстовом режиме (бинарные ассеты сломают раздачу).
6. **Утечка деталей во вне**: `HTTPException(500, detail=f"Error: {ex}")` в `src/router.py` передаёт внутренние сообщения об ошибках клиенту; в логи пишется содержимое промптов (`chat() — user_prompt: {user_prompt[:80]}...`) — риск для PII.
7. **Нет лимитов на размер запроса**: base64-изображения в `messages` не ограничены — потенциальное исчерпание памяти.
8. **Отсутствие валидации `provider_model_limits.json` при записи** из админки: проверяется только структура верхнего уровня, значения лимитов (отрицательные, нечисловые) не контролируются; повреждённый JSON валит сервер при следующем старте/hot-reload.
9. **Надёжность персистентности**: записи JSON не атомарны (нет tmp-файл + rename), резервные копии не создаются.
10. **Docker**: контейнер запускается от root, runtime-файлы (`usage_stats.json`, `conversations.json`, `logs/`) пишутся внутрь образа без объявления volumes.
