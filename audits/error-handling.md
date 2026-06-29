# Error Handling Audit — Dynamic Pricing Proxy

**Date:** 2026-06-29 (rev 2 — post EH-01/EH-02 fixes)
**Branch:** `feature/rate-caching`
**Scope:** `app/`, `lib/`, `config/`, `test/`

---

## Current State Snapshot

| File | Error handling role |
|------|-------------------|
| `app/controllers/application_controller.rb` | Base controller — **empty, no `rescue_from`** |
| `app/controllers/api/v1/pricing_controller.rb` | Validation guards + 400/502 branching |
| `app/services/base_service.rb` | `errors` array, `valid?`, `upstream_error?` |
| `app/services/api/v1/pricing_service.rb` | Cache proxy, upstream error accumulation |
| `lib/rate_api_client.rb` | HTTP adapter — network + JSON errors rescued |
| `config/environments/production.rb` | Redis `error_handler` lambda |
| `config/environments/development.rb` | Redis `error_handler` lambda |
| `config/initializers/filter_parameter_logging.rb` | Sensitive param filtering |

---

## 1. Error Handling Consistency

### Centralized handler
`ApplicationController` (`application_controller.rb:1`) is empty — no `rescue_from`. Every error path is handled ad-hoc at three separate call sites inside `PricingController`:

- `validate_params` — four inline `render json:` calls (`pricing_controller.rb:26, 30, 34, 38`)
- `index` — two inline `render json:` calls for valid/upstream-error/service-error (`pricing_controller.rb:14-19`)

Any unhandled exception (e.g., a Redis connection error outside the cache lambda, an unexpected `ArgumentError`) produces a Rails framework response that does not match the application's `{ error: "..." }` envelope.

### Error format
All responses use `{ error: "string" }` — flat, consistent key name, but no `code`, `status`, `request_id`, or `details` fields. A machine reading the response cannot identify the error type without string matching. See **EH-05**.

### Custom error classes
None. Errors are plain strings in `BaseService#errors`. The `upstream_error?` boolean flag added in the last session distinguishes category at the service boundary, but there are no exception classes that carry this information structurally.

---

## 2. Error Category Coverage

| HTTP Status | Scenario | Status |
|-------------|----------|--------|
| 400 | Missing / invalid params | ✓ Handled — `validate_params` |
| 401 | Unauthenticated request | ✗ Not implemented — see **EH-06** |
| 403 | Unauthorized request | ✗ Not implemented |
| 404 | Unknown route | ✗ Not handled — see **EH-07** |
| 429 | Rate limit exceeded | ✗ Not implemented — see **EH-08** |
| 500 | Unhandled exception | ✗ No custom handler — see **EH-03** |
| 502 | Upstream API failure / network error | ✓ Handled — `upstream_error?` branch |
| 503 | Redis unavailable | ✗ Implicit fallback only — see **EH-09** |

---

## 3. Async Error Handling

This is a synchronous Rails API. `ApplicationJob` exists but is unused. Action Cable is configured but unused for pricing.

**Redis `error_handler`** is the only async-adjacent error path:

```ruby
# config/environments/production.rb:60-62 / development.rb:24-26
error_handler: ->(method:, returning:, exception:) {
  Rails.logger.error("[Redis] #{method} failed: #{exception.message}")
}
```

The lambda logs but the `returning:` value — `nil` for reads, `false` for writes — is silently used as the return value by `Rails.cache`. The caller (`PricingService#run`) never knows Redis was unavailable.

---

## 4. Error Recovery

| Mechanism | Status | Notes |
|-----------|--------|-------|
| Network exception handling | ✓ Added | `NETWORK_ERRORS` rescue in `rate_api_client.rb:34` |
| JSON parse error handling | ✓ Added | `JSON::ParserError` rescue in `rate_api_client.rb:36` |
| Retry | ✗ Absent | Single attempt per request |
| Circuit breaker | ✗ Absent | — |
| Cache-down fallback | Implicit | Redis failure → `nil` → API call; untested |
| Static/default rate fallback | ✗ Absent | No degraded response on total upstream failure |

---

## 5. Error Information

### Dev vs. production detail
- Development: `config.consider_all_requests_local = true` — Rails renders full stack traces for unhandled errors.
- Production: `config.consider_all_requests_local = false` — correct.
- Application error responses never include a stack trace.

### Internal details leaked to clients
`rate_api_client.rb:35` includes the Ruby exception class name in the error string returned to clients:

```ruby
Result.new(success: false, error: "Upstream unreachable: #{e.class}")
```

`e.class` produces `Net::OpenTimeout`, `SocketError`, etc. — Ruby internal class names that are meaningless to API clients and expose the technology stack. See **EH-01**.

