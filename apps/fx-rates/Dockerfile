# fx-rates (Python 3.12, FastAPI). No OTel SDK: EDOT Python is injected by the OTel Operator.
# Debian slim (glibc) + Python 3.12 to match the injected EDOT Python agent.
FROM python:3.12.15-slim-bookworm AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install -r /tmp/requirements.txt

FROM python:3.12.15-slim-bookworm
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8080
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY *.py ./
USER 10001
EXPOSE 8080
# No --reload: the auto-instrumentation must wrap the serving process itself.
CMD ["sh", "-c", "exec uvicorn main:app --host 0.0.0.0 --port ${PORT} --no-access-log"]
