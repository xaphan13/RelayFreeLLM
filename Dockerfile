# Minimal Dockerfile for RelayFreeLLM
# Follows Docker best practices for Python apps.

FROM python:3.12-slim

# Pin uv to the version used to generate uv.lock
COPY --from=ghcr.io/astral-sh/uv:0.9.18 /uv /uvx /bin/

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Install dependencies first so this layer is cached
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

# Copy only application source and minimal config to keep image small
COPY src/ ./src/
COPY settings.json ./

# Use the project's virtualenv directly
ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

CMD ["python", "-m", "src.server"]
