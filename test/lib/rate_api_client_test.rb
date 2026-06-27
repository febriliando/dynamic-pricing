require "test_helper"

class RateApiClientTest < ActiveSupport::TestCase
  PERIOD = "Summer"
  HOTEL  = "FloatingPointResort"
  ROOM   = "SingletonRoom"

  # --- Result struct ---

  test "Result is successful when success is true" do
    result = RateApiClient::Result.new(success: true, value: "15000")
    assert result.success?
    assert_equal "15000", result.value
    assert_nil result.error
  end

  test "Result is not successful when success is false" do
    result = RateApiClient::Result.new(success: false, error: "Something went wrong")
    assert_not result.success?
    assert_nil result.value
    assert_equal "Something went wrong", result.error
  end

  # --- get_rate: success ---

  test "returns successful Result with rate value on API success" do
    body = {
      "rates" => [
        { "period" => PERIOD, "hotel" => HOTEL, "room" => ROOM, "rate" => "15000" }
      ]
    }.to_json

    stub_response(success: true, body: body) do
      result = RateApiClient.get_rate(period: PERIOD, hotel: HOTEL, room: ROOM)

      assert result.success?
      assert_equal "15000", result.value
      assert_nil result.error
    end
  end

  test "returns successful Result when multiple rates are present" do
    body = {
      "rates" => [
        { "period" => "Winter", "hotel" => HOTEL, "room" => ROOM, "rate" => "9000" },
        { "period" => PERIOD,   "hotel" => HOTEL, "room" => ROOM, "rate" => "15000" }
      ]
    }.to_json

    stub_response(success: true, body: body) do
      result = RateApiClient.get_rate(period: PERIOD, hotel: HOTEL, room: ROOM)

      assert result.success?
      assert_equal "15000", result.value
    end
  end

  # --- get_rate: rate not found in response ---

  test "returns failure Result when rate is not found in response" do
    body = { "rates" => [] }.to_json

    stub_response(success: true, body: body) do
      result = RateApiClient.get_rate(period: PERIOD, hotel: HOTEL, room: ROOM)

      assert_not result.success?
      assert_equal "Rate not found for the given parameters", result.error
      assert_nil result.value
    end
  end

  test "returns failure Result when rates key is missing" do
    body = {}.to_json

    stub_response(success: true, body: body) do
      result = RateApiClient.get_rate(period: PERIOD, hotel: HOTEL, room: ROOM)

      assert_not result.success?
      assert_equal "Rate not found for the given parameters", result.error
    end
  end

  # --- get_rate: API errors ---

  test "returns failure Result with error message when API returns error" do
    error_body = { "error" => "Unauthorized" }.to_json

    stub_response(success: false, body: error_body, code: 401) do
      result = RateApiClient.get_rate(period: PERIOD, hotel: HOTEL, room: ROOM)

      assert_not result.success?
      assert_equal "Unauthorized", result.error
      assert_nil result.value
    end
  end

  test "returns failure Result with HTTP status fallback when error body has no message" do
    stub_response(success: false, body: {}.to_json, code: 500) do
      result = RateApiClient.get_rate(period: PERIOD, hotel: HOTEL, room: ROOM)

      assert_not result.success?
      assert_equal "HTTP 500", result.error
    end
  end

  private

  def stub_response(success:, body:, code: 200)
    parsed = JSON.parse(body) rescue nil
    response = OpenStruct.new(
      success?: success,
      body: body,
      parsed_response: parsed,
      code: code
    )

    RateApiClient.stub(:post, response) { yield }
  end
end
