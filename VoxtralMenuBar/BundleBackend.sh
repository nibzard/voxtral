#!/bin/sh
# BundleBackend.sh - Build and bundle the Python backend for the macOS app
# This script creates a self-contained Python environment using python-build-standalone.

set -e

BACKEND_DIR="${SRCROOT}/backend"
BACKEND_DST="${BUILT_PRODUCTS_DIR}/backend"
BACKEND_BIN="${BACKEND_DST}/voxtral-backend"
PYTHON_RUNTIME="${BACKEND_DST}/python-runtime"
DOWNLOAD_CACHE="${SRCROOT}/.python-standalone-cache"
BUNDLE_ID_FILE="${BACKEND_DST}/backend-bundle-id.txt"

# Python version to use (must match python-build-standalone naming).
# vllm-metal currently ships cp312 wheels, so keep the bundled runtime on 3.12.x.
PYTHON_VERSION="3.12.12"
PYTHON_RELEASE="20260203"
PYTHON_STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"

# Create destination directory
mkdir -p "${BACKEND_DST}"
mkdir -p "${DOWNLOAD_CACHE}"

# Clean up any legacy bundle artifacts from earlier experiments.
rm -rf "${BACKEND_DST}/python-runtime-canary"

# Debug builds should stay lightweight. Bundling the full Python runtime + ML stack
# is huge (torch + vLLM + friends) and can easily exceed disk limits on dev
# machines/CI runners. Opt in via VOXTRAL_BUNDLE_BACKEND=1.
if [ "${CONFIGURATION}" = "Debug" ] && [ "${VOXTRAL_BUNDLE_BACKEND:-0}" != "1" ]; then
    echo "Skipping full backend bundling for Debug build. Set VOXTRAL_BUNDLE_BACKEND=1 to force."

    PYTHON_BIN_PATH=""
    if command -v python3.12 >/dev/null 2>&1; then
        PYTHON_BIN_PATH="$(command -v python3.12)"
    elif command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN_PATH="$(command -v python3)"
    fi

    # Provide a minimal runtime shim so the app can still find
    # backend/python-runtime/bin/python3 in the bundle.
    rm -rf "${PYTHON_RUNTIME}"
    mkdir -p "${PYTHON_RUNTIME}/bin"
    if [ -z "${PYTHON_BIN_PATH}" ]; then
        cat > "${PYTHON_RUNTIME}/bin/python3" << 'EOF'
#!/bin/sh
echo "Voxtral backend debug shim: python3 not found. Install Python 3.12 or build with VOXTRAL_BUNDLE_BACKEND=1." >&2
exit 127
EOF
    else
        cat > "${PYTHON_RUNTIME}/bin/python3" << EOF
#!/bin/sh
set -e

PYTHON_BIN="${PYTHON_BIN_PATH}"
if [ ! -x "\${PYTHON_BIN}" ]; then
    echo "Voxtral backend debug shim: \${PYTHON_BIN} is not executable. Install Python 3.12 or build with VOXTRAL_BUNDLE_BACKEND=1." >&2
    exit 127
fi

exec "\${PYTHON_BIN}" "\$@"
EOF
    fi
    chmod +x "${PYTHON_RUNTIME}/bin/python3"

    # Include backend sources so -m voxtral_backend.server works without an editable install.
    rm -rf "${BACKEND_DST}/voxtral_backend"
    if [ -d "${BACKEND_DIR}/voxtral_backend" ]; then
        cp -R "${BACKEND_DIR}/voxtral_backend" "${BACKEND_DST}/"
    fi

    # Launcher script that uses the runtime shim.
    cat > "${BACKEND_BIN}" << 'EOFSCRIPT'
#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_RUNTIME="${SCRIPT_DIR}/python-runtime"

export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
exec "${PYTHON_RUNTIME}/bin/python3" -m voxtral_backend.server "$@"
EOFSCRIPT

    chmod +x "${BACKEND_BIN}"
    echo "Backend debug shim created at: ${BACKEND_BIN}"

    # Helps the app detect when the installed backend differs from the bundled backend.
    echo "debug-shim python=${PYTHON_BIN_PATH:-missing}" > "${BUNDLE_ID_FILE}"
    exit 0
fi

# Function to download and extract Python standalone runtime
setup_python_runtime() {
    echo "Setting up Python standalone runtime at ${PYTHON_RUNTIME}..."

    ARCHIVE_NAME=$(basename "${PYTHON_STANDALONE_URL}")
    CACHED_ARCHIVE="${DOWNLOAD_CACHE}/${ARCHIVE_NAME}"

    # Download if not cached
    if [ ! -f "${CACHED_ARCHIVE}" ]; then
        echo "Downloading Python standalone runtime from ${PYTHON_STANDALONE_URL}..."
        curl -L -o "${CACHED_ARCHIVE}" "${PYTHON_STANDALONE_URL}"
    fi

    # Extract to runtime directory
    echo "Extracting Python runtime to ${PYTHON_RUNTIME}..."
    rm -rf "${PYTHON_RUNTIME}"
    mkdir -p "${PYTHON_RUNTIME}"
    tar -xzf "${CACHED_ARCHIVE}" -C "${PYTHON_RUNTIME}" --strip-components=1

    # Verify extraction
    if [ ! -f "${PYTHON_RUNTIME}/bin/python3" ]; then
        echo "Error: Failed to extract Python runtime"
        exit 1
    fi

    echo "Python runtime installed at: ${PYTHON_RUNTIME}"
}

# Build backend using pip install
if [ -d "${BACKEND_DIR}" ]; then
    echo "Building voxtral-backend..."

    # Setup Python runtime first.
    setup_python_runtime

    # Install backend dependencies into the runtime.
    # Note: `voxtral` (vLLM Metal) is heavy; `whisper` (faster-whisper) is the default engine in the app.
    echo "Installing backend dependencies..."
    "${PYTHON_RUNTIME}/bin/pip" install --upgrade pip
    "${PYTHON_RUNTIME}/bin/pip" install --no-cache-dir "${BACKEND_DIR}[voxtral,whisper]"

    # Create the launcher script that uses the bundled runtime.
    cat > "${BACKEND_BIN}" << EOFSCRIPT
#!/bin/sh
# Voxtral Backend Launcher
# This script runs the backend with the bundled Python runtime.

set -e

# Get the directory where this script is located
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
PYTHON_RUNTIME="\${SCRIPT_DIR}/python-runtime"

# Run the backend server using the bundled Python
exec "\${PYTHON_RUNTIME}/bin/python3" -m voxtral_backend.server "\$@"
EOFSCRIPT

    chmod +x "${BACKEND_BIN}"
    echo "Backend built at: ${BACKEND_BIN}"
    echo "  - Voxtral runtime: ${PYTHON_RUNTIME}"
    echo "  - Bundled Python version (voxtral): $("${PYTHON_RUNTIME}/bin/python3" --version)"

    # Helps the app detect when the installed backend differs from the bundled backend.
    echo "bundled python-build-standalone=${PYTHON_VERSION}+${PYTHON_RELEASE}" > "${BUNDLE_ID_FILE}"
else
    echo "Warning: backend directory not found at ${BACKEND_DIR}"
    # Create a stub that will be replaced by the actual backend
    cat > "${BACKEND_BIN}" << 'EOF'
#!/bin/sh
echo "Backend not yet built. Run: cd backend && pip install -e ."
exit 1
EOF
    chmod +x "${BACKEND_BIN}"
    echo "stub missing-backend" > "${BUNDLE_ID_FILE}"
fi
