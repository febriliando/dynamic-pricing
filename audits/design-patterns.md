# Design Pattern Audit — Dynamic Pricing Proxy

**Date:** 2026-06-29  
**Branch:** `feature/rate-caching`  
**Scope:** `app/`, `lib/`, `config/`

---

## Inventory of Source Files

| File | Role |
|------|------|
| `app/controllers/api/v1/pricing_controller.rb` | HTTP entry point, param validation |
| `app/controllers/application_controller.rb` | Base controller (empty) |
| `app/services/base_service.rb` | Abstract service base |
| `app/services/api/v1/pricing_service.rb` | Cache-then-fetch orchestration |
| `app/models/application_record.rb` | AR base (unused at runtime) |
| `lib/rate_api_client.rb` | HTTParty wrapper + Result VO |
| `lib/pricing_constants.rb` | Allowlist constants module |

---

## 1. Creational Patterns

### Singleton — Partial / Framework-delegated

`Rails.cache` (backed by Redis via `config.cache_store`) is a framework-managed Singleton, correctly configured in both `development.rb:21` and `production.rb:57`. No application-level Singletons are hand-rolled, which is appropriate.

`RateApiClient` (lib/rate_api_client.rb) uses only class methods and HTTParty class-level configuration:

```ruby
# lib/rate_api_client.rb:2-6
include HTTParty
base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
default_timeout ENV.fetch('RATE_API_TIMEOUT', 5).to_i
```

This makes the class behave as a Singleton module. Appropriate for a stateless proxy, but see **Finding F3**.

**Verdict:** Correctly delegated to the framework. No hand-rolled Singleton anti-patterns.

---

### Factory — Absent

No Factory pattern. `PricingService` instantiates itself via `new` called directly from the controller (`pricing_controller.rb:11`). `RateApiClient::Result` is constructed directly with `Result.new(...)`. For this scope, no factory is needed — the construction logic is trivial.

**Verdict:** Not needed at current complexity.

---

### Builder — Absent

`RateApiClient.build_body` (`lib/rate_api_client.rb:31`) assembles the JSON payload, but it's a single-step private helper, not a Builder. Appropriate given the payload has exactly one shape.

**Verdict:** Not applicable.

---

## 2. Structural Patterns

### Adapter — Present, Correct ✓

`RateApiClient` is a textbook Adapter: it wraps HTTParty (third-party) and translates the external API's response envelope into an internal `Result` struct.

```ruby
# lib/rate_api_client.rb:12-28
def self.get_rate(period:, hotel:, room:)
  response = post("/pricing", body: build_body(period, hotel, room))
  # ... translates HTTP response → Result struct
end
```

The downstream consumer (`PricingService`) never touches HTTParty or raw HTTP status codes. This boundary is clean and correct.

**Verdict:** Appropriate and correctly implemented.

---

### Facade — Present, Correct ✓

`PricingService` is a Facade over two subsystems: Redis cache and `RateApiClient`. The controller only calls `service.run` and inspects `service.valid?` / `service.result` — it never knows about cache keys, TTLs, or HTTP.

```ruby
# app/controllers/api/v1/pricing_controller.rb:11-17
service = Api::V1::PricingService.new(period:, hotel:, room:)
service.run
if service.valid?
  render json: { rate: service.result }
```

**Verdict:** Well-applied. The seam between controller and service is clean.

---

### Decorator — Absent

Rails' middleware stack (`ActionController::API`) provides the chain, but no application-level Decorator wraps requests or responses. Not needed for current scope.

---

### Proxy (Caching) — Present, Correct ✓

`PricingService#run` is a Cache Proxy: check cache → return early on hit → delegate to real subject on miss → write back.

```ruby
# app/services/api/v1/pricing_service.rb:12-22
def run
  cached = Rails.cache.read(cache_key, raw: true)
  return @result = cached if cached

  result = @client.get_rate(...)
  if result.success?
    @result = result.value.to_s
    Rails.cache.write(cache_key, @result, expires_in: CACHE_TTL, raw: true)
  else
    errors << result.error
  end
end
```

Error results are correctly not cached. This is one of the strongest pattern applications in the codebase.

**Verdict:** Correctly implemented.

---

## 3. Behavioral Patterns

### Chain of Responsibility — Present (Rails idiom) ✓

`before_action :validate_params` in `PricingController` is Rails' standard CoR: the filter halts the chain via `render` + implicit `return` before the action runs.

```ruby
# app/controllers/api/v1/pricing_controller.rb:4
before_action :validate_params
```

**Verdict:** Correct and idiomatic.

---

### Strategy — Absent (injection stub exists)

`PricingService` accepts a `client:` keyword argument defaulting to `RateApiClient`, hinting at a Strategy seam:

```ruby
# app/services/api/v1/pricing_service.rb:5
def initialize(period:, hotel:, room:, client: RateApiClient)
```

However, there is no abstract interface or documented contract for what a valid `client` must implement. See **Finding F1**.

---

### Observer — Absent

No events, hooks, or pub/sub. Not needed.

---

### Command — Absent

No background jobs for pricing requests. `ApplicationJob` exists but is unused. Not needed for a synchronous proxy.

