# ABOUTME: Configuration model and defaults for Voxtral backend runtime.
# ABOUTME: Loads env overrides and normalizes dtype values.
"""Backend configuration for Voxtral transcription model."""

from dataclasses import dataclass, field
from typing import Literal
import os


@dataclass(frozen=True)
class ModelConfig:
    """Configuration for Voxtral-Mini-4B-Realtime-2602 model."""

    # Model identifier or local path
    model_name: str = "mistralai/Voxtral-Mini-4B-Realtime-2602"
    model_path: str | None = None

    # Model loading settings
    dtype: Literal["bf16", "f16", "f32"] = "bf16"
    max_model_len: int = 131072  # ~3 hours at default settings

    # Inference settings
    temperature: float = 0.0
    transcription_delay_ms: int = 480

    # Audio settings
    sample_rate: int = 16000
    channels: int = 1
    encoding: str = "f32le"
    frame_samples: int = 320  # 20ms at 16kHz

    # vLLM Metal specific
    use_mlx: bool = True
    memory_fraction: float = 0.9

    @classmethod
    def from_env(cls) -> "ModelConfig":
        """Create config from environment variables with defaults."""
        model_path = os.getenv("VOXTRAL_MODEL_PATH")
        model_name = os.getenv("VOXTRAL_MODEL_NAME", cls.model_name)
        if model_path:
            model_name = model_path
        return cls(
            model_name=model_name,
            model_path=model_path,
            dtype=os.getenv("VOXTRAL_DTYPE", cls.dtype),
            max_model_len=int(os.getenv("VOXTRAL_MAX_MODEL_LEN", str(cls.max_model_len))),
            temperature=float(os.getenv("VOXTRAL_TEMPERATURE", str(cls.temperature))),
            transcription_delay_ms=int(os.getenv("VOXTRAL_TRANSCRIPTION_DELAY_MS", str(cls.transcription_delay_ms))),
            use_mlx=os.getenv("VOXTRAL_USE_MLX", "true").lower() == "true",
            memory_fraction=float(os.getenv("VOXTRAL_MEMORY_FRACTION", str(cls.memory_fraction))),
        )


# Default singleton instance
DEFAULT_CONFIG = ModelConfig()
