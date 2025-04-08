# syntax=docker/dockerfile:1
######## 前端构建阶段（基于阿里云Node镜像）########
FROM --platform=$BUILDPLATFORM crpi-vd2np7sloa8wv5h3.cn-qingdao.personal.cr.aliyuncs.com/rhzz/node:22-alpine3.20 AS frontend-builder
ARG BUILD_HASH

WORKDIR /app
COPY ["package.json", "package-lock.json", "./"]
RUN npm ci --omit=dev

COPY [".", "./"]
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## 后端构建阶段（基于阿里云Python镜像）########
FROM crpi-vd2np7sloa8wv5h3.cn-qingdao.personal.cr.aliyuncs.com/rhzz/python:3.11-slim-bookworm AS backend-base

# 声明构建参数（通过阿里云构建服务传递）
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_CUDA_VER=cu121
ARG USE_EMBEDDING_MODEL="sentence-transformers/all-MiniLM-L6-v2"
ARG USE_RERANKING_MODEL=""
ARG UID=0
ARG GID=0
ARG BUILD_HASH

# 环境变量配置（继承构建参数）
ENV ENV=prod \
    PORT=8080 \
    USE_CUDA_DOCKER=$USE_CUDA \
    USE_OLLAMA_DOCKER=$USE_OLLAMA \
    USE_CUDA_DOCKER_VER=$USE_CUDA_VER \
    RAG_EMBEDDING_MODEL=$USE_EMBEDDING_MODEL \
    RAG_RERANKING_MODEL=$USE_RERANKING_MODEL \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    WEBUI_BUILD_VERSION=$BUILD_HASH \
    DOCKER=true

WORKDIR /app/backend

# 用户权限配置（兼容阿里云容器服务权限策略）
RUN if [ $UID -ne 0 ]; then \
    groupadd -g $GID app && \
    useradd -u $UID -g $GID -d /home/app -s /bin/bash app && \
    mkdir -p /home/app && \
    chown -R $UID:$GID /home/app; \
    fi

# 系统依赖安装（适配阿里云apt源）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git build-essential pandoc netcat-openbsd curl jq \
    ffmpeg libsm6 libxext6 && \
    if [ "$USE_OLLAMA" = "true" ]; then \
    curl -fsSL https://ollama.com/install.sh | sh; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Python依赖安装（支持阿里云PyPI镜像）
COPY ["./backend/requirements.txt", "./requirements.txt"]
RUN pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ uv && \
    if [ "$USE_CUDA" = "true" ]; then \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_VER; \
    else \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu; \
    fi && \
    uv pip install --system -r requirements.txt --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/

# 前端构建产物复制（符合阿里云镜像分层规范）
COPY --chown=$UID:$GID --from=frontend-builder ["/app/build", "/app/build/"]
COPY --chown=$UID:$GID --from=frontend-builder ["/app/CHANGELOG.md", "/app/package.json", "/app/"]

# 后端代码复制（遵循阿里云镜像仓库目录结构）
COPY ["./backend", "/app/backend/"]

# 权限修正（适配阿里云容器运行时）
RUN chown -R $UID:$GID /app/backend/data/

EXPOSE 8080
USER $UID:$GID
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT}/health || exit 1

CMD ["bash", "start.sh"]
