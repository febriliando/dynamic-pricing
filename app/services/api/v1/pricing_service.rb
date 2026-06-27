module Api::V1
  class PricingService < BaseService
    CACHE_TTL = ENV.fetch('RATE_CACHE_TTL', 5).to_i.minutes

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel  = hotel
      @room   = room
    end

    def run
      cached = Rails.cache.read(cache_key, raw: true)
      return @result = cached if cached

      result = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)
      if result.success?
        @result = result.value.to_s
        Rails.cache.write(cache_key, @result, expires_in: CACHE_TTL, raw: true)
      else
        errors << result.error
      end
    end

    private

    def cache_key
      "#{@period}/#{@hotel}/#{@room}"
    end
  end
end
