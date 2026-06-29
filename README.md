# Backend Engineering Take-Home Assignment: Dynamic Pricing Proxy

Welcome to the Tripla backend engineering take-home assignment! This exercise is designed to simulate a real-world problem you might encounter as part of our team.

## The Challenge

At Tripla, we use a dynamic pricing model for hotel rooms. Instead of static, unchanging rates, our model uses a real-time algorithm to adjust prices based on market demand and other data signals. This helps us maximize both revenue and occupancy.

Our Data and AI team built a powerful model to handle this, but its inference process is computationally expensive to run. To make this product more cost-effective, we analyzed the model's output and found that a calculated room rate remains effective for up to 5 minutes.

## Solution Overview

This service acts as a caching proxy between clients and the pricing model API. Instead of forwarding every request directly to the expensive upstream model, it caches each rate result in Redis for 5 minutes. Identical requests within that window are served from cache — no API call made.

```
Client → PricingController → PricingService → Redis (cache hit)
                                           ↘ RateApiClient → rate-api
```

---

## Quick Start

### Prerequisites

- Docker and Docker Compose

### Build and Run

```bash
docker compose up -d --build
```

This starts three services:
- `interview-dev` — the Rails application on port `3000`
- `rate-api` — the upstream pricing model on port `8080`
- `redis` — the cache store on port `6379`

### Test the Endpoint

```bash
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
# => {"rate":"15000"}
```

**Valid parameter values:**

| Parameter | Valid values |
|---|---|
| `period` | `Summer`, `Autumn`, `Winter`, `Spring` |
| `hotel` | `FloatingPointResort`, `GitawayHotel`, `RecursionRetreat` |
| `room` | `SingletonRoom`, `BooleanTwin`, `RestfulKing` |

### Run Tests

```bash
# Full test suite
docker compose exec interview-dev ./bin/rails test

# Specific test file
docker compose exec interview-dev ./bin/rails test test/services/api/v1/pricing_service_test.rb

# Specific test by name
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb -n test_should_get_pricing_with_all_parameters
```

### Inspect the Cache

```bash
# See a cached rate
redis-cli GET Summer/FloatingPointResort/SingletonRoom

# Check remaining TTL (in seconds)
redis-cli TTL Summer/FloatingPointResort/SingletonRoom

# Clear all cached rates
redis-cli FLUSHDB
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `RATE_API_URL` | `http://localhost:8080` | Base URL of the upstream pricing API |
| `RATE_API_TOKEN` | *(required)* | Auth token for the pricing API |
| `RATE_API_TIMEOUT` | `5` | HTTP timeout for upstream calls (seconds) |
| `RATE_CACHE_TTL` | `5` | How long a rate stays valid in cache (minutes) |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection URL |

For local development outside Docker, copy `.env` and adjust as needed. The file is gitignored.

---

## Design Decisions

### Why Redis?

Three options were considered:

**In-memory store (`Rails.cache` with `:memory_store`)** — simplest to add, but cache is per-process and lost on restart. Puma with multiple workers would have separate caches, leading to redundant API calls.

**SQLite cache table** — no new infrastructure, persists across restarts. But requires a migration, manual TTL management, and SQLite's write concurrency is limited under load.

**Redis** — native TTL support, shared across all processes and workers, battle-tested for this exact use case, and inspectable at runtime. The assignment explicitly allows adding dependencies. This was the clear choice.

### Cache Key Design

Cache keys use the format `{period}/{hotel}/{room}` (e.g. `Summer/FloatingPointResort/SingletonRoom`). This is human-readable and directly inspectable in `redis-cli`, which makes debugging straightforward.

### Why Read + Write Instead of `fetch`

`Rails.cache.fetch` with `raw: true` writes an empty string to Redis when the block returns `nil`. An API error returns `nil`, which would cache a blank value and prevent retries for the full TTL window — the user would be stuck with an error for 5 minutes.

Splitting into explicit `read` + `write` gives full control: only successful results are cached, errors are never stored.

```ruby
cached = Rails.cache.read(cache_key, raw: true)
return @result = cached if cached

result = @client.get_rate(...)
if result.success?
  @result = result.value.to_s
  Rails.cache.write(cache_key, @result, expires_in: CACHE_TTL, raw: true)
else
  errors << result.error
end
```

### Consistent Return Type

Rates are always returned as strings. With `raw: true`, Redis always deserializes values as strings. On a cache miss, `result.value` comes from `JSON.parse` and could be a String or Integer depending on the API. Calling `.to_s` before caching and returning ensures both paths are identical — no type surprises for callers.

### `Result` Struct in `RateApiClient`

The original scaffold had `PricingService` calling `JSON.parse(rate.body)` and traversing the response structure directly — the service layer knew about the HTTP wire format. This was refactored so `RateApiClient.get_rate` returns a typed `Result` struct `{ success, value, error }`. The service layer only reads `result.success?` and `result.value`.

