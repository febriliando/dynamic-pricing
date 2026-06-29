class BaseService
  attr_reader :result

  def valid?          = errors.blank?
  def upstream_error? = @upstream_error || false

  def errors
    @errors ||= []
  end

  protected

  def add_upstream_error(message)
    @upstream_error = true
    errors << message
  end
end
