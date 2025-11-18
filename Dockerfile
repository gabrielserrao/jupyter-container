# Build stage
ARG PYTHON_VERSION=3.12-slim-bullseye
# Use a minimal Debian image for the builder
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
    # --- CRITICAL FIXES FOR PyVista/VTK (libX11.so.6 and GL) ---
    libx11-6 \
    libxext6 \
    libxrender1 \
    libgl1-mesa-glx \
    xvfb \
    # -----------------------------------------------------------
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
    # Gmsh Python bindings (separate from the executable)
    gmsh \
    && jupyter notebook --generate-config \
    && rm -rf /root/.cache/pip/*

# --------------------------------------------------------------------------
# Final stage
# --------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}

ARG NOTEBOOKS_DIR=/notebooks
ARG VOLUME_MOUNT_PATH=/notebooks/volume

# Set Python Path and Jupyter environment
ENV PATH=/opt/venv/bin:$PATH
ENV JUPYTER_IP=0.0.0.0
ENV PORT=8888
ENV NOTEBOOKS_DIR=${NOTEBOOKS_DIR}
# --- Headless Rendering Fix: Critical for PyVista/VTK ---
ENV PYVISTA_OFF_SCREEN=true
# -------------------------------------------------------

# Copy virtual env from builder
COPY --from=builder /opt/venv /opt/venv

# Install runtime dependencies, X11/GL libraries, and the GMSH EXECUTABLE
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    # --- CRITICAL FIXES REPEATED FOR FINAL STAGE (X11/GL/Xvfb) ---
    libx11-6 libxext6 libxrender1 libgl1-mesa-glx xvfb wget \
    # ---------------------------------------------------------------
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
ARG REPO_DIR=/notebooks/repo
ARG PY_REQUIREMENTS

# Remove the user setup section and related chown commands
RUN mkdir -p "${NOTEBOOKS_DIR}/samples" && \
    mkdir -p "${VOLUME_MOUNT_PATH}" && \
    chmod -R 777 "${VOLUME_MOUNT_PATH}"

# Pull GitHub repository if GITHUB_REPO is provided
RUN if [ ! -z "$GITHUB_REPO" ]; then \
        /opt/pull_repo.sh "$GITHUB_REPO" "$GITHUB_BRANCH" "$REPO_DIR"; \
    fi

# Install additional requirements
RUN /opt/install_packages.sh "${PY_REQUIREMENTS}" "${NOTEBOOKS_DIR}"

# Copy samples
COPY ./samples "${NOTEBOOKS_DIR}/samples"

WORKDIR /notebooks

# Expose Jupyter port
EXPOSE 8888

# Create jupyter runner script
RUN printf "#!/bin/bash\n" > /opt/jupyter_runner.sh && \
    printf "cd ${NOTEBOOKS_DIR} && jupyter notebook --ip=\${JUPYTER_IP:-0.0.0.0} --port=\${PORT:-8888} --no-browser --allow-root --NotebookApp.password=\$(python -c \"from jupyter_server.auth import passwd; print(passwd('\$JUPYTER_PASSWORD'))\") --NotebookApp.allow_root=True\n" >> /opt/jupyter_runner.sh && \
    chmod +x /opt/jupyter_runner.sh

CMD ["sh", "-c", "/opt/jupyter_runner.sh"]
