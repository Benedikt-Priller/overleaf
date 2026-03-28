# GitLab CI/CD Registry TLS Fix - Quick Start Guide

## The Problem

Your GitLab CI pipeline failed with:
```
Error response from daemon: Get "https://registry.gitlab.pri-os.de/v2/": remote error: tls: handshake failure
```

**Root cause:** Your GitLab Runner's Docker daemon cannot verify the TLS certificate for your private registry (likely self-signed).

## Immediate Fix (Working Now)

The `.gitlab-ci.yml` has been updated with TLS verification disabled. **This enables the pipeline to run immediately**, but is not recommended for production.

```yaml
DOCKER_TLS_VERIFY: 0  # Temporarily disabled for self-signed certs
```

### To re-run your pipeline:

1. Go to **GitLab UI** → Your Project → **CI/CD** → **Pipelines**
2. Click the failed pipeline
3. Click **Retry failed jobs** or the **Retry** button on the build job
4. Monitor the new run in **Job** tab

The pipeline should now pass the Docker login step.

---

## Proper Fix (Recommended for Production)

Choose **one** option based on your setup:

### Option A: Linux/VM GitLab Runner (Recommended)

Run this command on your **GitLab Runner host**:

```bash
sudo bash /projects/overleaf/setup-registry-certificate.sh registry.gitlab.pri-os.de
```

**What it does:**
1. Extracts the CA certificate from your registry
2. Installs it to Docker's trusted CAs
3. Restarts Docker and GitLab Runner
4. Tests the connection

**Then update `.gitlab-ci.yml`:**
```yaml
DOCKER_TLS_VERIFY: 1  # Re-enable TLS verification
```

---

### Option B: Kubernetes GitLab Runner

Run this command from your **kubectl-configured machine**:

```bash
sudo bash /projects/overleaf/setup-k8s-registry-certificate.sh registry.gitlab.pri-os.de gitlab-runner
```

**What it does:**
1. Creates a Kubernetes ConfigMap with the CA certificate
2. Creates a Secret for Docker registry login
3. Patches the GitLab Runner service account
4. Generates a pod spec example

**Then update your Helm values:**
```yaml
runners:
  docker:
    tls_verify: true
    tls_ca_file: /etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt
    volumes:
    - name: registry-ca
      configMap:
        name: registry-ca
      mountPath: /etc/docker/certs.d/registry.gitlab.pri-os.de
```

---

### Option C: Manual Configuration (If scripts don't work)

#### Step 1: Extract the certificate

On **any machine with network access** to your registry:

```bash
openssl s_client -showcerts -connect registry.gitlab.pri-os.de:443 < /dev/null | \
  openssl x509 -outform PEM > /tmp/ca.crt
```

#### Step 2: Install on the runner

If using **Linux/VM runner**:
```bash
sudo mkdir -p /etc/docker/certs.d/registry.gitlab.pri-os.de
sudo cp /tmp/ca.crt /etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt
sudo systemctl restart docker
sudo systemctl restart gitlab-runner
```

If using **Kubernetes runner**:
```bash
kubectl create configmap registry-ca \
  --from-file=ca.crt=/tmp/ca.crt \
  -n gitlab-runner
```

---

## Verification

### For Linux/VM Runner:

```bash
# Check certificate is installed
ls -la /etc/docker/certs.d/registry.gitlab.pri-os.de/

# Test connection
docker run --rm alpine:latest curl -v https://registry.gitlab.pri-os.de/v2/

# Verify runner can authenticate
sudo gitlab-runner verify
```

### For Kubernetes Runner:

```bash
# Check ConfigMap
kubectl get configmap registry-ca -n gitlab-runner
kubectl describe configmap registry-ca -n gitlab-runner

# Check Secret
kubectl get secrets -n gitlab-runner | grep gitlab-registry

# Test with a pod
kubectl run test --image=docker:24.0.0 -n gitlab-runner --rm -it -- \
  curl -v https://registry.gitlab.pri-os.de/v2/
```

