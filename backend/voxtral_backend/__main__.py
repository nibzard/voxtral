# ABOUTME: Module entry point for running the backend with python -m.
# ABOUTME: Delegates to server.main for CLI execution.
"""Main entry point for `python -m voxtral_backend.server`."""

from .server import main

if __name__ == "__main__":
    main()
