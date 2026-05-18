# faster-whisper on Alpine Linux

Docker image running [faster-whisper](https://github.com/SYSTRAN/faster-whisper) on Alpine Linux (musl libc).

All existing faster-whisper Docker images use Debian. This is the first Alpine-based image, solving five compatibility issues that block installation on musl systems.

## Problems solved

### 1. ctranslate2 — no musl wheels on PyPI
ctranslate2 (faster-whisper's inference engine) only publishes manylinux (glibc) wheels. These cannot run on Alpine/musl. This image builds ctranslate2 from source.

### 2. musl `stat64` / `fstat64` missing
spdlog (a ctranslate2 submodule) calls `stat64`/`fstat64`, which are glibc-only. musl provides only `stat`/`fstat` (already 64-bit on 64-bit platforms). Fixed at compile time:
```
-Dfstat64=fstat -Dstat64=stat
```

### 3. PyAV incompatible with FFmpeg 8.x
Alpine 3.23 ships FFmpeg 8.x, which removed `AVFMT_ALLOW_FLUSH`. PyAV ≤12 uses that constant and fails to compile. `av>=13` is required.

### 4. CMake 4.x policy rejection
CMake 4.0 dropped compatibility with `cmake_minimum_required` versions below 3.5. Some CTranslate2 submodules declare older minimums, causing configure to fail. Fixed with `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.

### 5. CTranslate2 CLI — cxxopts missing `<cstdint>`
The CLI tool's `cxxopts` submodule omits `#include <cstdint>`, causing `uint8_t` errors with GCC 14. Since only the library is needed (not the CLI), this is avoided with `-DBUILD_CLI=OFF`.

### Bonus: ARM64 int8 support
Without `-march=armv8-a+dotprod`, ctranslate2 rejects `int8` compute type at runtime even on CPUs that support it (Snapdragon 855+, Cortex-A76+, etc.). The Dockerfile detects ARM64 at build time and enables it automatically.

## Usage

```bash
docker pull ghcr.io/caseyng/faster-whisper-alpine:latest
```

```bash
docker run --rm \
  -v /path/to/audio:/app \
  ghcr.io/caseyng/faster-whisper-alpine:latest \
  python3 -c "
from faster_whisper import WhisperModel
model = WhisperModel('tiny', device='cpu', compute_type='int8')
segments, info = model.transcribe('/app/audio.wav')
for seg in segments:
    print(f'[{seg.start:.1f}s -> {seg.end:.1f}s] {seg.text}')
"
```

## Build locally

```bash
docker build -t faster-whisper-alpine .
```

Multi-platform (requires buildx):
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t faster-whisper-alpine .
```

## Models

| Model  | Size   | Notes                        |
|--------|--------|------------------------------|
| tiny   | ~75 MB | Fastest                      |
| base   | ~145 MB| Good for short clips         |
| small  | ~465 MB| Recommended balance          |
| medium | ~1.5 GB| High accuracy                |
| large  | ~3 GB  | Best accuracy                |

Models are downloaded automatically from HuggingFace on first use.

## Why Alpine?

- Smaller image footprint than Debian-based images
- Useful for constrained environments (edge devices, ARM SBCs)
- Proves musl compatibility for the faster-whisper stack

## Tested on

- Alpine 3.23, Python 3.12, aarch64 (ARM64) running in Termux proot-distro on Android
