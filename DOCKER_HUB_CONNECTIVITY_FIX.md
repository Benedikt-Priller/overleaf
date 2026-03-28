# Docker Hub TLS Connectivity Issue - Diagnostic & Fix

## The Problem

Your CI pipeline fails when building `Dockerfile-base` with:
```
ERROR: failed to do request: Head "https://registry-1.docker.io./v2/phusion/baseimage/manifests/noble-1.0.2": 
remote error: tls: handshake failure
```

**Root Cause:** GitLab Runner's Docker daemon cannot reach Docker Hub (registry-1.docker.io.) with TLS.

This is **different from** the private registry issue—this is Docker Hub access.

---

## Quick Diagnostics

### Step 1: Check DNS Resolution

On your **GitLab Runner host**, run:

```bash
# Test DNS for Docker Hub
nslookup registry-1.docker.io.
dig registry-1.docker.io.

# Alternative test
docker run --rm alpine:latest nslookup registry-1.docker.io.
```

**Expected:** Should resolve to Docker Hub IPs (likely 35.x.x.x range)

### Step 2: Test Docker Hub Connectivity

```bash
# Test HTTPS connectivity to Docker Hub
curl -v https://registry-1.docker.io./v2/

# Test from within Docker container
docker run --rm alpine:latest curl -v https://registry-1.docker.io./v2/

# Test pulling a simple image
docker pull alpine:latest  # Most basic test

# Or try the specific image
docker pull phusion/baseimage:noble-1.0.2
```

**Expected:** Should complete without TLS errors

### Step 3: Check Runner Environment

```bash
# Check if runner is behind a proxy
env | grep -i proxy

# Check Docker daemon configuration
cat /etc/docker/daemon.json

# Check Docker version and info
docker version
docker info | grep -A 5 "registries"
```

---

## Common Causes & Fixes

### Cause #1: Network Proxy

If your network routes traffic through a proxy, Docker needs configuration.

**Check for proxy:**
```bash
env | grep -i proxy
# Should show: HTTP_PROXY, HTTPS_PROXY, NO_PROXY, etc.
```

**Fix - Configure Docker daemon for proxy:**

Edit `/etc/docker/daemon.json`:
```json
{
  "proxies": {
    "default": {
      "httpProxy": "http://proxy.example.com.:8080",
      "httpsProxy": "https://proxy.example.com.:8080",
      "noProxy": "localhost,127.0.0.1,*.local,registry.gitlab.pri-os.de."
    }
  }
}
```

Then restart:
```bash
sudo systemctl restart docker
```

### Cause #2: Firewall Blocked HTTPS to Docker Hub

Your network firewall may block `registry-1.docker.io:443`.

**Check firewall:**
```bash
# Test connectivity
nc -zv registry-1.docker.io. 443
telnet registry-1.docker.io. 443

# Check from runner container
docker run --rm alpine:latest nc -zv registry-1.docker.io. 443
```

**Fix:** Work with your network admin to unblock:
- `registry-1.docker.io.:443` (Docker Hub)
- `auth.docker.io.:443` (Docker authentication)
- `*.docker.io.:443` (Docker CDN)

### Cause #3: Missing CA Certificates in Runner Environment

The runner's Docker daemon might not trust the network's SSL certificates (e.g., in a man-in-the-middle proxy scenario).

**Check CA certificates:**
```bash
# List CA certificates
ls -la /etc/docker/certs.d/
ls -la /etc/ssl/certs/

# Test full certificate chain
openssl s_client -connect registry-1.docker.io.:443
```

**Fix:** Add your organization's CA certificate:
```bash
# If using corporate proxy with self-signed certs:
sudo cp /path/to/ca-cert.pem /etc/docker/certs.d/registry-1.docker.io./ca.crt
sudo systemctl restart docker
```

### Cause #4: DNS Resolution Failure

Docker daemon might not be able to resolve Docker Hub domain.

**Check DNS in Docker:**
```bash
# Check Docker's DNS configuration
cat /etc/docker/daemon.json

# Test DNS from container
docker run --rm alpine:latest nslookup registry-1.docker.io.
```

**Fix - Set explicit DNS servers in daemon.json:**
```json
{
  "dns": ["8.8.8.8.", "8.8.4.4."],
  "insecure-registries": []
}
```

Or use your organization's DNS:
```json
{
  "dns": ["your-dns-server-1.", "your-dns-server-2."]
}
```

Then restart Docker:
```bash
sudo systemctl restart docker
```

### Cause #5: GitLab Runner Container Network Isolation

If running GitLab Runner in Docker/Kubernetes, network access might be restricted.

**For Kubernetes runners:**

Check pod network policy:
```bash
kubectl get networkpolicies -n gitlab-runner
kubectl describe networkpolicy <policy-name> -n gitlab-runner
```

