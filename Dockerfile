# Build stage
ARG PYTHON_VERSION=3.12-slim-bullseye
FROM python:${PYTHON_VERSION} AS builder

# Create virtual environment
RUN python -m venv /opt/venv

# Install build dependencies, CRITICAL X11/GL libraries, and utility tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    # Standard Python build dependencies
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncursesw5-dev \
    xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev \
    # Utility needed for downloading the Gmsh executable
    wget \
    # --- CRITICAL FIXES FOR PyVista/VTK (libX11.so.6, libGLU.so.1, and GL) ---
    libx11-6 \
    libxext6 \
    libxrender1 \
    libgl1-mesa-glx \
    libglu1-mesa \
    xvfb \
    # -------------------------------------------------------------------------
    git \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/venv/bin:$PATH

# Install base Python packages
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir \
    jupyter \
    numpy pandas matplotlib seaborn scikit-learn \
    open-darts \
    pyvista \
    # Gmsh Python bindings
    gmsh \
    && jupyter notebook --generate-config \
    && rm -rf /root/.cache/pip/*

# --------------------------------------------------------------------------
# Final stage
# --------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}

# Define and set environment variables
ARG NOTEBOOKS_DIR=/notebooks
ARG VOLUME_MOUNT_PATH=/notebooks/volume
ARG REPO_DIR=/notebooks/repo
ARG CLONE_ROOT=/notebooks/workspaces

ENV PATH=/opt/venv/bin:$PATH
ENV JUPYTER_IP=0.0.0.0
ENV PORT=8888
ENV NOTEBOOKS_DIR=${NOTEBOOKS_DIR}
ENV REPO_DIR=${REPO_DIR}
ENV CLONE_ROOT=${CLONE_ROOT}
ENV CLONE_COUNT=30
# Headless Rendering Fix
ENV PYVISTA_OFF_SCREEN=true 

# Copy virtual env from builder
COPY --from=builder /opt/venv /opt/venv

# Install runtime dependencies, X11/GL libraries, and the GMSH EXECUTABLE
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    # --- CRITICAL FIXES REPEATED FOR FINAL STAGE ---
    libx11-6 libxext6 libxrender1 libgl1-mesa-glx xvfb wget libglu1-mesa \
    # -----------------------------------------------
    # --- CRITICAL FIX: MANUALLY INSTALL GMSH EXECUTABLE (v4.13.1) ---
    && GMSH_VERSION="4.13.1" \
    && GMSH_DEB="gmsh_${GMSH_VERSION}_amd64.deb" \
    && wget -O /tmp/$GMSH_DEB "https://gmsh.info/bin/Linux/gmsh-${GMSH_VERSION}-Linux64.deb" \
    # Install the package and automatically install any missing dependencies
    && dpkg -i /tmp/$GMSH_DEB || apt-get install -fy \
    && rm -f /tmp/$GMSH_DEB \
    # ----------------------------------------------------------------
    && rm -rf /var/lib/apt/lists/*

# Copy and run install scripts
COPY ./build_scripts/install_packages.sh /opt/install_packages.sh
COPY ./build_scripts/pull_repo.sh /opt/pull_repo.sh
RUN chmod +x /opt/install_packages.sh && chmod +x /opt/pull_repo.sh

# Add args for GitHub repository
ARG GITHUB_REPO
ARG GITHUB_BRANCH=main
ARG GITHUB_TOKEN
ARG PY_REQUIREMENTS

# Create directories
RUN mkdir -p "${NOTEBOOKS_DIR}/samples" && \
    mkdir -p "${VOLUME_MOUNT_PATH}" && \
    mkdir -p "${REPO_DIR}" && \
    chmod -R 777 "${VOLUME_MOUNT_PATH}"

# Pull GitHub repository into the source directory
RUN if [ ! -z "$GITHUB_REPO" ]; then \
        /opt/pull_repo.sh "$GITHUB_REPO" "$GITHUB_BRANCH" "$REPO_DIR"; \
    fi

# Install additional requirements
RUN /opt/install_packages.sh "${PY_REQUIREMENTS}" "${NOTEBOOKS_DIR}"

# Copy samples
COPY ./samples "${NOTEBOOKS_DIR}/samples"

# Set initial working directory to the root containing the clones
WORKDIR /notebooks

# Expose Jupyter port
EXPOSE 8888

# Create jupyter runner script (FIXED: Uses heredoc for stability)
RUN cat > /opt/jupyter_runner.sh <<EOF
#!/bin/bash
set -e

echo "Setting up \${CLONE_COUNT} isolated workspaces..."
mkdir -p \${CLONE_ROOT}

# Cloning loop
for i in \$(seq 1 \${CLONE_COUNT}); do
  TARGET_DIR="\${CLONE_ROOT}/workspace_\$(printf "%%02d" \$i)"
  if [ ! -d "\${TARGET_DIR}" ]; then
    cp -r \${REPO_DIR} \${TARGET_DIR}
    echo "Created workspace \${i}"
  fi
done

echo "Starting Jupyter Notebook..."
jupyter notebook --ip=\${JUPYTER_IP} --port=\${PORT} --no-browser --allow-root --NotebookApp.password=\$(python -c "from jupyter_server.auth import passwd; print(passwd('\$JUPYTER_PASSWORD'))") --NotebookApp.allow_root=True --NotebookApp.root_dir='/notebooks'
EOF

RUN chmod +x /opt/jupyter_runner.sh

CMD ["sh", "-c", "/opt/jupyter_runner.sh"]
