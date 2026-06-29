# Architecture Analysis — Dynamic Pricing Proxy

**Date:** 2026-06-27  
**Scope:** Full codebase audit prior to caching implementation  
**Files analysed:** `app/`, `lib/`, `config/`, `Dockerfile`, `docker-compose.yml`

---

## 1. Architectural Pattern

**Pattern:** Rails API-only MVC with a lightweight Service Layer.

```
┌─────────────────────────────────────────────────────────────┐
│                        HTTP Client                          │
└───────────────────────────┬─────────────────────────────────┘
                            │ GET /api/v1/pricing
┌───────────────────────────▼─────────────────────────────────┐
│              PricingController (HTTP Layer)                  │
│  • param validation                                         │
│  • domain constant definitions (VALID_PERIODS etc.)         │
│  • response rendering                                       │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│              PricingService (Business Layer)                 │
│  • orchestrates the rate fetch                              │
│  • parses HTTP response body directly ← problem             │
│  • no caching ← missing layer                               │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│              RateApiClient (Integration Layer)               │
│  • wraps HTTParty                                           │
│  • hardcoded fallback token ← security concern              │
│  • no timeout / retry config                                │
└───────────────────────────┬─────────────────────────────────┘
                            │ POST /pricing
┌───────────────────────────▼─────────────────────────────────┐
│          tripladev/rate-api (External Docker service)        │
└─────────────────────────────────────────────────────────────┘

MISSING LAYER:
┌─────────────────────────────────────────────────────────────┐
│                    Cache Layer (Redis)                       │
│  • should sit between PricingService and RateApiClient      │
│  • key: period+hotel+room  TTL: 5 min                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Separation of Concerns

**Overall: Partially good.** The service layer exists and is separated from the controller, but responsibility boundaries are blurred in two places.

| Layer | File | Verdict |
|---|---|---|
| HTTP / Routing | `PricingController` | ⚠️ Leaks domain constants |
| Business Logic | `PricingService` | ⚠️ Leaks HTTP parsing |
| Integration | `RateApiClient` | ✅ Correct boundary |
| Base Infra | `BaseService` | ✅ Clean |

---

## 3. Findings

---

### F-01 — Missing Cache Layer
**Severity: 10/10**

`PricingService#run` calls `RateApiClient.get_rate` on every request with no caching. The rate API is constrained to a single token and the assignment explicitly states rates are valid for 5 minutes. This is the primary architectural gap.

**Location:** `app/services/api/v1/pricing_service.rb:10`

```ruby
# current — every request hits the external API
rate = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)
```

**Fix:**
```ruby
def run
  cache_key = "pricing/#{@period}/#{@hotel}/#{@room}"
  cached = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
    fetch_from_api
  end
  @result = cached
end

private

def fetch_from_api
  rate = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)
  if rate.success?
    parsed = JSON.parse(rate.body)
    parsed['rates'].detect { |r|
      r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room
    }&.dig('rate').tap { |r| errors << 'Rate not found' unless r }
  else
    errors << extract_error(rate)
    nil
  end
end
```

---

### F-02 — Domain Constants Defined in the Controller
**Severity: 7/10**

`VALID_PERIODS`, `VALID_HOTELS`, `VALID_ROOMS` are business-domain values hardcoded inside `PricingController`. If any other class (a future service, a validator, a test helper) needs them, it must reference the controller — wrong direction of dependency.

**Location:** `app/controllers/api/v1/pricing_controller.rb:2-4`

```ruby
VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
VALID_HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
VALID_ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze
```

**Fix:** Move to a domain constants module.

```ruby
# lib/pricing_constants.rb
module PricingConstants
  VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
  VALID_HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  VALID_ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze
end
```

```ruby
# in controller
include PricingConstants
```

---

### F-03 — HTTP Response Parsing Leaks into the Service Layer
**Severity: 7/10**

`PricingService#run` calls `JSON.parse(rate.body)` and then traverses the raw JSON structure. The service layer now knows the shape of the HTTP response body — this couples the service to the wire format of the external API.

**Location:** `app/services/api/v1/pricing_service.rb:12-14`

```ruby
parsed_rate = JSON.parse(rate.body)
@result = parsed_rate['rates'].detect { |r|
  r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room
}&.dig('rate')
```

**Fix:** Move parsing into `RateApiClient` and return a plain value or a typed result object.

```ruby
# lib/rate_api_client.rb
def self.get_rate(period:, hotel:, room:)
  response = post("/pricing", body: build_body(period, hotel, room))
  return Result.new(success: false, error: parse_error(response)) unless response.success?

  rates = JSON.parse(response.body)['rates']
  rate  = rates.detect { |r| r['period'] == period && r['hotel'] == hotel && r['room'] == room }
  rate ? Result.new(success: true, value: rate['rate']) : Result.new(success: false, error: 'Rate not found')
end

Result = Struct.new(:success, :value, :error, keyword_init: true) do
  def success? = success
end
```

---

### F-04 — Hardcoded Fallback API Token in Source
**Severity: 8/10**

