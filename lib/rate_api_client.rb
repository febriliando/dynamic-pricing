class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  default_timeout ENV.fetch('RATE_API_TIMEOUT', 5).to_i

  Result = Struct.new(:success, :value, :error, keyword_init: true) do
    def success? = success
  end

  def self.get_rate(period:, hotel:, room:)
    response = post("/pricing", body: build_body(period, hotel, room))

    unless response.success?
      error = response.parsed_response&.dig('error') || "HTTP #{response.code}"
      return Result.new(success: false, error: error)
    end

    rate = JSON.parse(response.body)['rates']
             &.detect { |r| r['period'] == period && r['hotel'] == hotel && r['room'] == room }
             &.dig('rate')

    if rate
      Result.new(success: true, value: rate)
    else
      Result.new(success: false, error: 'Rate not found for the given parameters')
    end
  end

  private_class_method def self.build_body(period, hotel, room)
    { attributes: [{ period: period, hotel: hotel, room: room }] }.to_json
  end
end