---

## 4. Domain Patterns

### Service Layer — Present, Correct ✓

`BaseService` + `Api::V1::PricingService` form a proper service layer with a consistent protocol:

```ruby
# app/services/base_service.rb
class BaseService
  attr_accessor :result

  def valid?   = errors.blank?
  def errors   = @errors ||= []
end
```

The controller never performs business logic. **Issue:** `attr_accessor` exposes a setter — see **Finding F4**.

**Verdict:** Well-structured. The `run` / `valid?` / `result` / `errors` protocol is consistent.

---

### Repository Pattern — Missing (inline cache access)

`PricingService#run` directly calls `Rails.cache.read` and `Rails.cache.write` with concrete knowledge of the key format, TTL, and `raw:` flag. This couples the service to the storage mechanism.

```ruby
# app/services/api/v1/pricing_service.rb:13-19
cached = Rails.cache.read(cache_key, raw: true)
# ...
Rails.cache.write(cache_key, @result, expires_in: CACHE_TTL, raw: true)
```

See **Finding F2** for the extraction fix.

---

### Value Object / DTO — Present, Correct ✓

`RateApiClient::Result` is a well-formed Value Object:

```ruby
# lib/rate_api_client.rb:8-10
Result = Struct.new(:success, :value, :error, keyword_init: true) do
  def success? = success
end
```

Immutable by convention, carries only data, and provides a predicate. No changes needed.

---

### Domain Model — Not applicable

No domain entities needed for a stateless proxy. `ApplicationRecord` is correctly retained as the Rails-required base but not used.

---

## Findings

---

### F1 — No interface contract for injectable client

**Importance: 6 / 10**

`PricingService` accepts any object as `client:`, but requires it to implement `get_rate(period:, hotel:, room:)` returning a `Result`-like object. This contract is undocumented and unenforced. Any alternative implementation (stub, mock, fallback client) can silently mismatch.

**Location:** `app/services/api/v1/pricing_service.rb:5`, `lib/rate_api_client.rb:12`

**Fix:** Add a module that documents and self-enforces the contract:

```ruby
# lib/rate_client_interface.rb
module RateClientInterface
  def get_rate(period:, hotel:, room:)
    raise NotImplementedError, "#{self.class}#get_rate not implemented"
  end
end

# lib/rate_api_client.rb
class RateApiClient
  extend RateClientInterface   # documents the contract; class methods satisfy it
  # ... existing code unchanged
end
```

Alternatively, document the expected interface in a comment on the `client:` parameter.

---

### F2 — Repository pattern missing: cache logic inline in service

**Importance: 7 / 10**

`PricingService#run` knows the cache key format, TTL value, and `raw: true` flag. If the key schema changes (e.g., add a version prefix, per-room TTL), `PricingService` must be edited — a class that should not own storage concerns.

**Location:** `app/services/api/v1/pricing_service.rb:13–19`, `27–29`

**Fix:** Extract a cache repository object:

```ruby
# app/repositories/rate_cache_repository.rb
class RateCacheRepository
  TTL = ENV.fetch('RATE_CACHE_TTL', 5).to_i.minutes

  def read(period, hotel, room)
    Rails.cache.read(key(period, hotel, room), raw: true)
  end

  def write(period, hotel, room, value)
    Rails.cache.write(key(period, hotel, room), value, expires_in: TTL, raw: true)
  end

  private

  def key(period, hotel, room) = "#{period}/#{hotel}/#{room}"
end

# app/services/api/v1/pricing_service.rb
def initialize(period:, hotel:, room:, client: RateApiClient, cache: RateCacheRepository.new)
  @period = period
  @hotel  = hotel
  @room   = room
  @client = client
  @cache  = cache
end

def run
  cached = @cache.read(@period, @hotel, @room)
  return @result = cached if cached

  result = @client.get_rate(period: @period, hotel: @hotel, room: @room)
  if result.success?
    @result = result.value.to_s
    @cache.write(@period, @hotel, @room, @result)
  else
    errors << result.error
  end
end
```

Also remove `CACHE_TTL` from `PricingService` — it moves to `RateCacheRepository`.

---

### F3 — `RateApiClient` is all class methods; cannot be configured per-instance

**Importance: 5 / 10**

HTTParty configuration (`headers`, `base_uri`, `default_timeout`) is set at the class level on load. This means the token and URL are fixed for the process lifetime. Per-tenant tokens, per-request timeouts, or multiple upstream environments are impossible without process restart.

**Location:** `lib/rate_api_client.rb:2–6`

**Fix:** Convert to an instance-based client:

```ruby
class RateApiClient
  Result = Struct.new(:success, :value, :error, keyword_init: true) do
    def success? = success
  end

  def initialize(
    base_url: ENV.fetch('RATE_API_URL', 'http://localhost:8080'),
    token:    ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62'),
    timeout:  ENV.fetch('RATE_API_TIMEOUT', 5).to_i
  )
    @base_url = base_url
    @token    = token
    @timeout  = timeout
  end

  def get_rate(period:, hotel:, room:)
    response = HTTParty.post(
      "#{@base_url}/pricing",
      body: build_body(period, hotel, room),
      headers: { 'Content-Type' => 'application/json', 'token' => @token },
      timeout: @timeout
    )
    # ... rest unchanged
  end
end

# In PricingService:
def initialize(..., client: RateApiClient.new)
```