### Logging completeness
- Redis errors: logged via `Rails.logger.error` — adequate.
- Upstream API failures: **never logged**. The error string enters `BaseService#errors` via `add_upstream_error` (`pricing_service.rb:21`) but no `Rails.logger` call exists in that path. See **EH-02**.
- Network errors: rescued and converted to `Result` — but only the generic class name is in the error string, with no server-side log of the full exception or which host was unreachable.

### Sensitive data in logs
- `filter_parameter_logging.rb:6` filters `:token` from request **params**.
- `RATE_API_TOKEN` is sent as an HTTP **header** (`rate_api_client.rb:5`). Rails does not filter request headers by default. In development with verbose logging enabled the token value will appear in the log.

---

## Findings

---

### EH-01 — Network error message leaks Ruby class name to clients

**Importance: 6 / 10**

`rate_api_client.rb:35` constructs the client-facing error string with `e.class`:

```ruby
Result.new(success: false, error: "Upstream unreachable: #{e.class}")
```

The error propagates to the JSON response body via `pricing_controller.rb:16`. API clients receive strings like `"Upstream unreachable: Net::OpenTimeout"` — a Ruby namespace that reveals the HTTP client implementation.

**Fix:** Use a generic message and log the detail server-side:

```ruby
# lib/rate_api_client.rb
rescue *NETWORK_ERRORS => e
  Rails.logger.warn("[RateApiClient] network error: #{e.class} — #{e.message}")
  Result.new(success: false, error: 'Upstream service unavailable')
rescue JSON::ParserError => e
  Rails.logger.warn("[RateApiClient] malformed response: #{e.message}")
  Result.new(success: false, error: 'Upstream returned malformed response')
end
```

---

### EH-02 — Upstream API failures never logged server-side

**Importance: 7 / 10**

When `RateApiClient` returns a failure `Result`, `PricingService#run` calls `add_upstream_error(result.error)` (`pricing_service.rb:21`). The error string reaches the client JSON response but leaves no server-side log entry. Debugging upstream outages requires correlating client reports with no corresponding server trace.

**Location:** `app/services/api/v1/pricing_service.rb:20-22`

```ruby
# Current — no log
else
  add_upstream_error(result.error)
end
```

**Fix:** One line:

```ruby
else
  Rails.logger.warn("[PricingService] upstream error (#{cache_key}): #{result.error}")
  add_upstream_error(result.error)
end
```

---

### EH-03 — No centralized exception handler; unhandled errors return un-enveloped response

**Importance: 7 / 10**

`ApplicationController` is empty (`application_controller.rb:1-2`). Any exception that escapes the application (Redis connection error outside the cache lambda, unexpected `ArgumentError`, missing ENV key not caught at boot, etc.) produces a Rails default response. In API-only mode this is typically:

```json
{ "status": 500, "error": "Internal Server Error" }
```

That does not match the application's `{ "error": "..." }` envelope and has a different key structure.

**Fix:**

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  rescue_from StandardError, with: :handle_internal_error

  private

  def handle_internal_error(exception)
    Rails.logger.error("[#{exception.class}] #{exception.message}\n#{exception.backtrace.first(5).join("\n")}")
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end
end
```

The `rescue_from StandardError` is broad — place it last so more specific `rescue_from` clauses (for routing, auth, etc.) take priority and are not swallowed.

---

### EH-04 — Four parallel `render json:` calls in `validate_params`; no shared render helper

**Importance: 4 / 10**

`validate_params` (`pricing_controller.rb:24-40`) repeats the `render json: { error: "..." }, status: :bad_request` pattern four times. Adding a new field to the error envelope (e.g., a `code` key) requires touching all four lines.

**Location:** `app/controllers/api/v1/pricing_controller.rb:26, 30, 34, 38`

**Fix:** Extract a one-liner helper — drop-in, no interface change:

```ruby
# app/controllers/application_controller.rb (add alongside rescue_from)
def render_error(message, status:)
  render json: { error: message }, status: status
end

# app/controllers/api/v1/pricing_controller.rb
def validate_params
  unless params[:period].present? && params[:hotel].present? && params[:room].present?
    return render_error('Missing required parameters: period, hotel, room', status: :bad_request)
  end
  unless VALID_PERIODS.include?(params[:period])
    return render_error("Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}", status: :bad_request)
  end
  unless VALID_HOTELS.include?(params[:hotel])
    return render_error("Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}", status: :bad_request)
  end
  unless VALID_ROOMS.include?(params[:room])
    return render_error("Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}", status: :bad_request)
  end
end

def index
  # ...
  if service.valid?
    render json: { rate: service.result }
  elsif service.upstream_error?
    render_error(service.errors.join(', '), status: :bad_gateway)
  else
    render_error(service.errors.join(', '), status: :bad_request)
  end