`RateApiClient` falls back to a literal token string when the env var is absent. This token is committed to version control and visible to anyone with repo access.

**Location:** `lib/rate_api_client.rb:5`

```ruby
headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
```

**Fix:** Remove the default. Fail loudly if the token is not configured.

```ruby
headers 'token' => ENV.fetch('RATE_API_TOKEN')
# raises KeyError at boot if missing — intentional
```

Add the token to `docker-compose.yml` under `environment:` instead.

---

### F-05 — No HTTP Timeout or Retry Configuration
**Severity: 6/10**

`RateApiClient` uses HTTParty with no `timeout` set. If the rate API hangs, Puma threads block indefinitely, exhausting the thread pool and making the service unresponsive.

**Location:** `lib/rate_api_client.rb` (entire class — timeout is absent)

**Fix:**
```ruby
class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers 'Content-Type' => 'application/json'
  headers 'token'        => ENV.fetch('RATE_API_TOKEN')
  default_timeout 5   # seconds — fail fast
end
```

---

### F-06 — Asymmetric Error Body Handling
**Severity: 5/10**

On success, `rate.body` is a JSON **String** (requiring `JSON.parse`). On failure, `rate.body` is accessed as a **Hash** via `rate.body['error']`. HTTParty auto-parses JSON response bodies into a Hash when the `Content-Type` is `application/json` — the success path manually re-parses a string, which only works if the API returns a non-JSON content type on success.

**Location:** `app/services/api/v1/pricing_service.rb:11-16`

```ruby
if rate.success?
  parsed_rate = JSON.parse(rate.body)   # treats body as String
  ...
else
  errors << rate.body['error']          # treats body as Hash
end
```

**Fix:** Normalise through `RateApiClient` (see F-03). If keeping current structure, use `rate.parsed_response` consistently, which HTTParty always provides as a Hash.

---

### F-07 — Cache Not Configured for Development / Production
**Severity: 6/10**

`config/environments/development.rb` sets `cache_store = :null_store` by default (caching disabled unless `tmp/caching-dev.txt` exists). `config/environments/production.rb` has `cache_store` commented out. Redis cache store is not wired in either environment.

**Location:**  
- `config/environments/development.rb:20-27`  
- `config/environments/production.rb:47` (commented out)

**Fix:** Once Redis is added to `docker-compose.yml`, configure in each environment:

```ruby
# config/environments/development.rb  &  production.rb
config.cache_store = :redis_cache_store, {
  url:            ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
  expires_in:     5.minutes,
  connect_timeout: 2,
  error_handler: ->(method:, returning:, exception:) {
    Rails.logger.error "Redis error: #{exception.message}"
  }
}
```

---

### F-08 — Tight Coupling: Service Hard-References Client by Name
**Severity: 4/10**

`PricingService` calls `RateApiClient` directly by constant name. This makes unit testing require stubbing at the class level (`RateApiClient.stub`) rather than injecting a collaborator.

**Location:** `app/services/api/v1/pricing_service.rb:10`

```ruby
rate = RateApiClient.get_rate(...)
```

**Fix (lightweight):** Accept an optional client dependency for testability.

```ruby
def initialize(period:, hotel:, room:, client: RateApiClient)
  @client = client
  ...
end

# in run:
rate = @client.get_rate(period: @period, hotel: @hotel, room: @room)
```

---

## 4. Anti-Pattern Summary

| Anti-pattern | Present | Location |
|---|---|---|
| Spaghetti code | No | — |
| Copy-paste programming | No | — |
| God class | No | — |
| Tight coupling (by name) | Yes | `PricingService` → `RateApiClient` (F-08) |
| Missing abstraction (cache) | Yes | Between service and client (F-01) |
| Wrong-layer constants | Yes | Domain consts in controller (F-02) |
| Responsibility leak | Yes | HTTP parsing in service (F-03) |
| Hardcoded secret | Yes | Fallback token in client (F-04) |

---

## 5. Modularity Rating: **6 / 10**

**What's good:**
- Service layer is separated from controller — correct intent
- `RateApiClient` is its own class, not inlined in the service
- `BaseService` provides a reusable error/result contract
- API-only Rails mode keeps the stack lean

**What pulls the score down:**
- Cache layer is entirely absent (the main deliverable)
- Domain constants live in the wrong layer
- Service is coupled to the HTTP response shape
- No Redis or cache store configured in any environment
- No timeout protection on the external HTTP call

---

## 6. Recommended Remediation Order

| Priority | Finding | Effort |
|---|---|---|
| 1 | F-01 Add Redis + cache layer | Medium |
| 2 | F-07 Configure cache store per environment | Low |
| 3 | F-04 Remove hardcoded token fallback | Low |
| 4 | F-05 Add HTTP timeout | Low |
| 5 | F-03 Move response parsing into client | Medium |
| 6 | F-02 Extract domain constants to lib/ | Low |
| 7 | F-06 Fix asymmetric body parsing | Low |
| 8 | F-08 Inject client dependency | Low |
