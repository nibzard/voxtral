"""WebSocket server for Voxtral real-time speech transcription."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import os
import uuid
from dataclasses import dataclass, field
from typing import Any, Literal

import websockets
from websockets.server import WebSocketServerProtocol

from .config import ModelConfig, DEFAULT_CONFIG


def resolve_max_audio_queue_size() -> int:
    raw_value = os.getenv("VOXTRAL_MAX_AUDIO_QUEUE_SIZE")
    if not raw_value:
        return 50
    try:
        value = int(raw_value)
    except ValueError:
        return 50
    return max(1, value)


MAX_AUDIO_QUEUE_SIZE = resolve_max_audio_queue_size()
DEFAULT_HOST = "127.0.0.1"
ALLOWED_HOSTNAMES = {"localhost"}


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("voxtral_backend")
logger.info(f"Voxtral Backend v{__import__('voxtral_backend').__version__} starting")


# Message types
@dataclass
class StartMessage:
    type: Literal["start"] = "start"
    session_id: str = ""
    audio_format: AudioFormat | None = None
    transcription_delay_ms: int = 480
    language: str = "auto"


@dataclass
class StopMessage:
    type: Literal["stop"] = "stop"
    session_id: str = ""


@dataclass
class AudioFormat:
    sample_rate: int = 16000
    channels: int = 1
    encoding: str = "f32le"
    frame_samples: int = 320


@dataclass
class ReadyMessage:
    type: Literal["ready"] = "ready"
    session_id: str = ""
    backend_version: str = "0.1.0"


@dataclass
class StatusMessage:
    type: Literal["status"] = "status"
    state: Literal["initializing", "warming", "running"] = "initializing"
    detail: str = ""


@dataclass
class TranscriptMessage:
    type: Literal["transcript"] = "transcript"
    seq: int = 0
    start_ms: int = 0
    end_ms: int = 0
    text: str = ""
    is_final: bool = False
    confidence: float = 0.0


@dataclass
class ErrorMessage:
    type: Literal["error"] = "error"
    code: str = ""
    message: str = ""
    recoverable: bool = True


@dataclass
class SessionEndMessage:
    type: Literal["session_end"] = "session_end"
    session_id: str = ""
    reason: Literal["client_stop", "backend_error"] = "client_stop"


@dataclass
class TranscriptionSession:
    session_id: str
    config: ModelConfig
    started: bool = False
    sequence: int = 0
    start_time: float = 0.0
    audio_queue: asyncio.Queue[bytes] = field(
        default_factory=lambda: asyncio.Queue(maxsize=MAX_AUDIO_QUEUE_SIZE)
    )
    stop_requested: asyncio.Event = field(default_factory=asyncio.Event)
    input_sample_rate: int = 16000
    input_channels: int = 1
    input_encoding: str = "f32le"
    input_frame_samples: int = 320
    transcription_delay_ms: int = 480
    language: str | None = None

    def get_audio_format(self) -> AudioFormat:
        return AudioFormat(
            sample_rate=self.input_sample_rate,
            channels=self.input_channels,
            encoding=self.input_encoding,
            frame_samples=self.input_frame_samples,
        )


class TranscriptionBackend:
    """Real transcription backend using vLLM Metal + MLX.

    Loads the Voxtral-Mini-4B-Realtime-2602 model and performs streaming
    audio transcription with configurable latency.
    """

    def __init__(self, config: ModelConfig) -> None:
        self.config = config
        self._model_lock = asyncio.Lock()
        self._model_loaded = False
        self._engine = None
        self._mistral_tokenizer = None
        self._mistral_audio_cls = None
        self._mistral_raw_audio_cls = None
        self._mistral_request_cls = None
        self._mistral_streaming_mode = None
        self._audio_processor = None

    async def load_model(self) -> None:
        """Load the Voxtral model with vLLM Metal."""
        async with self._model_lock:
            if self._model_loaded:
                return

            logger.info(f"Loading model: {self.config.model_name}")
            if self.config.model_path:
                logger.info(f"  model_path: {self.config.model_path}")
            logger.info(f"  dtype: {self.config.dtype}")
            logger.info(f"  max_model_len: {self.config.max_model_len}")
            logger.info(f"  temperature: {self.config.temperature}")
            logger.info(f"  transcription_delay_ms: {self.config.transcription_delay_ms}")
            logger.info(f"  use_mlx: {self.config.use_mlx}")
            logger.info(f"  memory_fraction: {self.config.memory_fraction}")

            # Set vLLM Metal environment variables
            os.environ["VLLM_METAL_USE_MLX"] = "true" if self.config.use_mlx else "false"
            os.environ["VLLM_METAL_MEMORY_FRACTION"] = str(self.config.memory_fraction)

            try:
                from vllm import AsyncEngineArgs, AsyncLLMEngine

                model_path = self.config.model_path or self.config.model_name

                logger.info("Initializing vLLM AsyncLLMEngine...")
                engine_args = AsyncEngineArgs(
                    model=model_path,
                    dtype=self.config.dtype,
                    max_model_len=self.config.max_model_len,
                    enforce_eager=True,
                    trust_remote_code=True,
                    gpu_memory_utilization=self.config.memory_fraction,
                )

                self._engine = AsyncLLMEngine.from_engine_args(engine_args)

                # Load Mistral tokenizer for audio transcription encoding
                self._init_mistral_tokenizer(model_path)

                # Initialize audio processor for resampling and feature extraction
                self._init_audio_processor()

                self._model_loaded = True
                logger.info("Model loaded successfully with vLLM Metal")

            except ImportError as e:
                logger.error(
                    f"Failed to import vLLM: {e}. "
                    "Install with: pip install vllm vllm-metal"
                )
                raise RuntimeError(
                    "vLLM Metal is required. Install with: pip install vllm vllm-metal"
                ) from e
            except Exception as e:
                logger.error(f"Failed to load model: {e}", exc_info=True)
                raise

    def _init_audio_processor(self) -> None:
        """Initialize audio processing components."""
        try:
            import numpy as np

            self._np = np
        except ImportError:
            logger.error("numpy is required for audio processing")
            self._np = None
            self._soxr = None
            return

        try:
            import soxr

            self._soxr = soxr
            logger.info("Audio processing initialized (soxr available)")
        except ImportError:
            logger.warning(
                "soxr not available, audio resampling will be limited. "
                "Install with: pip install soxr"
            )
            self._soxr = None

    def _init_mistral_tokenizer(self, model_path: str) -> None:
        """Initialize the Mistral tokenizer for Voxtral audio encoding."""
        try:
            from mistral_common.audio import Audio as MistralAudio
            from mistral_common.protocol.transcription.request import (
                StreamingMode,
                TranscriptionRequest,
            )
            try:
                from mistral_common.protocol.instruct.chunk import RawAudio
            except ImportError:
                from mistral_common.protocol.instruct.messages import RawAudio
            from mistral_common.tokens.tokenizers.mistral import MistralTokenizer

            self._mistral_audio_cls = MistralAudio
            self._mistral_raw_audio_cls = RawAudio
            self._mistral_request_cls = TranscriptionRequest
            self._mistral_streaming_mode = StreamingMode

            if os.path.isdir(model_path):
                tekken_path = os.path.join(model_path, "tekken.json")
                if os.path.exists(tekken_path):
                    self._mistral_tokenizer = MistralTokenizer.from_file(tekken_path)
                else:
                    self._mistral_tokenizer = MistralTokenizer.from_hf_hub(
                        self.config.model_name
                    )
            else:
                self._mistral_tokenizer = MistralTokenizer.from_hf_hub(model_path)

            logger.info("Mistral tokenizer initialized for audio transcription")
        except ImportError as e:
            logger.error(
                f"Failed to import mistral_common: {e}. "
                "Install with: pip install mistral-common[audio]"
            )
            raise RuntimeError(
                "mistral-common is required for Voxtral transcription. "
                "Install with: pip install mistral-common[audio]"
            ) from e

    def _resample_audio(
        self,
        audio_array: "np.ndarray",
        target_sample_rate: int,
        source_sample_rate: int,
    ) -> "np.ndarray":
        """Resample audio to target sample rate."""
        if source_sample_rate == target_sample_rate:
            return audio_array

        if self._soxr is None:
            logger.warning(
                f"Cannot resample from {source_sample_rate} to {target_sample_rate} "
                "without soxr library"
            )
            return audio_array

        # Resample using soxr
        resampled = self._soxr.resample(
            audio_array,
            source_sample_rate,
            target_sample_rate,
            quality="HQ",
        )

        return resampled.astype(self._np.float32)

    def _encode_transcription(
        self,
        audio_array: "np.ndarray",
        language: str | None,
    ):
        """Encode audio into Voxtral transcription tokens + audio payload."""
        if not self._mistral_tokenizer:
            raise RuntimeError("Mistral tokenizer not initialized")

        audio = self._mistral_audio_cls(
            audio_array=audio_array,
            sampling_rate=self.config.sample_rate,
            format="wav",
        )
        raw_audio = self._mistral_raw_audio_cls(
            data=audio.to_base64("wav"),
            format="wav",
        )
        request = self._mistral_request_cls(
            audio=raw_audio,
            streaming=self._mistral_streaming_mode.ONLINE,
            language=language,
        )
        return self._mistral_tokenizer.encode_transcription(request)

    def _extract_audio_payload(self, audios: list[Any]) -> list[tuple["np.ndarray", int]]:
        """Convert mistral_common audio outputs into vLLM audio payloads."""
        payload: list[tuple["np.ndarray", int]] = []
        if not audios:
            return payload

        for item in audios:
            audio_item = item
            if hasattr(audio_item, "audio"):
                audio_item = audio_item.audio

            if isinstance(audio_item, tuple) and len(audio_item) == 2:
                array, sr = audio_item
            elif hasattr(audio_item, "audio_array") and hasattr(audio_item, "sampling_rate"):
                array = audio_item.audio_array
                sr = audio_item.sampling_rate
            elif hasattr(audio_item, "array") and hasattr(audio_item, "sampling_rate"):
                array = audio_item.array
                sr = audio_item.sampling_rate
            elif hasattr(audio_item, "data") and hasattr(audio_item, "sampling_rate"):
                array = audio_item.data
                sr = audio_item.sampling_rate
            elif self._np is not None and isinstance(audio_item, self._np.ndarray):
                array = audio_item
                sr = self.config.sample_rate
            else:
                raise RuntimeError("Unsupported audio payload format from tokenizer")

            array = self._np.asarray(array, dtype=self._np.float32)
            payload.append((array, int(sr)))

        return payload

    async def process_audio(
        self,
        session: TranscriptionSession,
        on_transcript: callable,
    ) -> None:
        """Process audio frames from the queue and generate transcripts."""
        import time

        session.start_time = time.time()
        frame_sample_count = session.input_frame_samples * session.input_channels
        frame_size_bytes = frame_sample_count * 4  # f32le = 4 bytes per sample

        logger.info(f"Processing audio for session {session.session_id}")
        logger.info(f"  transcription_delay: {session.transcription_delay_ms}ms")
        logger.info(
            f"  audio_format: {session.input_sample_rate}Hz, "
            f"{session.input_channels}ch, {session.input_encoding}"
        )

        # Audio buffer for accumulating frames before transcription
        audio_buffer: bytearray = bytearray()
        frames_since_last_transcript = 0
        delay_frames = max(1, session.transcription_delay_ms // 20)  # 20ms per frame
        drain_timeout_s = 1.0

        async def handle_frame(audio_bytes: bytes) -> None:
            nonlocal frames_since_last_transcript
            # Validate frame size
            if len(audio_bytes) != frame_size_bytes:
                logger.warning(
                    f"Invalid frame size: {len(audio_bytes)} bytes "
                    f"(expected {frame_size_bytes})"
                )
                return

            # Accumulate audio
            audio_buffer.extend(audio_bytes)
            frames_since_last_transcript += 1

            # Transcribe when we have enough audio buffered
            if frames_since_last_transcript >= delay_frames:
                await self._transcribe_buffer(
                    session,
                    audio_buffer,
                    on_transcript,
                )
                # Only clear buffer and reset counter after successful transcription
                audio_buffer.clear()
                frames_since_last_transcript = 0

        async def drain_queue() -> None:
            """Drain queued frames after stop is requested, with a timeout."""
            deadline = time.monotonic() + drain_timeout_s
            while time.monotonic() < deadline:
                try:
                    audio_bytes = await asyncio.wait_for(
                        session.audio_queue.get(),
                        timeout=0.1,
                    )
                except asyncio.TimeoutError:
                    if session.audio_queue.empty():
                        break
                    continue

                await handle_frame(audio_bytes)

        try:
            while not session.stop_requested.is_set():
                try:
                    audio_bytes = await asyncio.wait_for(
                        session.audio_queue.get(),
                        timeout=0.1,
                    )
                except asyncio.TimeoutError:
                    # Check if we have buffered audio to transcribe
                    if audio_buffer and frames_since_last_transcript >= delay_frames:
                        await self._transcribe_buffer(
                            session,
                            audio_buffer,
                            on_transcript,
                        )
                        audio_buffer.clear()
                        frames_since_last_transcript = 0
                    continue

                if session.stop_requested.is_set():
                    break

                await handle_frame(audio_bytes)

            # Drain any queued frames after stop before flushing remaining audio
            await drain_queue()

            # Flush any remaining audio on stop
            if audio_buffer:
                await self._transcribe_buffer(session, audio_buffer, on_transcript)
        except Exception as e:
            logger.error(f"Error processing audio: {e}", exc_info=True)
            raise

    async def _transcribe_buffer(
        self,
        session: TranscriptionSession,
        audio_buffer: bytes,
        on_transcript: callable,
    ) -> None:
        """Transcribe accumulated audio buffer and emit transcript message."""
        import time

        if not self._model_loaded or not self._engine:
            logger.warning("Model not loaded, skipping transcription")
            return

        elapsed_ms = int((time.time() - session.start_time) * 1000)
        session.sequence += 1

        try:
            # Convert bytes to float32 waveform
            audio_array = self._np.frombuffer(audio_buffer, dtype=self._np.float32)
            if session.input_channels > 1:
                audio_array = audio_array.reshape(-1, session.input_channels).mean(axis=1)

            # Resample to model sample rate if needed
            audio_array = self._resample_audio(
                audio_array,
                target_sample_rate=self.config.sample_rate,
                source_sample_rate=session.input_sample_rate,
            )
            audio_array = self._np.clip(audio_array, -1.0, 1.0)

            language = None
            if session.language and session.language != "auto":
                language = session.language

            tokenized = self._encode_transcription(audio_array, language)
            audio_payload = self._extract_audio_payload(tokenized.audios)

            llm_inputs = {
                "prompt_token_ids": tokenized.tokens,
                "multi_modal_data": {"audio": audio_payload},
            }

            from vllm import SamplingParams

            sampling_params = SamplingParams(
                temperature=self.config.temperature,
                max_tokens=256,  # Limit output per chunk
            )

            # Generate (this is async in vLLM)
            text = ""
            async for request_output in self._engine.generate(llm_inputs, sampling_params):
                if request_output.outputs:
                    text = request_output.outputs[0].text.strip()

            # Only emit if we got meaningful text
            if text and len(text) > 1:
                await on_transcript(
                    TranscriptMessage(
                        seq=session.sequence,
                        start_ms=elapsed_ms,
                        end_ms=elapsed_ms + session.transcription_delay_ms,
                        text=text,
                        is_final=True,
                        confidence=0.85,  # Placeholder confidence score
                    )
                )

        except Exception as e:
            logger.error(f"Error during transcription: {e}", exc_info=True)

    async def unload_model(self) -> None:
        """Unload the model and release resources."""
        if self._engine:
            # vLLM engine cleanup if needed
            self._engine = None

        self._mistral_tokenizer = None
        self._mistral_audio_cls = None
        self._mistral_raw_audio_cls = None
        self._mistral_request_cls = None
        self._mistral_streaming_mode = None
        self._audio_processor = None
        self._model_loaded = False
        logger.info("Model unloaded")


async def handle_connection(
    websocket: WebSocketServerProtocol,
    backend: TranscriptionBackend,
    config: ModelConfig,
) -> None:
    """Handle a WebSocket connection."""
    client_addr = f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
    logger.info(f"Connection from {client_addr}")

    session: TranscriptionSession | None = None
    processing_task: asyncio.Task | None = None

    async def send_message(msg: dict[str, Any] | dataclass) -> None:
        """Send a JSON message to the client."""
        if hasattr(msg, "asdict"):
            data = msg.asdict()
        elif isinstance(msg, dict):
            data = msg
        else:
            data = msg.__dict__
        await websocket.send(json.dumps(data))

    async def send_transcript(transcript: TranscriptMessage) -> None:
        """Send a transcript message."""
        await send_message(transcript)

    try:
        # Send ready message
        await send_message(
            ReadyMessage(
                session_id="",
                backend_version=__import__('voxtral_backend').__version__,
            )
        )

        # Message loop
        async for raw_message in websocket:
            try:
                # Handle binary audio frames
                if isinstance(raw_message, bytes):
                    if session and session.started:
                        # Apply backpressure if queue is too full
                        try:
                            session.audio_queue.put_nowait(raw_message)
                        except asyncio.QueueFull:
                            logger.warning(
                                "Audio queue full (max=%d), dropping frame",
                                MAX_AUDIO_QUEUE_SIZE,
                            )
                    continue

                # Handle JSON control messages
                message = json.loads(raw_message)
                msg_type = message.get("type")

                if msg_type == "start":
                    session_id = message.get("session_id") or str(uuid.uuid4())
                    audio_format = message.get("audio_format") or {}
                    input_sample_rate = int(
                        audio_format.get("sample_rate", config.sample_rate)
                    )
                    input_channels = int(
                        audio_format.get("channels", config.channels)
                    )
                    input_encoding = audio_format.get("encoding", config.encoding)
                    input_frame_samples = int(
                        audio_format.get("frame_samples", config.frame_samples)
                    )
                    transcription_delay_ms = int(
                        message.get(
                            "transcription_delay_ms",
                            config.transcription_delay_ms,
                        )
                    )
                    language = message.get("language", "auto")

                    if input_encoding != "f32le":
                        logger.error(
                            f"Unsupported audio encoding: {input_encoding}"
                        )
                        await send_message(
                            ErrorMessage(
                                code="unsupported_audio_format",
                                message="Only f32le audio encoding is supported",
                                recoverable=True,
                            )
                        )
                        continue

                    session = TranscriptionSession(
                        session_id=session_id,
                        config=config,
                        input_sample_rate=input_sample_rate,
                        input_channels=input_channels,
                        input_encoding=input_encoding,
                        input_frame_samples=input_frame_samples,
                        transcription_delay_ms=transcription_delay_ms,
                        language=language,
                    )

                    logger.info(f"Starting session {session_id}")

                    # Ensure model is loaded
                    if not backend._model_loaded:
                        await send_message(
                            StatusMessage(state="initializing", detail="Loading model")
                        )
                        await backend.load_model()
                        await send_message(
                            StatusMessage(state="warming", detail="Model ready")
                        )

                    session.started = True
                    await send_message(
                        ReadyMessage(
                            session_id=session_id,
                            backend_version=__import__('voxtral_backend').__version__,
                        )
                    )

                    # Start audio processing task
                    processing_task = asyncio.create_task(
                        backend.process_audio(session, send_transcript)
                    )

                    await send_message(StatusMessage(state="running"))

                elif msg_type == "stop":
                    if session:
                        logger.info(f"Stopping session {session.session_id}")
                        session.stop_requested.set()

                        # Wait for processing task to finish flushing audio buffer
                        if processing_task:
                            try:
                                await asyncio.wait_for(processing_task, timeout=2.0)
                            except asyncio.TimeoutError:
                                logger.warning(
                                    f"Processing task timeout for session {session.session_id}, "
                                    "cancelling"
                                )
                                processing_task.cancel()
                                try:
                                    await processing_task
                                except asyncio.CancelledError:
                                    pass
                            except asyncio.CancelledError:
                                pass

                        await send_message(
                            SessionEndMessage(
                                session_id=session.session_id,
                                reason="client_stop",
                            )
                        )

                        session = None
                        processing_task = None

                else:
                    logger.warning(f"Unknown message type: {msg_type}")

            except json.JSONDecodeError:
                logger.error("Invalid JSON message")
                await send_message(
                    ErrorMessage(
                        code="invalid_json",
                        message="Could not parse JSON message",
                        recoverable=True,
                    )
                )
            except Exception as e:
                logger.error(f"Error handling message: {e}", exc_info=True)
                await send_message(
                    ErrorMessage(
                        code="backend_error",
                        message=str(e),
                        recoverable=True,
                    )
                )

    except websockets.exceptions.ConnectionClosed:
        logger.info(f"Connection closed by {client_addr}")
    except Exception as e:
        logger.error(f"Connection error: {e}", exc_info=True)
    finally:
        if processing_task:
            if processing_task.done():
                try:
                    processing_task.result()
                except Exception as e:
                    logger.warning(
                        f"Processing task ended with error during cleanup: {e}",
                        exc_info=True,
                    )
            else:
                processing_task.cancel()
                try:
                    await processing_task
                except asyncio.CancelledError:
                    pass
                except Exception as e:
                    logger.warning(
                        f"Processing task raised during cancellation: {e}",
                        exc_info=True,
                    )

        logger.info(f"Connection handler ended for {client_addr}")


def load_config_from_env() -> ModelConfig:
    """Load configuration from environment variables."""
    return ModelConfig.from_env()


def resolve_ws_host() -> str:
    """Resolve a safe WebSocket bind host from environment variables."""
    raw_host = os.getenv("VOXTRAL_HOST", DEFAULT_HOST)
    host = raw_host.strip() if raw_host is not None else ""
    if not host:
        return DEFAULT_HOST

    if host.lower() in ALLOWED_HOSTNAMES:
        return host

    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        logger.warning(
            "Invalid VOXTRAL_HOST value '%s'; falling back to %s", host, DEFAULT_HOST
        )
        return DEFAULT_HOST

    if not ip.is_loopback:
        logger.warning(
            "Non-loopback VOXTRAL_HOST value '%s' is not allowed; falling back to %s",
            host,
            DEFAULT_HOST,
        )
        return DEFAULT_HOST

    return host


async def main_async() -> None:
    """Main async entry point."""
    config = load_config_from_env()
    backend = TranscriptionBackend(config)

    port = int(os.getenv("VOXTRAL_PORT", "8765"))
    host = resolve_ws_host()

    logger.info(f"Starting WebSocket server on ws://{host}:{port}")
    logger.info(f"Audio: {config.sample_rate} Hz, {config.channels} channel(s), {config.encoding}")
    logger.info(f"Frame size: {config.frame_samples} samples ({config.frame_samples * 1000 / config.sample_rate:.1f} ms)")

    async def handler(websocket: WebSocketServerProtocol) -> None:
        await handle_connection(websocket, backend, config)

    async with websockets.serve(handler, host, port):
        logger.info("Server ready")
        await asyncio.Future()  # Run forever


def main() -> None:
    """CLI entry point."""
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        logger.info("Server stopped by user")
    except Exception as e:
        logger.error(f"Server error: {e}", exc_info=True)
        raise


if __name__ == "__main__":
    main()
