# Voxtral Backend

Local speech transcription backend with selectable engines:

- `voxtral`: Voxtral-Mini-4B-Realtime-2602 via vLLM Metal (large + fast on Apple Silicon, but requires lots of RAM + disk).
- `whisper`: faster-whisper (CTranslate2) models (smaller + CPU/Metal-friendly; recommended default on Apple Silicon).

## Configuration

The backend loads with opinionated defaults for Voxtral-Mini-4B-Realtime-2602:

| Setting | Value | Description |
|---------|-------|-------------|
| Model | `mistralai/Voxtral-Mini-4B-Realtime-2602` | Model identifier |
| Precision | BF16 | Brain float 16 for optimal performance |
| Temperature | 0.0 | Deterministic transcription |
| Transcription Delay | 480 ms | Latency/accuracy sweet spot |
| Max Model Length | 131072 tokens | ~3 hours of audio |
| Sample Rate | 16000 Hz | 16 kHz mono |
| Frame Size | 320 samples | 20 ms frames |

## Local Model Files

The bundled model directory is expected to include:

- `consolidated.safetensors`
- `params.json`
- `tekken.json`

The backend uses `mistral-common` with `tekken.json` for tokenization and does
not require Hugging Face tokenizer/config files when running from a local path.

## Environment Variables

Override defaults via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VOXTRAL_BACKEND` | `voxtral` | Backend engine: `voxtral` (vLLM Metal) or `whisper` (faster-whisper) |
| `VOXTRAL_MODEL_NAME` | `mistralai/Voxtral-Mini-4B-Realtime-2602` | Model to load |
| `VOXTRAL_MODEL_PATH` | (unset) | Local model directory (overrides `VOXTRAL_MODEL_NAME`) |
| `VOXTRAL_DTYPE` | `bfloat16` | Data type (auto, float16, bfloat16, float32). Legacy: bf16, f16, f32. |
| `VOXTRAL_MAX_MODEL_LEN` | `131072` | Max tokens (~3h at 480ms delay) |
| `VOXTRAL_TEMPERATURE` | `0.0` | Sampling temperature |
| `VOXTRAL_TRANSCRIPTION_DELAY_MS` | `480` | Transcription delay in ms |
| `VOXTRAL_USE_MLX` | `true` | Use MLX backend |
| `VOXTRAL_MEMORY_FRACTION` | `0.9` | GPU memory fraction |
| `VOXTRAL_PORT` | `8765` | WebSocket server port |
| `VOXTRAL_DEVICE` | `auto` | Device for faster-whisper: `auto`, `cpu`, `metal` |
| `VOXTRAL_WHISPER_COMPUTE_TYPE` | (auto) | faster-whisper compute type (e.g. `int8`, `float16`) |
| `HF_HOME` | (unset) | Hugging Face cache root (app sets this to Application Support) |

## Running

```bash
python -m voxtral_backend.server
```

The server listens on `ws://127.0.0.1:8765/v1/transcribe` by default.
