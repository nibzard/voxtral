# Research Summary

## vLLM Metal (vllm-project/vllm-metal)

### What it is
vLLM Metal is a community-maintained plugin that enables vLLM to run on Apple Silicon Macs using MLX as the primary compute backend, with PyTorch used for model loading and interoperability. The README positions it as a high-performance inference option for Apple Silicon. [1]

### Key capabilities (from the README)
- MLX-accelerated inference (claimed faster than PyTorch MPS on Apple Silicon). [1]
- Unified memory / zero-copy operations leveraging Apple Silicon's unified memory architecture. [1]
- Compatibility with vLLM engine, scheduler, and OpenAI-compatible API; supports paged attention and GQA. [1]

### Requirements and install
- macOS on Apple Silicon. [1]
- Install via the repo's install script. [1]

### Architecture (README summary)
- vLLM core -> vllm_metal plugin layer (platform/worker/model runner) -> unified backend with MLX (primary) and PyTorch (loading/interoperability) -> Metal GPU layer. [1]

### Configuration (environment variables)
- VLLM_METAL_MEMORY_FRACTION, VLLM_METAL_USE_MLX, VLLM_MLX_DEVICE, VLLM_METAL_BLOCK_SIZE, VLLM_METAL_DEBUG, VLLM_USE_MODELSCOPE, VLLM_METAL_MODELSCOPE_CACHE. [1]

### Context from vLLM docs
- vLLM notes macOS/Apple Silicon CPU support is experimental and requires building from source. For GPU-accelerated inference on Apple Silicon, vLLM points users to vllm-metal (community plugin using MLX). [2]

## Voxtral Mini 4B Realtime 2602 (mistralai)

### What it is
Voxtral Mini 4B Realtime 2602 is a multilingual, real-time speech transcription model. The model card describes it as open source, with <500ms delay and support for 13 languages, aimed at real-time use cases like voice assistants and live subtitling. It is released in BF16 under Apache-2.0. [3]

### Architecture and streaming
- Two main components: approx. 3.4B language model + approx. 0.6B audio encoder. [3]
- The audio encoder uses causal attention; both the encoder and LM use sliding-window attention to enable streaming. [3]
- The model card describes configurable transcription delays (240ms to 2.4s). [3]

### Recommended settings (model card)
- Temperature 0.0. [3]
- Set --max-model-len based on expected recording duration (example: 1h requires >= 45000). Default max length 131072 tokens (~3h) recommended for user experience. [3]
- Use websockets for streaming. [3]
- 480ms is recommended as a performance/latency sweet spot; configurable via transcription_delay_ms in tekken.json. [3]

### Benchmarks and latency claims
- The model card includes FLEURS and English benchmarks and describes performance as competitive with leading offline models. [3]
- Mistral's Voxtral Transcribe 2 announcement says Voxtral Realtime uses a streaming architecture with latency configurable down to sub-200ms; at 480ms it stays within 1-2% WER of the batch model. The announcement also states 13-language coverage and a 4B-parameter footprint. [4]
- Treat performance statements as vendor-reported; validate in your target environment. [3][4]

### Usage and serving notes (model card)
- The model is currently supported in vLLM; the model card invites community contributions to add the architecture to Transformers and llama.cpp. [3]
- The model card recommends installing vLLM from nightly and installing audio dependencies (soxr, librosa, soundfile). [3]
- Serving note: BF16 weights require a single GPU with >= 16GB memory. [3]

## Sources
1. https://github.com/vllm-project/vllm-metal (README)
2. https://docs.vllm.ai/en/v0.14.0/getting_started/installation/cpu/ (Apple Silicon notes and vllm-metal reference)
3. https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602 (Model card)
4. https://mistral.ai/news/voxtral-transcribe-2 (Announcement)
