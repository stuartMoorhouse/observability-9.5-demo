# demo-control-panel (Python stdlib only, no third-party packages). Not instrumented:
# it is presenter tooling and should not appear in APM.
FROM python:3.12.15-slim-bookworm
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8080
WORKDIR /app
COPY main.py ./
COPY static/ ./static/
USER 10001
EXPOSE 8080
CMD ["python", "main.py"]
