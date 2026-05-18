# faster-whisper on Alpine Linux (musl libc)
#
# Problem: ctranslate2 (faster-whisper's inference engine) has no musl/Alpine
# wheels on PyPI — only manylinux (glibc) wheels. This Dockerfile builds it
# from source with two fixes discovered during testing on Alpine 3.23 aarch64:
#
#   Fix 1 — musl stat64 compatibility:
#     musl does not expose stat64/fstat64 as separate symbols (they are the
#     same as stat/fstat on 64-bit). spdlog (a ctranslate2 submodule) uses
#     them unconditionally, so we remap at compile time:
#     -Dfstat64=fstat -Dstat64=stat
#
#   Fix 2 — ARM64 int8 support:
#     int8 quantization on ARM64 requires the dotprod extension (asimddp).
#     Without -march=armv8-a+dotprod, ctranslate2 rejects int8 compute type
#     at runtime even when the CPU supports it.
#
#   Fix 3 — PyAV version:
#     Alpine 3.23 ships FFmpeg 8.x, which removed AVFMT_ALLOW_FLUSH.
#     PyAV <=12 uses that constant, so av>=13 is required.
#
#   Fix 4 — CMake 4.x policy:
#     CMake 4.0 removed backward compatibility with cmake_minimum_required
#     versions below 3.5. Some CTranslate2 submodules declare older minimums.
#     -DCMAKE_POLICY_VERSION_MINIMUM=3.5 suppresses the error.
#
#   Fix 5 — cxxopts missing <cstdint>:
#     The CTranslate2 CLI tool's cxxopts submodule omits #include <cstdint>,
#     causing uint8_t errors with GCC 14. We don't need the CLI (only the
#     library), so -DBUILD_CLI=OFF skips it entirely.

FROM alpine:3.23

# ── Runtime dependencies ───────────────────────────────────────────────────────
RUN apk add --no-cache \
    python3 \
    py3-pip \
    openblas \
    ffmpeg

# ── Build dependencies (removed after build) ───────────────────────────────────
RUN apk add --no-cache --virtual .build-deps \
    cmake make g++ \
    python3-dev \
    openblas-dev \
    ffmpeg-dev \
    pkgconf \
    git

# ── Python virtual environment ─────────────────────────────────────────────────
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# ── CTranslate2: clone and configure ──────────────────────────────────────────
RUN git clone --depth 1 --recursive --shallow-submodules \
    https://github.com/OpenNMT/CTranslate2.git /tmp/ct2

RUN EXTRA_CXX="" && \
    [ "$(uname -m)" = "aarch64" ] && EXTRA_CXX="-march=armv8-a+dotprod" || true && \
    cmake -B /tmp/ct2/build -S /tmp/ct2 \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_MKL=OFF \
        -DWITH_OPENBLAS=ON \
        -DOPENMP_RUNTIME=NONE \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_CLI=OFF \
        "-DCMAKE_CXX_FLAGS=-Dfstat64=fstat -Dstat64=stat $EXTRA_CXX"

# ── CTranslate2: build and install C++ library ─────────────────────────────────
RUN cmake --build /tmp/ct2/build -j$(nproc) && \
    cmake --install /tmp/ct2/build

# ── CTranslate2: Python bindings ───────────────────────────────────────────────
RUN pip install pybind11 && \
    cd /tmp/ct2/python && pip install .

# ── PyAV: build from source against Alpine's FFmpeg 8.x ───────────────────────
RUN pip install "av>=13"

# ── Remove build tools and source (keeps image lean) ──────────────────────────
RUN apk del .build-deps && \
    rm -rf /tmp/ct2 /var/cache/apk/*

# ── faster-whisper ─────────────────────────────────────────────────────────────
# --no-deps: ctranslate2 and av are already installed above;
# bypasses the version-pinned dep resolver that would try to reinstall them.
RUN pip install faster-whisper --no-deps && \
    pip install huggingface_hub tqdm tokenizers setuptools

# /usr/local/lib is not in musl's default search path
ENV LD_LIBRARY_PATH=/usr/local/lib

WORKDIR /app

CMD ["python3"]