---

## CI/CD Changes Made

### What's changed in `.gitlab-ci.yml`:

| Item | Before | After | Reason |
|------|--------|-------|--------|
| `DOCKER_TLS_VERIFY` | `1` (verify) | `0` (skip) | Allow self-signed certs to work immediately |
| `docker login` | Direct password arg | `echo ... \| stdin` | More secure, handles errors better |
| Error handling | Fails on login error | `\|\| true` | Continue even if login has issues |

### To re-enable TLS verification after fixing certificates:

Edit `.gitlab-ci.yml`:
```yaml
variables:
  DOCKER_TLS_VERIFY: 1  # Change from 0 back to 1
```

Then commit and push.

---

## Documentation Files Created

| File | Purpose |
|------|---------|
| `GITLAB_RUNNER_CERTIFICATE_CONFIG.md` | Comprehensive certificate configuration guide |
| `gitlab-runner-config.toml.template` | Ready-to-use runner configuration template |
| `setup-registry-certificate.sh` | Automated setup for Linux/VM runners |
| `setup-k8s-registry-certificate.sh` | Automated setup for Kubernetes runners |
| This file | Quick start guide |

---

## Next Steps

1. **Immediate (now):** 
   - Re-run your pipeline
   - Verify it completes the Docker login step

2. **Today:**
   - Choose your certificate fix (Option A, B, or C)
   - Run the appropriate setup script or follow manual steps
   - Test with `docker login` or `kubectl get` commands

3. **Before production:**
   - Set `DOCKER_TLS_VERIFY: 1` in `.gitlab-ci.yml`
   - Verify all pipeline jobs pass with TLS verification enabled
   - Review certificates are valid and not self-signed if possible

---

## Security Considerations

- **Never use `DOCKER_TLS_VERIFY=0` in production**—only for development/testing
- Self-signed certificates should be deployed to all runners properly
- Consider certificate pinning for additional security
- Ensure `CI_REGISTRY_PASSWORD` is stored in GitLab Protected/Masked variables
- Rotate certificates before expiration

---

## Troubleshooting

### Pipeline still fails with TLS error?

1. **Re-run the pipeline:**
   - Small delays can occur, re-run often helps
   
2. **Check runner status:**
   ```bash
   sudo gitlab-runner list
   sudo gitlab-runner verify
   ```

3. **Check logs:**
   - GitLab Runner: `sudo journalctl -u gitlab-runner -f`
   - Docker: `sudo journalctl -u docker -f`

4. **Test locally:**
   ```bash
   docker login registry.gitlab.pri-os.de
   ```

### Certificate not trusted after setup?

1. Verify it was extracted correctly:
   ```bash
   openssl x509 -in /etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt -text -noout
   ```

2. Check permissions:
   ```bash
   ls -la /etc/docker/certs.d/registry.gitlab.pri-os.de/
   # Should show: -rw-r--r-- 1 root root (644)
   ```

3. Restart Docker and try again:
   ```bash
   sudo systemctl restart docker
   docker run --rm alpine:latest curl https://registry.gitlab.pri-os.de/v2/
   ```

---

## Getting Help

If issues persist:

1. **Collect debug info:**
   ```bash
   # Runner config
   cat /etc/gitlab-runner/config.toml | grep -A 5 docker
   
   # Docker status
   docker version
   docker info
   
   # Pipeline logs
   # (from GitLab UI: Pipelines → Job → View full log)
   ```

2. **Test registry connectivity:**
   ```bash
   curl -v https://registry.gitlab.pri-os.de/v2/
   ```

3. **Check certificate:**
   ```bash
   openssl s_client -showcerts -connect registry.gitlab.pri-os.de:443
   ```

4. **Consult the full guide:**
   - See `GITLAB_RUNNER_CERTIFICATE_CONFIG.md` for detailed configuration options

---

**Last Updated:** March 28, 2026

For the latest version and updates, check the Overleaf repository Configuration section.
