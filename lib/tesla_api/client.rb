module TeslaApi
  class Client
    attr_reader :api, :email, :access_token, :access_token_expires_at, :refresh_token, :client_id, :client_secret

    BASE_URI = 'https://owner-api.teslamotors.com'
    SSO_URI = 'https://auth.tesla.com'

    def initialize(
        email: nil,
        access_token: nil,
        access_token_expires_at: nil,
        refresh_token: nil,
        client_id: ENV['TESLA_CLIENT_ID'],
        client_secret: ENV['TESLA_CLIENT_SECRET'],
        retry_options: nil,
        base_uri: nil,
        sso_uri: nil,
        client_options: {}
    )
      @email = email
      @base_uri = base_uri || BASE_URI
      @sso_uri = sso_uri || SSO_URI

      @client_id = client_id
      @client_secret = client_secret

      @access_token = access_token
      @access_token_expires_at = access_token_expires_at
      @refresh_token = refresh_token

      @api = Faraday.new(
        @base_uri + '/api/1',
        {
          headers: { 'User-Agent' => "github.com/timdorr/tesla-api v:#{VERSION}" }
        }.merge(client_options)
      ) do |conn|
        conn.request :json
        conn.response :json
        conn.response :raise_error
        conn.request :retry, retry_options if retry_options # Must be registered after :raise_error
        conn.adapter Faraday.default_adapter
      end
    end

    def refresh_access_token
      return response = @api.post(
        @sso_uri + '/oauth2/v3/token',
        {
          grant_type: 'refresh_token',
          scope: 'openid email offline_access',
          client_id: 'ownerapi',
          client_secret: client_secret,
          refresh_token: refresh_token
        }
      )

      @refresh_token = response['refresh_token']

      response = api.post(
        @base_uri + '/oauth/token',
        {
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          client_id: client_id,
          client_secret: client_secret
        },
        'Authorization' => "Bearer #{response['access_token']}"
      ).body

      @access_token = response['access_token']
      @access_token_expires_at = Time.at(response['created_at'].to_f + response['expires_in'].to_f).to_datetime

      response
    end

    def login!(password)
      code_verifier = rand(36**86).to_s(36)
      code_challenge = Base64.urlsafe_encode64(Digest::SHA256.hexdigest(code_verifier))
      state = rand(36**20).to_s(36)

      response = Faraday.get(
        @sso_uri + '/oauth2/v3/authorize',
        {
          client_id: 'ownerapi',
          code_challenge: code_challenge,
          code_challenge_method: 'S256',
          redirect_uri: 'https://auth.tesla.com/void/callback',
          response_type: 'code',
          scope: 'openid email offline_access',
          state: state,
        }
      )

      cookie = response.headers['set-cookie'].split(' ').first
      parameters = Hash[response.body.scan(/type="hidden" name="(.*?)" value="(.*?)"/)]

      response = Faraday.post(
        @sso_uri + '/oauth2/v3/authorize?' + URI.encode_www_form({
          client_id: 'ownerapi',
          code_challenge: code_challenge,
          code_challenge_method: 'S256',
          redirect_uri: 'https://auth.tesla.com/void/callback',
          response_type: 'code',
          scope: 'openid email offline_access',
          state: state,
        }),
        URI.encode_www_form(parameters.merge(
          'identity' => email,
          'credential' => password
        )),
        'Cookie' => cookie
      )

      code = CGI.parse(URI(response.headers['location']).query)['code'].first

      response = @api.post(
        @sso_uri + '/oauth2/v3/token',
        {
          grant_type: 'authorization_code',
          client_id: 'ownerapi',
          code: code,
          code_verifier: code_verifier,
          redirect_uri: 'https://auth.tesla.com/void/callback'
        }
      ).body

      @refresh_token = response['refresh_token']

      response = api.post(
        @base_uri + '/oauth/token',
        {
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          client_id: client_id,
          client_secret: client_secret
        },
        'Authorization' => "Bearer #{response['access_token']}"
      ).body

      @access_token = response['access_token']
      @access_token_expires_at = Time.at(response['created_at'].to_f + response['expires_in'].to_f).to_datetime

      response
    end

    def expired?
      return true if access_token_expires_at.nil?
      access_token_expires_at <= DateTime.now
    end

    def get(url)
      api.get(url.sub(/^\//, ''), nil, { 'Authorization' => "Bearer #{access_token}" }).body
    end

    def post(url, body: nil)
      api.post(url.sub(/^\//, ''), body, { 'Authorization' => "Bearer #{access_token}" }).body
    end

    def vehicles
      get('/vehicles')['response'].map { |v| Vehicle.new(self, email, v['id'], v) }
    end

    def vehicle(id)
      Vehicle.new(self, email, id, self.get("/vehicles/#{id}")['response'])
    end
  end
end
