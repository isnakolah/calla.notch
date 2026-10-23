FROM python:3.14-slim
WORKDIR /site
COPY api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --create-home calla \
    && mkdir /data && chown calla:calla /data
COPY api ./api
USER calla
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "1", "--threads", "4", "--timeout", "20", "--no-control-socket", "api.app:create_app()"]
