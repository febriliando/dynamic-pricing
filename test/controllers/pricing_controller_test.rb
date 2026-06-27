require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  # --- success ---

  test "should get pricing with all parameters" do
    mock_result = RateApiClient::Result.new(success: true, value: "15000")

    RateApiClient.stub(:get_rate, mock_result) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :success
      assert_equal "application/json", @response.media_type
      assert_equal "15000", JSON.parse(@response.body)["rate"]
    end
  end

  # --- upstream errors ---

  test "should return error when rate API fails" do
    mock_result = RateApiClient::Result.new(success: false, error: "Rate not found")

    RateApiClient.stub(:get_rate, mock_result) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :bad_request
      assert_includes JSON.parse(@response.body)["error"], "Rate not found"
    end
  end

  # --- param validation ---

  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get api_v1_pricing_url, params: { period: "", hotel: "", room: "" }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    assert_includes JSON.parse(@response.body)["error"], "Invalid room"
  end
end