This also fixed a pre-existing bug: `rate.body` was treated as a String on success (requiring `JSON.parse`) but as a Hash on error (accessed via `rate.body['error']`). The `Result` struct normalises both paths.

### HTTP Timeout

The upstream pricing model is described as computationally expensive. Without a timeout, a slow or hung API call would block a Puma thread indefinitely. Under concurrent load, all threads could be blocked, making the service unresponsive. A 5-second timeout (`RATE_API_TIMEOUT`) fails fast and protects thread availability. The value is configurable so it can be tuned without a code change.

### Error Handling Strategy

- **Upstream timeout/error**: `RateApiClient` returns `Result.new(success: false, error: ...)`. The service adds the error to `errors`, nothing is cached, the controller responds with `400` and a descriptive message.
- **Rate not found in response**: Treated the same as an API error — not cached, user can retry.
- **Redis unavailable**: The `error_handler` in the cache config logs the failure and allows the request to continue. The app degrades gracefully by hitting the upstream API directly on every request rather than crashing.

---

## Project Structure

```
app/
  controllers/api/v1/pricing_controller.rb   # param validation, response rendering
  services/api/v1/pricing_service.rb         # cache logic, orchestration
  services/base_service.rb                   # shared result/errors contract

lib/
  rate_api_client.rb                         # HTTParty client, Result struct
  pricing_constants.rb                       # VALID_PERIODS / HOTELS / ROOMS

test/
  controllers/pricing_controller_test.rb     # integration tests (param validation)
  services/api/v1/pricing_service_test.rb    # cache behaviour unit tests
  lib/rate_api_client_test.rb                # client unit tests

audits/
  design-patterns.md                         # design pattern usage evaluation
  error-handling.md                          # error handling findings and remediation
```

---

## AI Assistance

### Tool

[Claude Code](https://claude.ai/code) (Anthropic) — an AI-powered CLI that operates directly in the terminal with access to the file system and shell. It reads, writes, and edits source files; runs commands; and reasons over the full project context in a single session.

### Workflow

The workflow followed a consistent audit-then-implement loop:

1. **Read the codebase** — Claude Code read every source file to build a complete picture of the existing implementation before making any suggestions.
2. **Produce structured audits** — findings were written to `audits/` as markdown reports with importance scores and concrete remediation snippets, rather than making changes immediately. This kept the reasoning visible and reviewable before any code was touched.
3. **Implement specific findings** — after reviewing each audit, selected findings were implemented as targeted, minimal changes. No speculative refactoring was done beyond what the finding required.
4. **Write tests alongside the fix** — every code change was accompanied by tests that directly exercised the new behaviour.
5. **Commit with descriptive messages** — each commit captures the full scope of a change and references the finding it addresses.

### What was AI-assisted

| Area | What was done |
|------|---------------|
| **Audit: design patterns** | Evaluated all four pattern categories (creational, structural, behavioural, domain) across the codebase; produced `audits/design-patterns.md` with six findings and drop-in fix snippets |
| **Audit: error handling** | Mapped every error category (400–503) against what was actually handled; produced `audits/error-handling.md` with eleven findings ordered by importance |
| **EH-02 — network exception handling** | Added `NETWORK_ERRORS` constant and `rescue` clauses to `RateApiClient#get_rate` so network-level failures (`Net::OpenTimeout`, `SocketError`, etc.) and malformed JSON are caught and returned as `Result` objects instead of raising unhandled exceptions |
| **EH-01 — correct HTTP status for upstream failures** | Added `upstream_error?` flag and `add_upstream_error` to `BaseService`; updated `PricingService` to use it; updated `PricingController` to return `502 Bad Gateway` for upstream failures instead of `400 Bad Request` |
| **Test coverage** | Added parameterised network-error tests for every class in `NETWORK_ERRORS`, a malformed-JSON test, an `upstream_error?` assertion in the service test, and two new controller tests asserting 502 behaviour |

### What was written by hand

The core implementation — Redis caching strategy, `RateApiClient` / `PricingService` / `BaseService` architecture, `Result` struct, cache key design, `read`+`write` over `fetch`, environment variable configuration, Docker setup, and the original test suite — was written independently before AI assistance was used.

---

## Running Locally Without Docker

Start only Redis and the rate-api via Docker, then run Rails natively:

```bash
docker compose up -d rate-api redis

# Install dependencies
bundle install

# Start the server (env vars loaded from .env)
RATE_API_URL=http://localhost:8080 \
RATE_API_TOKEN=04aa6f42aa03f220c2ae9a276cd68c62 \
RATE_API_TIMEOUT=5 \
RATE_CACHE_TTL=5 \
REDIS_URL=redis://localhost:6379/0 \
bin/rails server
```
