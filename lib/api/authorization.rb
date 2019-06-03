require 'excon'

class CustomWizard::Api::Authorization
  include ActiveModel::SerializerSupport

  attr_accessor :api_name,
                :authorized,
                :auth_type,
                :auth_url,
                :token_url,
                :client_id,
                :client_secret,
                :auth_params,
                :access_token,
                :refresh_token,
                :token_expires_at,
                :token_refresh_at,
                :code,
                :username,
                :password

  def initialize(api_name, data={})
    @api_name = api_name

    data.each do |k, v|
      self.send "#{k}=", v if self.respond_to?(k)
    end
  end

  def authorized
    @authorized ||= @access_token && @token_expires_at.to_datetime > Time.now
  end

  def self.set(api_name, new_data = {})
    data = self.get(api_name, data_only: true) || {}

    new_data.each do |k, v|
      data[k.to_sym] = v
    end

    PluginStore.set("custom_wizard_api_#{api_name}", 'authorization', data)

    self.get(api_name)
  end

  def self.get(api_name, opts = {})
    if data = PluginStore.get("custom_wizard_api_#{api_name}", 'authorization')
      if opts[:data_only]
        data
      else
        self.new(api_name, data)
      end
    else
      nil
    end
  end

  def self.remove(api_name)
    PluginStore.remove("custom_wizard_api_#{api_name}", "authorization")
  end

  def self.get_header_authorization_string(name)
    protocol = authentication_protocol(name)
    raise Discourse::InvalidParameters.new(:name) unless protocol.present?
    raise Discourse::InvalidParameters.new(:protocol) unless [BASIC_AUTH, OAUTH2_AUTH].include? protocol

    if protocol = BASIC_AUTH
      username = username(name)
      raise Discourse::InvalidParameters.new(:username) unless username.present?
      password = password(name)
      raise Discourse::InvalidParameters.new(:password) unless password.present?
      authorization_string = (username + ":" + password).chomp
      "Basic #{Base64.strict_encode64(authorization_string)}"
    else
      # must be OAUTH2
      access_token = access_token(name)
      raise Discourse::InvalidParameters.new(access_token) unless access_token.present?
      "Bearer #{access_token}"
    end
  end

  def self.get_token(name)
    authorization = CustomWizard::Api::Authorization.get(name)

    body = {
      client_id: authorization.client_id,
      client_secret: authorization.client_secret,
      code: authorization.code,
      grant_type: 'authorization_code',
      redirect_uri: Discourse.base_url + "/admin/wizards/apis/#{name}/redirect"
    }

    result = Excon.post(
      authorization.token_url,
      :headers => {
        "Content-Type" => "application/x-www-form-urlencoded"
      },
      :body => URI.encode_www_form(body)
    )

    self.handle_token_result(name, result)
  end

  def self.refresh_token(name)
    authorization = CustomWizard::Api::Authorization.get(name)

    body = {
      grant_type: 'refresh_token',
      refresh_token: authorization.refresh_token
    }

    authorization_string = authorization.client_id + ':' + authorization.client_secret

    result = Excon.post(
      authorization.token_url,
      :headers => {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Authorization" => "Basic #{Base64.strict_encode64(authorization_string)}"
      },
      :body => URI.encode_www_form(body)
    )

    self.handle_token_result(name, result)
  end

  def self.handle_token_result(name, result)
    data = JSON.parse(result.body)

    return false if (data['error'])

    access_token = data['access_token']
    refresh_token = data['refresh_token']
    expires_at = Time.now + data['expires_in'].seconds
    refresh_at = expires_at.to_time - 2.hours

    opts = {
      name: name
    }

    Jobs.enqueue_at(refresh_at, :refresh_api_access_token, opts)

    CustomWizard::Api::Authorization.set(name,
      access_token: access_token,
      refresh_token: refresh_token,
      token_expires_at: expires_at,
      token_refresh_at: refresh_at
    )
  end
end