end
```

---

### EH-05 — No standard error envelope; no machine-readable error codes

**Importance: 5 / 10**

All error responses are `{ "error": "plain string" }`. There is no `code` field to identify the error category programmatically, no `request_id` for log correlation, and no `details` array for multi-field validation errors. Clients must pattern-match on string content.

**Fix:** Extend `render_error` (from EH-04) to accept an optional `code`:

```ruby
# app/controllers/application_controller.rb
def render_error(message, status:, code: nil)
  body = { error: message }
  body[:code]       = code       if code
  body[:request_id] = request.request_id
  render json: body, status: status
end
```

Usage:

```ruby
render_error('Missing required parameters: period, hotel, room',
             status: :bad_request, code: 'MISSING_PARAMS')
render_error(service.errors.join(', '),
             status: :bad_gateway, code: 'UPSTREAM_ERROR')
```

---

### EH-06 — No authentication layer; 401 never returned

**Importance: 6 / 10**

The proxy has no inbound authentication. Any client that discovers the endpoint can call it freely. The `RATE_API_TOKEN` header in `rate_api_client.rb:5` shows the upstream enforces auth, but the proxy itself does not.

**Unable to fully verify:** An upstream reverse proxy or API gateway may provide auth. To check, review infrastructure config (nginx, Kong, AWS API GW, etc.) outside this repository. If none exists:

**Fix (API token, drop-in):**

```ruby
# app/controllers/application_controller.rb
before_action :authenticate_request

private

def authenticate_request
  expected = ENV['PROXY_API_TOKEN']
  return if expected.nil?   # auth disabled when var not set

  provided = request.headers['X-Api-Token']
  unless ActiveSupport::SecurityUtils.secure_compare(expected.to_s, provided.to_s)
    render_error('Unauthorized', status: :unauthorized)
  end
end
```

`secure_compare` prevents timing attacks. Do not use `==`.

---

### EH-07 — Unknown routes return un-enveloped Rails 404

**Importance: 5 / 10**

A request to `GET /api/v1/nonexistent` raises `ActionController::RoutingError`. In API-only mode the default response body is not `{ "error": "..." }` — it uses Rails' internal format.

**Fix:**

```ruby
# config/routes.rb
Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get '/pricing', to: 'pricing#index'
    end
  end
  match '*path', to: 'application#not_found', via: :all
end

# app/controllers/application_controller.rb
def not_found
  render_error('Not found', status: :not_found)
end
```

---

### EH-08 — No rate limiting; upstream 429 semantics lost

**Importance: 4 / 10**

There is no inbound throttle. A high-frequency client can exhaust Redis connections or hit the upstream API's rate limit. When the upstream returns 429, `rate_api_client.rb:21` captures it as `"HTTP 429"` and the proxy returns it as a `502 Bad Gateway` — the 429 semantics and any `Retry-After` header are lost.

**Fix (pass-through 429):**

```ruby
# lib/rate_api_client.rb — inside get_rate, before the generic error branch
unless response.success?
  if response.code == 429
    retry_after = response.headers['Retry-After']
    msg = retry_after ? "Rate limited — retry after #{retry_after}s" : 'Rate limited by upstream'
    return Result.new(success: false, error: msg)
  end
  error = response.parsed_response&.dig('error') || "HTTP #{response.code}"
  return Result.new(success: false, error: error)
end
```

Then in the controller, surface it as 429 by checking the error string — or better, add a `status_code` field to `Result`:

```ruby
# Cleaner: add status_code to Result struct
Result = Struct.new(:success, :value, :error, :status_code, keyword_init: true) do
  def success? = success
end
```

---

### EH-09 — Redis failure mode is implicit and untested

**Importance: 5 / 10**

When Redis is unavailable, `Rails.cache.read` returns `nil` (via the `error_handler` lambda), triggering a cache miss and an API call. If the API also fails, the caller receives a `502 Bad Gateway` with no indication that Redis was also down. There are zero tests for this path.

**To verify:** `grep -r 'CannotConnect\|redis.*down\|cache.*fail' test/` — returns nothing.

**Fix (test coverage):**

```ruby
# test/services/api/v1/pricing_service_test.rb
test "falls through to API when cache read fails" do
  Rails.cache.stub(:read, ->(*) { raise Redis::CannotConnectError }) do
    client = mock_client(success: true, value: "15000")
    service = build_service(client: client)
    service.run
    assert service.valid?
    assert_equal "15000", service.result
  end
end

test "returns upstream error when both cache and API fail" do
  Rails.cache.stub(:read, ->(*) { raise Redis::CannotConnectError }) do
    client = mock_client(success: false, error: "Service unavailable")
    service = build_service(client: client)
    service.run
    assert_not service.valid?
    assert service.upstream_error?
  end
