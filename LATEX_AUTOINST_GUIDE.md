# Overleaf with Automatic LaTeX Package Installation

This document explains the modifications made to support automatic LaTeX package installation and custom package management in Overleaf, particularly for Kubernetes deployments.

## Overview

The system now includes:

1. **Automatic Package Installation**: When LaTeX encounters a missing package, the compilation process automatically attempts to install it via TeX Live's `tlmgr` (TeX Live Manager)
2. **Enhanced latexmk Configuration**: Updated latexmkrc with support for auto-installation wrapper scripts
3. **Wrapper Scripts**: Shell scripts that intercept LaTeX compiler calls and handle package installation with retry logic
4. **Pre-installed Common Packages**: A curated list of frequently-used packages included in the base image to speed up first-time compilations

## How It Works

### Architecture

```
Latexmk (compilation orchestrator)
  ↓
pdflatex-autoinst / xelatex-autoinst / lualatex-autoinst / latex-autoinst
  ↓
Original pdflatex/xelatex/lualatex compiler
  ↓
Missing package detected? → tlmgr install package → Retry
```

### Modified Files

1. **server-ce/config/latexmkrc**
   - Configured to use wrapper scripts instead of calling compilers directly
   - These wrappers handle auto-installation logic

2. **server-ce/bin/\*-autoinst scripts**
   - `pdflatex-autoinst`: Wrapper for pdflatex
   - `xelatex-autoinst`: Wrapper for xelatex
   - `lualatex-autoinst`: Wrapper for lualatex
   - `latex-autoinst`: Wrapper for latex
   
   Each script:
   - Runs the compiler
   - Monitors output for missing package errors
   - Automatically installs missing packages using tlmgr
   - Retries compilation up to 3 times (configurable via MAX_ATTEMPTS)
   - Prevents infinite loops by tracking installed packages

3. **server-ce/Dockerfile**
   - Added commands to copy wrapper scripts to `/usr/local/bin/`
   - Made scripts executable

4. **server-ce/Dockerfile-base**
   - Pre-installed ~90 common LaTeX packages (amsmath, babel, beamer, glossaries, minted, tikz, etc.)
   - These reduce build time for typical documents

## Usage

### Basic Usage (No Changes Required)

Simply use Overleaf as normal. When a document uses a package not currently installed:

1. Compilation starts with latexmk
2. LaTeX compiler fails with "File 'glossaries.sty' not found"
3. Wrapper script detects the missing package
4. `tlmgr` automatically installs "glossaries"
5. Compilation automatically retries
6. Document compiles successfully

### Adding Custom Packages

#### Option 1: Pre-build with Custom Packages (Recommended for Kubernetes)

Extend the Dockerfile-base to include your custom packages:

```dockerfile
# In server-ce/Dockerfile-base, after the common packages section:

RUN tlmgr install --repository ${TEXLIVE_MIRROR} \
      your-custom-package-1 \
      your-custom-package-2 \
      your-custom-package-3
```

Then rebuild:

```bash
docker build -f server-ce/Dockerfile-base -t your-registry/sharelatex-custom-base:latest .
docker build --build-arg OVERLEAF_BASE_TAG=your-registry/sharelatex-custom-base:latest \
             -f server-ce/Dockerfile -t your-registry/sharelatex-custom:latest .
```

#### Option 2: Runtime Installation via Sidecar

For Kubernetes, use a sidecar that mounts a shared TeX Live volume:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: overleaf-with-packages
spec:
  containers:
  - name: overleaf
    image: your-registry/sharelatex-custom:latest
    volumeMounts:
    - name: texlive
      mountPath: /usr/local/texlive
    - name: custom-packages
      mountPath: /custom-packages
  
  - name: package-installer
    image: your-registry/sharelatex-custom:latest
    command: ["/bin/bash"]
    args:
    - -c
    - |
      # List of packages to install
      PACKAGES="your-package-1 your-package-2 your-package-3"
      for pkg in $PACKAGES; do
        tlmgr install --repository https://mirror.ox.ac.uk/sites/ctan.org/systems/texlive/tlnet $pkg
      done
      # Keep sidecar running
      tail -f /dev/null
    volumeMounts:
    - name: texlive
      mountPath: /usr/local/texlive
  
  volumes:
  - name: texlive
    emptyDir: {}
  - name: custom-packages
    configMap:
      name: custom-packages
