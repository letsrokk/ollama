# Reliable SearXNG Engine Tuning

## Goal

Make OpenClaw searches through the local SearXNG instance substantially more reliable while querying both Brave Search API and Google for every general web search.

Success means:

- general searches query `braveapi` and `google`;
- DuckDuckGo and Bing no longer participate;
- the Brave API key is not stored in tracked configuration or printed during verification;
- repeated Google CAPTCHA and HTTP 429 failures trigger a meaningful suspension instead of continued upstream requests;
- controlled JSON searches return results after the container is recreated; and
- the SearXNG logs contain no DuckDuckGo failures after the change.

## Current State

`searxng/settings.yml` uses default settings with a restricted engine list. The effective general-search pool is Google and DuckDuckGo because the pinned SearXNG image keeps Bing disabled by default. Recent container logs show a DuckDuckGo CAPTCHA. The DuckDuckGo engine raises that error with a zero-second suspension, so later searches can immediately hit it again.

The local inbound limiter is disabled. It is not responsible for upstream engine throttling and will remain disabled for this trusted local integration.

## Engine Design

The restricted engine list will contain:

- `braveapi` for API-backed general and web results;
- `google` for a second general and web result source; and
- `openstreetmap` for explicitly selected local searches.

DuckDuckGo, Bing, and the Google/Bing news engines will be removed. A normal general search will fan out to Brave API and Google concurrently. SearXNG does not provide primary/fallback engine ordering, so Google can still cause the first CAPTCHA or 429 warning even when Brave succeeds.

Brave API is expected to provide the stable result path. Google remains enabled by explicit user choice and is treated as a best-effort additional source.

## Secret Injection

The repository will document `BRAVE_SEARCH_API_KEY` in `.env.example`; the real value belongs in the already ignored `.env` file.

Tracked `settings.yml` will contain a unique Brave-key placeholder. A tracked startup helper will:

1. require `BRAVE_SEARCH_API_KEY` to be non-empty;
2. read the tracked settings template;
3. replace exactly the placeholder with the environment value using the image's Python runtime;
4. write the rendered settings to a temporary container-only path; and
5. execute the image's original entrypoint with `SEARXNG_SETTINGS_PATH` pointing at that temporary file.

Docker Compose will pass the key from `.env` and select the helper as the SearXNG entrypoint. The key will not be written into the bind-mounted repository directory.

The helper will not enable shell tracing or echo the key. Placeholder replacement will avoid shell interpolation so punctuation in the key cannot alter the command.

## Failure and Backoff Behavior

Outgoing retries will be set to zero. Retrying a blocked request can amplify upstream throttling, while the second engine already supplies redundancy.

SearXNG's suspension settings are global by failure class, not per engine. They will explicitly apply longer cooldowns to matching upstream failures:

- CAPTCHA: 43,200 seconds (12 hours);
- too many requests / HTTP 429: 1,800 seconds (30 minutes);
- access denied / HTTP 402 or 403: 3,600 seconds (1 hour).

Cloudflare and reCAPTCHA-specific defaults will remain at least as strict as the pinned image defaults. Existing request timeouts and connection-pool limits will remain unchanged because runtime evidence does not implicate them.

During a Google suspension, general searches will effectively rely on Brave API. If Brave returns the same failure class, it will receive the same cooldown and Google may remain available. SearXNG may report an engine as suspended or unresponsive; this is expected and preferable to repeatedly contacting a blocked upstream.

## Verification

Implementation verification will be performed without displaying the API key:

1. Validate the Compose model with `docker compose config --quiet` while suppressing rendered environment values.
2. Recreate the SearXNG container.
3. Confirm from `/config` that `braveapi` and `google` are enabled and DuckDuckGo/Bing are absent.
4. Send controlled JSON searches through the local `/search` endpoint and confirm usable results.
5. Inspect fresh SearXNG logs for startup/configuration errors, Brave authentication failures, and removed-engine activity.
6. Inspect Git status and diff, and search tracked files to confirm the real key is absent.

If the Brave key is missing, startup will fail with a clear message rather than silently running a degraded scraper-only configuration. If the key is invalid or its free quota is exhausted, SearXNG will expose the Brave API failure while Google may still return results.

## Scope

This change covers the SearXNG configuration and its Compose startup wiring. It does not reconfigure OpenClaw directly, change Open WebUI concurrency, add proxy rotation, enable the public-instance limiter, or alter unrelated services.
