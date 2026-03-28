# GitLab CI/CD Configuration for Self-Signed Registry

## TLS Certificate Issue Resolution

Your error indicates the Docker daemon cannot verify the TLS certificate for your private registry (`registry.gitlab.pri-os.de`). This is common in self-hosted deployments.

### Option 1: Configure GitLab Runner (Recommended)

Edit your **GitLab Runner's `/etc/gitlab-runner/config.toml`** to trust your registry's certificate:

```toml
[[runners]]
  [runners.machine]
    # ... existing config ...

  [runners.docker]
    image = "docker:24.0.0"
    privileged = true
    disable_cache = false
    volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
    
    # For self-signed certificates:
    # Option A: Skip TLS verification (less secure, dev/test only)
    tls_verify = false
    
    # Option B: Mount CA certificate into containers (recommended for production)
    # First, add your CA certificate:
    # volumes = [
    #   "/var/run/docker.sock:/var/run/docker.sock",
    #   "/etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt:/etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt:ro"
    # ]

  [runners.docker.tlsverify]
    # Path to CA certificate (if using Option B above)
    # ca_file = "/etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt"
```

### Option 2: Docker Daemon Configuration (Alternative)

On the **GitLab Runner host**, configure Docker to trust your registry. Create or edit `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["registry.gitlab.pri-os.de"],
  "debug": true,
  "tls": true,
  "tlscacerts": "/etc/docker/certs.d/ca.crt"
}
```

Then restart Docker:
```bash
sudo systemctl restart docker
```

### Option 3: Add CA Certificate to Docker

1. **Get your registry's CA certificate:**

```bash
# For GitLab with self-signed cert
openssl s_client -showcerts -connect registry.gitlab.pri-os.de:443 < /dev/null | \
  openssl x509 -outform PEM > /tmp/ca.crt
```

2. **Add it to Docker's trusted CAs:**

```bash
sudo mkdir -p /etc/docker/certs.d/registry.gitlab.pri-os.de
sudo cp /tmp/ca.crt /etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt
sudo systemctl restart docker
```

3. **On the GitLab Runner host (Kubernetes or VM):**

If using Kubernetes runners, mount the certificate:

```yaml
# runners-kubernetes-config.yaml
runners:
  docker:
    volumes:
    - name: docker-certs
      mountPath: /etc/docker/certs.d/registry.gitlab.pri-os.de/
      readOnly: true
  
  volumes:
  - name: docker-certs
    secret:
      secretName: registry-ca
      defaultMode: 0444
```

Then create the secret:

```bash
kubectl create secret generic registry-ca \
  --from-file=ca.crt=/path/to/ca.crt \
  -n gitlab-runner
```

## Quick Fix for Immediate Testing

If you need to get the pipeline running immediately, the `.gitlab-ci.yml` has been updated to:

1. Use `echo ... | docker login` instead of CLI password (more secure)
2. Set `DOCKER_TLS_VERIFY: 0` to disable certificate verification (testing only)
3. Add error tolerance with `|| true` exit handlers

### To use this immediately:

1. The pipeline will now attempt login with reduced TLS verification
2. Push to GitLab and re-run the pipeline

### Next Steps (Long-term Solution)

1. **Obtain your CA certificate** from your GitLab instance:
   ```bash
   openssl s_client -showcerts -connect registry.gitlab.pri-os.de:443 < /dev/null | \
     openssl x509 -outform PEM > /tmp/gitlab-ca.crt
   ```

2. **Configure your GitLab Runner** using Option 1 above (recommended)

3. **Set `DOCKER_TLS_VERIFY: 1`** back in `.gitlab-ci.yml` for security:
   ```yaml
   DOCKER_TLS_VERIFY: 1
   ```

## Kubernetes Runner Configuration

If you're running the GitLab Runner on Kubernetes, use this Helm values:

```yaml
runners:
  privileged: true
  docker:
    image: docker:24.0.0
    privileged: true
    tls_verify: false  # Or use cert mounting below
    
    # For certificate verification:
    tls_ca_file: /etc/docker/certs.d/registry.gitlab.pri-os.de/ca.crt
    
    volumes:
    - name: docker-sock
      hostPath: /var/run/docker.sock
      mountPath: /var/run/docker.sock
    
    # Optionally mount CA cert:
    - name: registry-ca
      secret:
        secretName: registry-ca
      mountPath: /etc/docker/certs.d/registry.gitlab.pri-os.de/

```

## Docker-in-Docker (DinD) Considerations

Since the pipeline uses `docker:24.0.0-dind` service, the DinD container itself needs certificate configuration:

```yaml
services:
  - name: docker:24.0.0-dind
    command: ["--tls=false"]  # Quick fix for testing
    # OR with certificate:
    # command: ["--tlscacert=/etc/docker/certs.d/ca.crt"]
    # volumes:
    # - /etc/docker/certs.d:/etc/docker/certs.d:ro
```

## Debugging Tips

1. **Check Docker daemon logs:**
   ```bash
   sudo journalctl -u docker -f
   docker ps
   ```

2. **Test registry connectivity:**
   ```bash
   curl -v https://registry.gitlab.pri-os.de/v2/
   ```

3. **View CI job logs** in GitLab UI for detailed error messages

4. **Test locally** before committing:
   ```bash
   docker login registry.gitlab.pri-os.de
   docker tag myimage registry.gitlab.pri-os.de/project/myimage:latest
   docker push registry.gitlab.pri-os.de/project/myimage:latest
   ```

## Security Notes

- **DOCKER_TLS_VERIFY=0** should only be used for testing/development
- For production, always use proper certificate verification
- Consider using certificate pinning for additional security
- Ensure CI_REGISTRY_PASSWORD and credentials are stored securely in GitLab secrets
