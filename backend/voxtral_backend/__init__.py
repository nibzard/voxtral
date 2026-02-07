# ABOUTME: Package entry for voxtral_backend and public defaults.
# ABOUTME: Exposes config exports and package version.
"""Voxtral backend for local speech transcription."""

from .config import ModelConfig, DEFAULT_CONFIG

__all__ = ["ModelConfig", "DEFAULT_CONFIG"]
__version__ = "0.1.0"
