# Ollama and Web Search Stack

Local setup for running Open WebUI with SearXNG search support and either a
native or Docker-hosted Ollama server.

## Services

- `open-webui`: Open WebUI exposed on `http://localhost:3000/`
- `searxng`: SearXNG server exposed on `http://localhost:8080`
- `valkey`: backing store for SearXNG
- `ollama`: optional Docker-hosted Ollama server exposed on
  `http://localhost:11434`

The default `docker-compose.yaml` contains Open WebUI, SearXNG, and Valkey.
Open WebUI connects to Ollama on the host through
`http://host.docker.internal:11434`, which supports native Ollama on macOS.
Set `OLLAMA_BASE_URL` to override that endpoint. Authentication is disabled
for this local deployment. Hugging Face offline mode is enabled so the UI does
not block startup on external model downloads. Open WebUI RAG embeddings are
configured to use Ollama with `qwen3-embedding:0.6b`.
Open WebUI web search is enabled through SearXNG at
`http://searxng:8080/search?q=<query>`, returning 5 results with 2 concurrent
requests.

HTTPS is expected to terminate on the separate Caddy host. Point that Caddy
reverse proxy at `http://<this-host>:3000` and keep WebSocket proxying enabled.

## Setup

Create a local `.env` file from the example:

```bash
cp .env.example .env
```

Then replace the placeholder values:

```env
SEARXNG_SECRET=change-this-to-a-long-random-string
OLLAMA_API_KEY=change-this-to-a-long-random-string
```

The `.env` file is ignored by git and should not be committed.

## Run with Native Ollama on macOS

Ensure the native Ollama application or server is running, then start Open
WebUI and the search services:

```bash
docker compose up -d
```

Check or stop the stack:

```bash
docker compose config
docker compose down
```

### Start Ollama with Persistent Server Settings

The macOS LaunchAgent installer configures the native Ollama application at
login and starts it after applying these server settings:

- Flash Attention enabled
- `q4_0` KV cache quantization
- up to 2 parallel requests
- up to 2 loaded models
- 15-minute model keep-alive

Context length is intentionally not forced. The launcher clears any inherited
`OLLAMA_CONTEXT_LENGTH` value so Ollama can select its VRAM-aware default.
Two parallel requests and two loaded models can still require substantial
unified memory, especially when Ollama selects a large context.

Install and immediately activate the LaunchAgent:

```bash
./macos-install-launch-agent.sh --install --disable-login-item
```

The `--disable-login-item` option disables Ollama's stock managed login item
to avoid a startup race with the custom LaunchAgent. If macOS does not allow
the launchctl override to be changed, disable **Ollama** under **System
Settings > General > Login Items**. Without this option, the installer leaves
the stock login item unchanged and prints a warning when it remains enabled.

The installer does not stop a running Ollama application. It completes the
LaunchAgent setup and then tells you when a manual restart is required. Choose
**Quit Ollama** from its menu-bar icon and open Ollama again so the application
inherits the configured environment. If Ollama was not running, the LaunchAgent
starts it with the configured environment and no restart is needed.

Installed files and launcher logs are located at:

```text
~/.ollama/ollama-custom-launcher.sh
~/.ollama/logs/launch-agent.stdout.log
~/.ollama/logs/launch-agent.stderr.log
~/Library/LaunchAgents/local.ollama.configured-launch.plist
```

Because the LaunchAgent executes `ollama-custom-launcher.sh` directly, macOS
shows that name instead of the generic `zsh` executable under Background
Activity.

Verify the service and environment:

```bash
launchctl print "gui/$(id -u)/local.ollama.configured-launch"
launchctl getenv OLLAMA_CONTEXT_LENGTH
launchctl getenv OLLAMA_FLASH_ATTENTION
launchctl getenv OLLAMA_KV_CACHE_TYPE
launchctl getenv OLLAMA_NUM_PARALLEL
launchctl getenv OLLAMA_MAX_LOADED_MODELS
launchctl getenv OLLAMA_KEEP_ALIVE
```

`OLLAMA_CONTEXT_LENGTH` should be empty. The remaining values should be `1`,
`q4_0`, `2`, `2`, and `15m`, respectively. After running a model, use
`ollama ps` and inspect `~/.ollama/logs/server.log` to confirm the allocated
context and model placement.

Uninstall the custom LaunchAgent while leaving Ollama's stock login-item state
unchanged:

```bash
./macos-install-launch-agent.sh --uninstall
```

To also restore the stock login item for the next login:

```bash
./macos-install-launch-agent.sh --uninstall --enable-login-item
```

Uninstallation preserves Ollama models, keys, and logs. If Ollama is already
running, restart it afterward to discard the environment inherited at launch.

## Run with Docker Ollama

Start Ollama from its dedicated Compose file, then start Open WebUI and the
search services:

```bash
docker compose -f docker-compose-ollama.yaml up -d
docker compose up -d
```

Check or stop both stacks:

```bash
docker compose -f docker-compose-ollama.yaml config
docker compose config
docker compose down
docker compose -f docker-compose-ollama.yaml down
```

## Pull Models

Pull models from the platform-specific default list:

```bash
./pull-models.sh
```

On Apple Silicon macOS, the default is `models-mlx.list`. All other platforms
use `models-gguf.list`. The Apple Silicon list prefers official MLX variants
and uses regular Ollama variants for models without an MLX version.

On macOS, the script uses the native `ollama` binary when it is available and
falls back to the Docker Compose `ollama` service otherwise. Other platforms
use Docker Compose by default. Model-list selection is based on the platform
and is independent of backend selection. Docker pulls target
`docker-compose-ollama.yaml`.

Force a backend:

```bash
./pull-models.sh --native
./pull-models.sh --docker
```

Pull models from a specific list:

```bash
./pull-models.sh models-gguf.list
./pull-models.sh --native models-mlx.list
```

Pull a single model or multiple comma-separated models:

```bash
./pull-models.sh qwen3.8:27b
./pull-models.sh qwen3.8:27b,gemma4:12b
```

Both included lists contain `qwen3-embedding:0.6b` and
`qwen3-embedding:8b`; Open WebUI uses the 0.6B model by default. Model list
files support blank lines and `#` comments. Run `./pull-models.sh --help` for
the complete command syntax. During a pull, the script reports the selected
backend and model source, prints each model as `[current/total]`, and finishes
with the number of models pulled successfully.

## Local Data

Ollama data is stored in `ollama-data/`. This directory can contain model blobs,
history, and local SSH keys generated by Ollama, so it is ignored by git.

Open WebUI data is stored in `open-webui-data/`. This directory can contain
chat history, users, settings, and other local application state, so it is also
ignored by git.