**Fix:** Update network policy to allow Docker Hub:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dockerhub
  namespace: gitlab-runner
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  # Allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
  # Allow Docker Hub
  - to:
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 80
```

---

## Immediate Workarounds

### Workaround #1: Use Docker Buildkit with Registry Mirror

Configure Docker to use a registry mirror closer to you:

Edit `/etc/docker/daemon.json`:
```json
{
  "registry-mirrors": [
    "https://mirror.aliyun.com.",
    "https://docker.mirrors.ustc.edu.cn."
  ]
}
```

Restart:
```bash
sudo systemctl restart docker
```

Then test:
```bash
docker pull phusion/baseimage:noble-1.0.2
```

### Workaround #2: Use Buildah Instead of Docker

If Docker connectivity is problematic but you have network access, use Buildah:

```bash
# Install buildah
sudo apt-get install buildah

# Use in CI pipeline (edit .gitlab-ci.yml)
image: buildah:latest
services: []  # Don't use DinD
script:
  - buildah build -f Dockerfile-base -t $IMAGE_BASE:$CI_COMMIT_SHA .
  - buildah push $IMAGE_BASE:$CI_COMMIT_SHA
```

### Workaround #3: Increase Timeout & Retry

Edit .gitlab-ci.yml to allow more retries and longer timeout:

```yaml
.docker_build_template: &docker_build
  stage: build
  image: docker:24.0.0
  retry:
    max: 2
    when:
      - runner_system_failure
      - stuck_or_timeout_failure
      - stale_runner
  timeout: 1h
```

### Workaround #4: Pull Base Image Manually First

In runner pre-script, pre-pull the base image:

```yaml
.docker_build_template: &docker_build
  before_script:
    - docker pull phusion/baseimage:noble-1.0.2 || true
    - # Rest of login script...
```

---

## Permanent Fix Checklist

- [ ] **Network Access:** Verify runner can reach registry-1.docker.io:443
- [ ] **Firewall:** Whitelist Docker Hub domains
- [ ] **DNS:** Confirm DNS resolution works
- [ ] **Proxy:** Configure Docker daemon if behind proxy
- [ ] **Certificates:** Install CA certs if needed
- [ ] **Docker Config:** Review `/etc/docker/daemon.json`
- [ ] **Test Connectivity:**
  ```bash
  docker pull phusion/baseimage:noble-1.0.2
  ```
- [ ] **Runner Tests:**
  ```bash
  sudo gitlab-runner verify
  sudo gitlab-runner list
  ```

---

## Testing After Fix

```bash
# 1. Test Docker daemon directly
docker pull alpine:latest
docker pull phusion/baseimage:noble-1.0.2

# 2. Test DNS resolution
nslookup registry-1.docker.io.

# 3. Test from runner
sudo gitlab-runner verify

# 4. Run a CI pipeline
git commit --allow-empty -m "Test Docker Hub connectivity"
git push gitlab main

# Monitor in GitLab UI: CI/CD → Pipelines
```

---

## Advanced: Use Private Registry Cache

If Docker Hub access is permanently restricted in your environment, set up a local registry mirror:

```bash
# Using registry mirror container
docker run -d \
  -p 5000:5000 \
  -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io. \
  --name registry-mirror \
  registry:2

# Configure Docker to use local mirror
cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["http://localhost:5000"]
}
EOF

sudo systemctl restart docker
```

Then configure .gitlab-ci.yml to use local registry:
```yaml
variables:
  DOCKER_REGISTRY_MIRROR: "http://registry-mirror:5000"
```

---

## Support Commands

If issues persist, collect diagnostic information:

```bash
#!/bin/bash

echo "=== Docker Hub TLS Diagnostics ==="
echo ""
echo "1. DNS Resolution:"
nslookup registry-1.docker.io.
echo ""
echo "2. Connectivity:"
curl -v https://registry-1.docker.io./v2/
echo ""
echo "3. Docker Version:"
docker version
echo ""
echo "4. Docker Daemon Config:"
cat /etc/docker/daemon.json
echo ""
echo "5. Docker Info:"
docker info
echo ""
echo "6. Environment Variables:"
env | grep -i proxy
echo ""
echo "7. CA Certificates:"
ls -la /etc/docker/certs.d/
ls -la /etc/ssl/certs/ | head -20
echo ""
echo "8. Test Image Pull:"
docker pull phusion/baseimage:noble-1.0.2 2>&1 | tail -20
```

Save output and share with your infrastructure team.

---

## Next Steps

1. **Diagnose:** Run the diagnostics from Step 1-3 above
2. **Identify:** Which cause matches your situation
3. **Fix:** Apply the appropriate fix for your environment
4. **Test DNS:** Verify `nslookup registry-1.docker.io.` resolves correctly
5. **Test Pull:** Verify with `docker pull phusion/baseimage:noble-1.0.2`
6. **Deploy:** Re-run your CI pipeline

For Kubernetes runners, also check `k8s-configmap-secrets-example.yaml` for network policy examples.
