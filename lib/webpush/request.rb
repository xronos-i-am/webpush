# frozen_string_literal: true

require 'jwt'
require 'base64'

module Webpush
  # rubocop:disable Metrics/ClassLength
  class Request
    def initialize(message: '', subscription:, vapid:, **options)
      endpoint = subscription.fetch(:endpoint)
      @endpoint = endpoint
      @payload = build_payload(message, subscription)
      @vapid_options = vapid
      @options = default_options.merge(options)
    end

    # rubocop:disable Metrics/AbcSize
    def perform
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.ssl_timeout = @options[:ssl_timeout] unless @options[:ssl_timeout].nil?
      http.open_timeout = @options[:open_timeout] unless @options[:open_timeout].nil?
      http.read_timeout = @options[:read_timeout] unless @options[:read_timeout].nil?

      req = Net::HTTP::Post.new(uri.request_uri, headers)
      req.body = body
      resp = http.request(req)
      verify_response(resp)

      resp
    end
    # rubocop:enable Metrics/AbcSize

    # rubocop:disable Metrics/MethodLength
    def headers
      headers = {}
      headers['Content-Type'] = 'application/octet-stream'
      headers['Ttl']          = ttl
      headers['Urgency']      = urgency

      if @payload.key?(:server_public_key)
        headers['Content-Encoding'] = 'aesgcm'
        headers['Encryption'] = "salt=#{salt_param}"
        headers['Crypto-Key'] = "dh=#{dh_param}"
      end

      if api_key?
        headers['Authorization'] = "key=#{api_key}"
      elsif vapid?
        vapid_headers = build_vapid_headers
        headers['Authorization'] = vapid_headers['Authorization']
        headers['Crypto-Key'] = [headers['Crypto-Key'], vapid_headers['Crypto-Key']].compact.join(';')
      end

      headers
    end
    # rubocop:enable Metrics/MethodLength

    def build_vapid_headers
      vapid_key = vapid_pem ? VapidKey.from_pem(vapid_pem) : VapidKey.from_keys(vapid_public_key, vapid_private_key)
      jwt = JWT.encode(jwt_payload, vapid_key.curve, 'ES256', jwt_header_fields)
      p256ecdsa = vapid_key.public_key_for_push_header

      {
        'Authorization' => 'WebPush ' + jwt,
        'Crypto-Key' => 'p256ecdsa=' + p256ecdsa
      }
    end

    def body
      @payload.fetch(:ciphertext, '')
    end

    private

    def uri
      @uri ||= URI.parse(@endpoint)
    end

    def ttl
      @options.fetch(:ttl).to_s
    end

    def urgency
      @options.fetch(:urgency).to_s
    end

    def dh_param
      trim_encode64(@payload.fetch(:server_public_key))
    end

    def salt_param
      trim_encode64(@payload.fetch(:salt))
    end

    def jwt_payload
      {
        aud: audience,
        exp: Time.now.to_i + expiration,
        sub: subject
      }
    end

    def jwt_header_fields
      { 'typ' => 'JWT' }
    end

    def audience
      uri.scheme + '://' + uri.host
    end

    def expiration
      @vapid_options.fetch(:expiration, 24 * 60 * 60)
    end

    def subject
      @vapid_options.fetch(:subject, 'sender@example.com')
    end

    def vapid_public_key
      @vapid_options.fetch(:public_key, nil)
    end

    def vapid_private_key
      @vapid_options.fetch(:private_key, nil)
    end

    def vapid_pem
      @vapid_options.fetch(:pem, nil)
    end

    def default_options
      {
        ttl: 60 * 60 * 24 * 7 * 4, # 4 weeks
        urgency: 'normal'
      }
    end

    def build_payload(message, subscription)
      return {} if message.nil? || message.empty?

      encrypt_payload(message, subscription.fetch(:keys))
    end

    def encrypt_payload(message, p256dh:, auth:)
      Encryption.encrypt(message, p256dh, auth)
    end

    def api_key
      @options.fetch(:api_key, nil)
    end

    def api_key?
      !(api_key.nil? || api_key.empty?) && @endpoint =~ %r{\Ahttps://(android|gcm-http|fcm)\.googleapis\.com}
    end

    def vapid?
      @vapid_options.any?
    end

    def trim_encode64(bin)
      Webpush.encode64(bin).delete('=')
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/GuardClause
    def verify_response(resp)
      if resp.is_a?(Net::HTTPGone) # 410
        raise ExpiredSubscription.new(resp, uri.host)
      elsif resp.is_a?(Net::HTTPNotFound) # 404
        raise InvalidSubscription.new(resp, uri.host)
      elsif resp.is_a?(Net::HTTPUnauthorized) || resp.is_a?(Net::HTTPForbidden) || # 401, 403
            resp.is_a?(Net::HTTPBadRequest) && resp.message == 'UnauthorizedRegistration' # 400, Google FCM
        raise Unauthorized.new(resp, uri.host)
      elsif resp.is_a?(Net::HTTPRequestEntityTooLarge) # 413
        raise PayloadTooLarge.new(resp, uri.host)
      elsif resp.is_a?(Net::HTTPTooManyRequests) # 429, try again later!
        raise TooManyRequests.new(resp, uri.host)
      elsif resp.is_a?(Net::HTTPServerError) # 5xx
        raise PushServiceError.new(resp, uri.host)
      elsif !resp.is_a?(Net::HTTPSuccess) # unknown/unhandled response error
        raise ResponseError.new(resp, uri.host)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Style/GuardClause
  end
  # rubocop:enable Metrics/ClassLength
end
