require "test_helper"

class Api::V1::PricingServiceTest < ActiveSupport::TestCase
  PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze
  CACHE_KEY = "Summer/FloatingPointResort/SingletonRoom"

  setup do
    Rails.cache.clear
  end


  test "calls API and returns rate on cache miss" do
    client = mock_client(success: true, value: "15000")

    service = build_service(client: client)
    service.run

    assert service.valid?
    assert_equal "15000", service.result
  end


  test "returns cached rate without calling API on cache hit" do
    Rails.cache.write(CACHE_KEY, "15000", raw: true)

    client = Minitest::Mock.new
    # get_rate should never be called
    service = build_service(client: client)
    service.run

    assert service.valid?
    assert_equal "15000", service.result
    client.verify
  end


  test "does not cache rate when API returns error" do
    client = mock_client(success: false, error: "Service unavailable")

    service = build_service(client: client)
    service.run

    assert_not service.valid?
    assert service.upstream_error?
    assert_includes service.errors, "Service unavailable"
    assert_nil Rails.cache.read(CACHE_KEY, raw: true)
  end

  test "retries API after previous error" do
    error_client = mock_client(success: false, error: "Service unavailable")
    build_service(client: error_client).run

    success_client = mock_client(success: true, value: "15000")
    service = build_service(client: success_client)
    service.run

    assert service.valid?
    assert_equal "15000", service.result
  end


  test "returns rate as string on cache miss" do
    client = mock_client(success: true, value: 15000)

    service = build_service(client: client)
    service.run

    assert_instance_of String, service.result
    assert_equal "15000", service.result
  end

  test "returns rate as string on cache hit" do
    Rails.cache.write(CACHE_KEY, "15000", raw: true)

    service = build_service(client: Minitest::Mock.new)
    service.run

    assert_instance_of String, service.result
  end


  test "writes rate to cache after successful API call" do
    client = mock_client(success: true, value: "15000")

    build_service(client: client).run

    assert_equal "15000", Rails.cache.read(CACHE_KEY, raw: true)
  end

  private

  def build_service(client:)
    Api::V1::PricingService.new(**PARAMS, client: client)
  end

  def mock_client(success:, value: nil, error: nil)
    result = RateApiClient::Result.new(success: success, value: value, error: error)
    client = Minitest::Mock.new
    client.expect(:get_rate, result, [], **PARAMS)
    client
  end
end