end
```

---

### EH-10 — `RATE_API_TOKEN` sent as HTTP header is not filtered from logs

**Importance: 5 / 10**

`filter_parameter_logging.rb:6` filters `:token` from request params. The `RATE_API_TOKEN` is set as an outbound HTTP header (`rate_api_client.rb:5`), not a param. In development with verbose HTTP logging (e.g., `httparty` debug mode or a logging middleware), the header value will appear in plaintext in logs.

**Unable to fully verify:** Whether the token actually appears depends on whether HTTParty request logging is enabled. To confirm: run `HTTPARTY_DEBUG=true rails server` in development and inspect stdout.

**Fix:** If HTTParty logging is not explicitly enabled, the risk is low. If it is, add a log sanitizer or disable request logging for the pricing client. Minimum safe guard:

```ruby
# lib/rate_api_client.rb — override logger to suppress headers
logger Rails.logger, :info, :curl   # :curl format does include headers — use :apache instead
# or suppress entirely:
logger nil
```

---

### EH-11 — `rescue nil` in test stub silently swallows JSON parse failures

**Importance: 2 / 10**

Test-only, but establishes a risky pattern.

**Location:** `test/lib/rate_api_client_test.rb:128`

```ruby
parsed = JSON.parse(body) rescue nil
```

If `body` is not valid JSON, `parsed` silently becomes `nil`. Any test passing a malformed body to `stub_response` will not raise — it will exercise the wrong code path and may pass for the wrong reason.

**Fix:**

```ruby
def stub_response(success:, body:, code: 200)
  parsed = JSON.parse(body)
  response = OpenStruct.new(
    success?: success,
    body: body,
    parsed_response: parsed,
    code: code
  )
  RateApiClient.stub(:post, response) { yield }
end
```

For the malformed-JSON test case, pass `parsed_response: nil` explicitly in the `OpenStruct` rather than relying on the helper.

---

## Summary Table

| ID | Importance | Category | Finding |
|----|-----------|----------|---------|
| EH-02 | 7 / 10 | Logging | Upstream API failures not logged server-side |
| EH-03 | 7 / 10 | Consistency | No `rescue_from`; unhandled exceptions return un-enveloped response |
| EH-01 | 6 / 10 | Information | Network error leaks Ruby class name (`Net::OpenTimeout`) to clients |
| EH-06 | 6 / 10 | Auth | No authentication layer; 401 never returned |
| EH-05 | 5 / 10 | Consistency | No standard error envelope; no machine-readable codes or request ID |
| EH-07 | 5 / 10 | Categorization | Unknown routes return un-enveloped Rails 404 |
| EH-09 | 5 / 10 | Recovery | Redis failure mode implicit and completely untested |
| EH-10 | 5 / 10 | Information | `RATE_API_TOKEN` HTTP header not filtered from logs |
| EH-04 | 4 / 10 | Consistency | Four parallel `render json:` call sites; no shared render helper |
| EH-08 | 4 / 10 | Categorization | No rate limiting; upstream 429 semantics lost |
| EH-11 | 2 / 10 | Testing | `rescue nil` in test stub silently hides JSON parse errors |

### Recommended fix order

1. **EH-02** — log upstream errors in `PricingService` (one line, immediate observability gain)
2. **EH-01** — replace `e.class` with a generic message in `RateApiClient` rescue clauses
3. **EH-03** — add `rescue_from StandardError` to `ApplicationController` (prevents un-enveloped 500s)
4. **EH-04** — extract `render_error` helper (enables EH-05 as a follow-on)
5. **EH-05** — add `code` and `request_id` to error envelope via `render_error`
6. **EH-07** — add catch-all route for 404s
7. **EH-09** — add Redis-down test coverage
8. **EH-10** — verify/suppress HTTParty header logging
9. **EH-06** — add authentication (infrastructure decision)
10. **EH-08** — add upstream 429 pass-through and optional inbound throttle
11. **EH-11** — remove `rescue nil` from test stub helper

### What is handled correctly (no action needed)

| Concern | Location |
|---------|----------|
| Network exceptions rescued | `rate_api_client.rb:34` — `NETWORK_ERRORS` rescue |
| JSON parse errors rescued | `rate_api_client.rb:36` — `JSON::ParserError` rescue |
| Upstream errors return 502, not 400 | `pricing_controller.rb:15-16` |
| Errors not cached on upstream failure | `pricing_service.rb:17-22` |
| Redis `error_handler` configured in dev + prod | `development.rb:24`, `production.rb:60` |
| `config.force_ssl = true` in production | `production.rb:43` |
| Sensitive params filtered from request logs | `filter_parameter_logging.rb:6` |
