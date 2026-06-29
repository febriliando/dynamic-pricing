module Api::V1
  class PricingService < BaseService
    CACHE_TTL = ENV.fetch('RATE_CACHE_TTL', 5).to_i.minutes

    def initialize(period:, hotel:, room:, client: RateApiClient)
      @period = period
      @hotel  = hotel
      @room   = room
      @client = client
    end

    def run
      cached = Rails.cache.read(cache_key, raw: true)
      return @result = cached if cached

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = @client.get_rate(period: @period, hotel: @hotel, room: @room)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

      if result.success?
        Rails.logger.info "event=api_success key=#{cache_key} duration_ms=#{duration_ms}"
        @result = result.value.to_s
        Rails.cache.write(cache_key, @result, expires_in: CACHE_TTL, raw: true)
      else
        Rails.logger.warn "event=api_failure key=#{cache_key} error=#{result.error.inspect} duration_ms=#{duration_ms}"
        add_upstream_error(result.error)
      end
    end

    private

    def cache_key
      "#{@period}/#{@hotel}/#{@room}"
    end
  end
end
