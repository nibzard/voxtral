#!/bin/sh
# BundleBackend.sh - Build and bundle the Python backend for the macOS app
# This script creates a self-contained Python environment using python-build-standalone.

set -e

BACKEND_DIR="${SRCROOT}/../backend"
BACKEND_DST="${BUILT_PRODUCTS_DIR}/backend"
BACKEND_BIN="${BACKEND_DST}/voxtral-backend"
PYTHON_RUNTIME="${BACKEND_DST}/python-runtime"
DOWNLOAD_CACHE="${SRCROOT}/../.python-standalone-cache"

# Python version to use (must match python-build-standalone naming).
# vllm-metal currently ships cp312 wheels, so keep the bundled runtime on 3.12.x.
PYTHON_VERSION="3.12.12"
PYTHON_RELEASE="20260203"
PYTHON_STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"

# Create destination directory
mkdir -p "${BACKEND_DST}"
mkdir -p "${DOWNLOAD_CACHE}"

# Function to download and extract Python standalone runtime
setup_python_runtime() {
    echo "Setting up Python standalone runtime..."

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

    # Setup Python runtime first
    setup_python_runtime

    # Install backend dependencies into the runtime
    echo "Installing backend dependencies..."
    "${PYTHON_RUNTIME}/bin/pip" install --upgrade pip
    "${PYTHON_RUNTIME}/bin/pip" install "${BACKEND_DIR}"

    # Create the launcher script that uses the bundled Python runtime
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
    echo "  - Python runtime: ${PYTHON_RUNTIME}"
    echo "  - Bundled Python version: $("${PYTHON_RUNTIME}/bin/python3" --version)"
else
    echo "Warning: backend directory not found at ${BACKEND_DIR}"
    # Create a stub that will be replaced by the actual backend
    cat > "${BACKEND_BIN}" << 'EOF'
#!/bin/sh
echo "Backend not yet built. Run: cd backend && pip install -e ."
exit 1
EOF
    chmod +x "${BACKEND_BIN}"
fi
