ARG UBUNTU_VERSION=24.04
# This needs to generally match the container host's environment.
ARG CUDA_VERSION=12.8.1
ARG GCC_VERSION=14
# Target the CUDA build image
ARG BASE_CUDA_DEV_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}

ARG BASE_CUDA_RUN_CONTAINER=docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

ARG NODE_VERSION=24

FROM docker.io/node:$NODE_VERSION AS web

ARG APP_VERSION

WORKDIR /app/tools/ui

COPY tools/ui/package.json tools/ui/package-lock.json ./
RUN npm ci

COPY tools/ui/ ./
RUN LLAMA_BUILD_NUMBER="$APP_VERSION" npm run build

FROM ${BASE_CUDA_DEV_CONTAINER} AS build

ARG CUDA_VERSION
ARG GCC_VERSION
# CUDA architecture policy. `non-blackwell` is the portable default for the
# published images and excludes Blackwell SM 100/103/120/121 targets.
# Override with an explicit semicolon-separated CMake list when needed.
ARG CUDA_DOCKER_ARCH=non-blackwell
# Build all CPU backend variants by default for published images. CI can turn
# this off to avoid compiling every x86 dispatch variant during a smoke build.
ARG GGML_CPU_ALL_VARIANTS=ON

RUN apt-get update && \
    apt-get install -y gcc-${GCC_VERSION} g++-${GCC_VERSION} build-essential cmake python3 python3-pip git libssl-dev libgomp1

ENV CC=gcc-${GCC_VERSION} CXX=g++-${GCC_VERSION} CUDAHOSTCXX=g++-${GCC_VERSION}

WORKDIR /app

COPY . .

COPY --from=web /app/tools/ui/dist tools/ui/dist

RUN export CMAKE_ARGS="" && \
    if [ "${CUDA_DOCKER_ARCH}" = "non-blackwell" ]; then \
      case "${CUDA_VERSION%%.*}" in \
        12) export CUDA_ARCH_LIST="50-real;52-real;53-real;60-real;61-real;62-real;70-real;72-real;75-real;80-real;86-real;87-real;89-real;90-real" ;; \
        13) export CUDA_ARCH_LIST="75-real;80-real;86-real;87-real;89-real;90-real" ;; \
        *) echo "Unsupported CUDA major for non-blackwell architecture policy: ${CUDA_VERSION}" >&2; exit 2 ;; \
      esac; \
      export CMAKE_ARGS="-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH_LIST}"; \
    elif [ "${CUDA_DOCKER_ARCH}" != "default" ] && [ -n "${CUDA_DOCKER_ARCH}" ]; then \
      export CMAKE_ARGS="-DCMAKE_CUDA_ARCHITECTURES=${CUDA_DOCKER_ARCH}"; \
    fi && \
    cmake -B build -DGGML_NATIVE=OFF -DGGML_CUDA=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=${GGML_CPU_ALL_VARIANTS} -DLLAMA_BUILD_TESTS=OFF ${CMAKE_ARGS} -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined . && \
    cmake --build build --config Release -j$(nproc)

RUN mkdir -p /app/lib && \
    find build -name "*.so*" -exec cp -P {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r conversion /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

## Base image
FROM ${BASE_CUDA_RUN_CONTAINER} AS base

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
ARG IMAGE_URL=https://github.com/ggml-org/llama.cpp
ARG IMAGE_SOURCE=https://github.com/ggml-org/llama.cpp
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp" \
      org.opencontainers.image.description="LLM inference in C/C++" \
      org.opencontainers.image.url=$IMAGE_URL \
      org.opencontainers.image.source=$IMAGE_SOURCE

RUN apt-get update \
    && apt-get install -y libgomp1 curl ffmpeg \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app

### Full
FROM base AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-wheel \
    && pip install --break-system-packages --upgrade setuptools \
    && pip install --break-system-packages -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete


ENTRYPOINT ["/app/tools.sh"]

### Light, CLI only
FROM base AS light

COPY --from=build /app/full/llama /app/full/llama-cli /app/full/llama-completion /app/

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

### Server, Server only
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080

COPY --from=build /app/full/llama /app/full/llama-server /app/

WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