```

#### Option 3: Just-in-Time Installation

Simply use packages in your LaTeX documents. They will be automatically installed on first compilation.

**Advantages:**
- No image rebuild needed
- Documents can use any package available on CTAN
- Easy to test new packages

**Disadvantages:**
- First compilation takes longer (package download + install)
- Requires internet access from the compilation container

## Configuration

### Adjusting Auto-Install Behavior

Edit the wrapper scripts (`server-ce/bin/*-autoinst`) to customize:

```bash
# Maximum retry attempts (default: 3)
MAX_ATTEMPTS=3

# TeX Live mirror URL (default: mirror.ox.ac.uk)
TEXLIVE_MIRROR=${TEXLIVE_MIRROR:-https://mirror.ox.ac.uk/sites/ctan.org/systems/texlive/tlnet}
```

Or set environment variables when running:

```bash
TEXLIVE_MIRROR=https://mirror.ctan.org/systems/texlive/tlnet docker run ...
```

### latexmkrc Extensions

The `server-ce/config/latexmkrc` can be extended with additional latexmk options:

```perl
# Example: Always cleanup auxiliary files after successful compilation
$clean_ext = "dvi ps eps";

# Example: Show PDF viewer
$pdf_previewer = "evince %O %S";

# Example: Maximum parallel jobs
$max_print_line = 200;
```

## Monitoring and Debugging

### Viewing Installation Logs

The wrapper scripts output installation progress with clear markers:

```
===== AutoInstall: Installing package 'glossaries' =====
... tlmgr output ...
===== AutoInstall: Retrying pdflatex after package installation =====
```

Look for these markers in:
- Docker logs: `docker logs <container>`
- Kubernetes logs: `kubectl logs <pod> -c web` (for the web service)
- Compilation output: Check the "Logs" tab in Overleaf

### Troubleshooting

**Problem: "Package not found" error still appears**

1. Check if the package name is correct
2. Verify tlmgr can reach the mirror
3. Check available disk space (TeX Live packages can be large)
4. Try explicitly installing: `tlmgr install package-name`

**Problem: Compilation times out**

1. Increase timeout in Overleaf settings (if applicable)
2. Pre-install packages during image build instead of runtime
3. Check network connectivity from container to CTAN mirror

**Problem: Package installation fails with permission denied**

Ensure the container has write permissions to `/usr/local/texlive`. This is usually handled automatically, but in Kubernetes you may need to adjust:

```yaml
volumeMounts:
- name: texlive-cache
  mountPath: /usr/local/texlive/2024/texmf-var  # Or current version
```

## Kubernetes Deployment

### Basic Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: overleaf
spec:
  replicas: 1
  selector:
    matchLabels:
      app: overleaf
  template:
    metadata:
      labels:
        app: overleaf
    spec:
      containers:
      - name: overleaf
        image: your-registry/sharelatex-custom:latest
        ports:
        - containerPort: 80
        env:
        - name: TEXLIVE_MIRROR
          value: "https://mirror.ox.ac.uk/sites/ctan.org/systems/texlive/tlnet"
        resources:
          requests:
            memory: "2Gi"
            cpu: "1"
          limits:
            memory: "4Gi"
            cpu: "2"
```

### With Persistent TeX Live Cache

For faster subsequent compilations, mount a persistent volume for TeX Live:

```yaml
volumeMounts:
- name: texlive-cache
  mountPath: /usr/local/texlive
- name: texmf-var
  mountPath: /var/lib/overleaf/tmp/texmf-var

volumes:
- name: texlive-cache
  persistentVolumeClaim:
    claimName: texlive-cache
- name: texmf-var
  emptyDir: {}
```

This way, installed packages persist across container restarts.

## Performance Considerations

### First Compilation
- Without pre-installed packages: ~60-90 seconds (includes package downloads)
- With pre-installed packages: ~10-30 seconds

### Subsequent Compilations
- No change: ~5-15 seconds (normal compilation time)

### Package Installation Speed
- Network-dependent: 1-5 seconds per package
- Depends on CTAN mirror and network latency

## Limitations and Notes

1. **Network Required**: Package installation requires internet access to CTAN mirrors
2. **Temporary Installations**: In non-persistent deployments, packages are lost on container restart
3. **Mirroring**: If you're behind a firewall, configure an internal CTAN mirror
4. **Package Dependencies**: Some packages have dependencies that must also be installed
5. **Supported Compilers**: Works with pdflatex, xelatex, lualatex, and latex

## Reverting to Manual Management

To revert to the old behavior without auto-installation:

1. Edit `server-ce/config/latexmkrc` and remove the wrapper script references:

```perl
# Change from:
$pdflatex = 'pdflatex-autoinst %O %S';
# Back to default (comment out):
# $pdflatex = 'pdflatex %O %S';
```

2. Rebuild the Docker image

## Contributing Custom Packages

To suggest frequently-used packages for inclusion in the pre-installed set:

1. Test the package in a compilation
2. Document its use case
3. Verify it doesn't conflict with existing packages
4. Submit a PR to add it to the Dockerfile-base installation list

## Best Practices

1. **For Public Servers**: Use Option 1 (pre-built with packages) for reliability and performance
2. **For Development**: Use Option 3 (just-in-time) for flexibility
3. **For Production Kubernetes**: Combine Options 1 + persistent volume for best performance
4. **Monitor Disk Usage**: Pre-installed packages add ~2-3GB to the image
5. **Regular Updates**: Periodically update TeX Live with `tlmgr update --all`

## Support and Issues

For issues or questions:

1. Check the troubleshooting section above
2. Review the wrapper script output in compilation logs
3. Test manually: `tlmgr install package-name` to verify package availability
4. Check CTAN mirror status

---

**Note**: This system is based on latexmk's reliable compilation approach, which already handles multi-pass compilation, bibliography generation, and other complex LaTeX workflows. The auto-installation is an additional enhancement.
