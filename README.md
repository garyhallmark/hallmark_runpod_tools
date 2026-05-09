# Hallmark RunPod Tools

Utilities for starting an Ollama server on a RunPod GPU pod and keeping model
data on the persistent `/workspace` volume.

The main entrypoint is:

```bash
./pod_startup.sh
```

It installs or validates Ollama, starts `ollama serve`, pulls the configured
model if needed, and prints useful diagnostics.

## Create A RunPod Pod

1. Create a new RunPod pod with a CUDA-capable GPU.
2. Attach a network volume if you want model downloads to survive pod changes.
   RunPod mounts this at `/workspace`.
3. Use a CUDA/PyTorch-style image or template that can run `nvidia-smi`.
4. Expose HTTP port `11434`.
5. Add environment variables in the pod template if you want custom defaults:

```bash
OLLAMA_HOST=0.0.0.0:11434
OLLAMA_MODELS=/workspace/ollama-models
MODEL=gemma4:e4b
```

RunPod's public proxy URL for Ollama will usually look like:

```text
https://POD_ID-11434.proxy.runpod.net
```

Treat that URL as public unless you add your own access controls.

## Connect To The Pod

Use either the RunPod web terminal or SSH.

SSH usually looks like:

```bash
ssh POD_USER@ssh.runpod.io -i ~/.ssh/id_ed25519
```

RunPod shows the exact SSH command in the pod connection panel.

## Clone This Repo

From the pod:

```bash
cd /workspace
git clone git@github.com:garyhallmark/hallmark_runpod_tools.git
cd hallmark_runpod_tools
```

If the pod does not have your GitHub SSH key, use HTTPS instead:

```bash
git clone https://github.com/garyhallmark/hallmark_runpod_tools.git
cd hallmark_runpod_tools
```

## Run Startup

Normal startup:

```bash
./pod_startup.sh
```

Force Ollama reinstall and validation:

```bash
OLLAMA_FORCE_INSTALL=1 ./pod_startup.sh
```

Use a different model:

```bash
MODEL=llama3.1:8b ./pod_startup.sh
```

Use a different Ollama API port:

```bash
OLLAMA_HOST=0.0.0.0:11435 ./pod_startup.sh
```

If you change the port, expose the same port in RunPod.

## Important Environment Variables

`MODEL`
: Model to pull and use by default. Default: `gemma4:e4b`.

`OLLAMA_HOST`
: Bind address for the Ollama API. Default: `0.0.0.0:11434`.

`OLLAMA_MODELS`
: Model cache location. Default: `/workspace/ollama-models`.

`OLLAMA_FORCE_INSTALL`
: Set to `1` or `true` to reinstall Ollama even if it appears installed.

`OLLAMA_INSTALL_MAX_TIME`
: Max seconds allowed for downloading the official installer. Default: `1800`.

`OLLAMA_SMOKE_PORT`
: Temporary port used while validating the Ollama install. Default: `11435`.

`OLLAMA_SMOKE_SECONDS`
: Seconds to wait for the validation server to become healthy. Default: `30`.

`OLLAMA_RELEASE_ASSETS_IP`
: GitHub release-assets routing for the official Ollama installer. Default:
`auto`, which probes available IPs and temporarily pins the fastest one in
`/etc/hosts` during install. Set to `0` to disable, or set a specific IP such as
`185.199.109.133`.

`OLLAMA_RELEASE_ASSETS_PROBE_BYTES`
: Bytes to download from each GitHub release-assets IP during the installer
route probe. Default: `1048576`.

`OLLAMA_RELEASE_ASSETS_PROBE_SECONDS`
: Max seconds per GitHub release-assets IP probe. Default: `8`.

## Verify Ollama

Check the API:

```bash
curl http://127.0.0.1:11434/api/tags
curl http://127.0.0.1:11434/api/ps
```

Ask a question with the CLI:

```bash
ollama run gemma4:e4b "Return one short sentence."
```

Ask through the API:

```bash
curl http://127.0.0.1:11434/api/generate \
  -d '{"model":"gemma4:e4b","prompt":"Return one short sentence.","stream":false}'
```

From your laptop through the RunPod proxy:

```bash
curl https://POD_ID-11434.proxy.runpod.net/api/tags
```

## Logs And Diagnostics

Startup and server logs:

```bash
tail -100 /workspace/logs/ollama.log
tail -100 /workspace/logs/ollama-install.log
tail -100 /workspace/logs/ollama-smoke.log
```

Check running processes:

```bash
ps aux | grep '[o]llama'
cat /workspace/ollama.pid
```

Check GPU visibility:

```bash
nvidia-smi
```

Check whether Ollama detected CUDA:

```bash
grep 'inference compute' /workspace/logs/ollama.log /workspace/logs/ollama-smoke.log
```

A healthy GPU-backed startup should show an `inference compute` line with
`library=cuda`. If it only shows `id=cpu` while `nvidia-smi` sees a GPU, the
script treats that as an unhealthy Ollama install and reruns the installer.

Check the model cache:

```bash
du -sh /workspace/ollama-models
ollama list
```

## Common Issues

### `ollama run` appears to hang

First check whether the model is loading on CPU:

```bash
tail -100 /workspace/logs/ollama.log
grep 'inference compute' /workspace/logs/ollama.log
nvidia-smi
```

If `nvidia-smi` sees a GPU but Ollama logs show CPU-only inference, force a
reinstall:

```bash
pkill -f 'ollama serve' || true
rm -f /workspace/ollama.pid
OLLAMA_FORCE_INSTALL=1 ./pod_startup.sh
```

### Startup skipped install but Ollama is broken

The script now validates the install before skipping. To be explicit:

```bash
OLLAMA_FORCE_INSTALL=1 ./pod_startup.sh
```

### Port is unreachable from outside RunPod

Check that the pod exposes the same port as `OLLAMA_HOST`.

For the default:

```bash
OLLAMA_HOST=0.0.0.0:11434
```

RunPod must expose HTTP port `11434`, and the proxy URL should include `-11434`.

### Model downloads every time

Make sure `OLLAMA_MODELS` points under `/workspace`:

```bash
echo "$OLLAMA_MODELS"
du -sh /workspace/ollama-models
```

If models are stored outside `/workspace`, they may be lost when the pod's
ephemeral filesystem is replaced.

### Official Ollama install is slow

Look at:

```bash
tail -f /workspace/logs/ollama-install.log
```

The official installer downloads the Linux bundle through GitHub releases. On
some pods, DNS can choose a slow `release-assets.githubusercontent.com` edge. The
startup script probes the candidate GitHub release-assets IPs and temporarily
pins the fastest one during install.

If you find a known-good edge, force it:

```bash
OLLAMA_RELEASE_ASSETS_IP=185.199.109.133 OLLAMA_FORCE_INSTALL=1 ./pod_startup.sh
```

Disable pinning:

```bash
OLLAMA_RELEASE_ASSETS_IP=0 OLLAMA_FORCE_INSTALL=1 ./pod_startup.sh
```

Compare network speed from other sources:

```bash
apt-get update
curl -L -o /tmp/cloudflare-10mb.bin 'https://speed.cloudflare.com/__down?bytes=10000000'
```

If apt is fast but Ollama download is slow, the issue is likely connectivity to
GitHub release-assets from that pod or region. Try the auto pinning behavior,
a specific known-fast IP, a different RunPod region, or a different GPU host.

```bash
OLLAMA_FORCE_INSTALL=1 ./pod_startup.sh
```

## Updating The Script On A Pod

From `/workspace/hallmark_runpod_tools`:

```bash
git pull
./pod_startup.sh
```

## References

- [RunPod port exposure](https://docs.runpod.io/pods/configuration/expose-ports)
- [RunPod storage types](https://docs.runpod.io/pods/storage/types)
- [Ollama Linux install](https://docs.ollama.com/linux)
- [Ollama GPU docs](https://docs.ollama.com/gpu)