This also removes the need for `extend RateClientInterface` — instance methods satisfy the interface naturally.

---

### F4 — `BaseService` exposes `result` as a mutable accessor

**Importance: 4 / 10**

`attr_accessor :result` in `BaseService` allows any caller to overwrite `service.result` after `run` completes. This breaks the invariant that `result` is set only by the service's own logic.

**Location:** `app/services/base_service.rb:2`

**Fix:** One-character change:

```ruby
# app/services/base_service.rb
class BaseService
  attr_reader :result   # was: attr_accessor
  # ...
end
```

Subclasses set `@result` directly, which is unaffected by this change.

---

### F5 — Network exceptions not rescued in `RateApiClient`

**Importance: 7 / 10**

`RateApiClient.get_rate` handles non-2xx HTTP responses but does not rescue network-level exceptions (`Net::OpenTimeout`, `Net::ReadTimeout`, `SocketError`, `Errno::ECONNREFUSED`). These propagate as unhandled 500s with a stack trace, bypassing the `Result` error path and the service's error accumulation.

**Location:** `lib/rate_api_client.rb:12–28`

**Fix:**

```ruby
NETWORK_ERRORS = [
  Net::OpenTimeout, Net::ReadTimeout, Net::HTTPError,
  SocketError, Errno::ECONNREFUSED, EOFError
].freeze

def self.get_rate(period:, hotel:, room:)
  response = post("/pricing", body: build_body(period, hotel, room))
  # ... existing success/failure handling
rescue *NETWORK_ERRORS => e
  Result.new(success: false, error: "Network error: #{e.class}")
end
```

---

### F6 — Param validation inline in controller rather than a Value Object

**Importance: 5 / 10**

`validate_params` in `PricingController` performs three sequential `unless` guards with repeated `render json:` calls. If a new required param is added, or the valid-value sets grow, this method becomes the wrong place to evolve. The service receives raw strings without any indication that validation has occurred.

**Location:** `app/controllers/api/v1/pricing_controller.rb:22–38`

**Fix:** Extract a `PricingParams` value object (plain Ruby, no AR dependency):

```ruby
# app/value_objects/pricing_params.rb
class PricingParams
  include PricingConstants
  include ActiveModel::Validations

  attr_reader :period, :hotel, :room

  validates :period, inclusion: { in: VALID_PERIODS }
  validates :hotel,  inclusion: { in: VALID_HOTELS  }
  validates :room,   inclusion: { in: VALID_ROOMS   }
  validates :period, :hotel, :room, presence: true

  def initialize(period:, hotel:, room:)
    @period = period
    @hotel  = hotel
    @room   = room
  end
end

# app/controllers/api/v1/pricing_controller.rb
def index
  params_vo = PricingParams.new(period: params[:period], hotel: params[:hotel], room: params[:room])
  unless params_vo.valid?
    return render json: { error: params_vo.errors.full_messages.join(', ') }, status: :bad_request
  end
  service = Api::V1::PricingService.new(period: params_vo.period, hotel: params_vo.hotel, room: params_vo.room)
  # ...
end
```

Remove the `before_action :validate_params` and `validate_params` method entirely. The `PricingConstants` include moves to `PricingParams`.

---

## Summary Table

| ID | Pattern Category | Finding | Importance |
|----|-----------------|---------|------------|
| F1 | Structural (Adapter / Strategy) | No interface contract for injectable `client:` | 6 / 10 |
| F2 | Domain (Repository) | Cache read/write logic inline in `PricingService` | 7 / 10 |
| F3 | Creational (Singleton/Factory) | `RateApiClient` all-class-methods prevents per-instance config | 5 / 10 |
| F4 | Domain (Service Layer) | `attr_accessor :result` allows external mutation | 4 / 10 |
| F5 | Structural (Adapter) | Network exceptions not rescued in `RateApiClient` | 7 / 10 |
| F6 | Domain (DTO/Value Object) | Param validation inline in controller, not a Value Object | 5 / 10 |

### Patterns used correctly (no action needed)

| Pattern | Location |
|---------|----------|
| Adapter | `RateApiClient` wrapping HTTParty |
| Facade | `PricingService` over Redis + `RateApiClient` |
| Caching Proxy | `PricingService#run` cache-then-fetch |
| Value Object | `RateApiClient::Result` Struct |
| Service Layer | `BaseService` + `PricingService` |
| Chain of Responsibility | `before_action :validate_params` |

### Patterns evaluated as not needed

| Pattern | Rationale |
|---------|-----------|
| Singleton (hand-rolled) | `Rails.cache` covers it; no other shared state |
| Factory / Builder | Object construction is trivial |
| Observer / Event Bus | No side-effects or cross-cutting event needs |
| Command (job queue) | Synchronous proxy; no async requirement |
| Domain Model | No persistent entities in a pure proxy service |
