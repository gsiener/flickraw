require 'openssl'
require 'net/http'

module FlickRaw
  class OAuthClient
    class UnknownSignatureMethod < StandardError; end
    class FailedResponse < StandardError
      def initialize(str)
        @response = OAuthClient.parse_response(str)
        super(@response['oauth_problem'])
      end
    end
  
    class << self
      def escape(v); URI.escape(v.to_s, /[^a-zA-Z0-9\-\.\_\~]/) end
      def parse_response(text); Hash[text.split("&").map {|s| s.split("=")}] end
      
      def signature_base_string(method, url, params)
        params_norm = params.map {|k,v| escape(k) + "=" + escape(v)}.sort.join("&")
        method.to_s.upcase + "&" + escape(url) + "&" + escape(params_norm)
      end
      
      def sign_plaintext(method, url, params, token_secret, consumer_secret)
        escape(consumer_secret) + "&" + escape(token_secret)
      end
        
      def sign_rsa_sha1(method, url, params, token_secret, consumer_secret)
        text = signature_base_string(method, url, params)
        key = OpenSSL::PKey::RSA.new(consumer_secret)
        digest = OpenSSL::Digest::Digest.new("sha1")
        [key.sign(digest, text)].pack('m0').gsub(/\n$/,'')
      end
            
      def sign_hmac_sha1(method, url, params, token_secret, consumer_secret)
        text = signature_base_string(method, url, params)
        key = escape(consumer_secret) + "&" + escape(token_secret)
        digest = OpenSSL::Digest::Digest.new("sha1")
        [OpenSSL::HMAC.digest(digest, key, text)].pack('m0').gsub(/\n$/,'')
      end
    
      def gen_timestamp; Time.now.to_i end
      def gen_nonce; [OpenSSL::Random.random_bytes(32)].pack('m0').gsub(/\n$/,'') end
      def gen_default_params
        { :oauth_version => "1.0", :oauth_signature_method => "HMAC-SHA1",
          :oauth_nonce => gen_nonce, :oauth_timestamp => gen_timestamp }
      end
    
      def authorization_header(url, params)
        params_norm = params.map {|k,v| %(#{escape(k)}="#{escape(v)}")}.sort.join(", ")
        %(OAuth realm="#{url.to_s}", #{params_norm})
      end
    end
    
    attr_accessor :user_agent
    attr_reader :proxy
    def proxy=(url); @proxy = URI.parse(url || '') end
    
    def initialize(consumer_key, consumer_secret)
      @consumer_key, @consumer_secret = consumer_key, consumer_secret
      self.proxy = nil
    end

    def request_token(url, oauth_params = {})
      r = post_form(url, nil, {:oauth_callback => "oob"}.merge(oauth_params))
      OAuthClient.parse_response(r.body)
    end
    
    def authorize_url(url, oauth_params = {})
      params_norm = oauth_params.map {|k,v| OAuthClient.escape(k) + "=" + OAuthClient.escape(v)}.sort.join("&")
      url =  URI.parse(url)
      url.query = url.query ? url.query + "&" + params_norm : params_norm
      url.to_s
    end
    
    def access_token(url, token_secret, oauth_params = {})
      r = post_form(url, token_secret, oauth_params)
      OAuthClient.parse_response(r.body)
    end

    def post_form(url, token_secret, oauth_params = {}, params = {})
      post(url, token_secret, oauth_params, params) {|request| request.form_data = params}
    end
    
    def post_multipart(url, token_secret, oauth_params = {}, params = {})
      post(url, token_secret, oauth_params, params) {|request|
        boundary = "FlickRaw#{OAuthClient.gen_nonce}"
        request['Content-type'] = "multipart/form-data, boundary=#{boundary}"

        request.body = ''
        params.each { |k, v|
          if v.is_a? File
            basename = File.basename(v.path).to_s
            basename = basename.encode("utf-8").force_encoding("ascii-8bit") if RUBY_VERSION >= "1.9"
            filename = basename
            request.body << "--#{boundary}\r\n" <<
              "Content-Disposition: form-data; name=\"#{k}\"; filename=\"#{filename}\"\r\n" <<
              "Content-Transfer-Encoding: binary\r\n" <<
              "Content-Type: image/jpeg\r\n\r\n" <<
              v.read << "\r\n"
          else
            request.body << "--#{boundary}\r\n" <<
              "Content-Disposition: form-data; name=\"#{k}\"\r\n\r\n" <<
              "#{v}\r\n"
          end
        }
        
        request.body << "--#{boundary}--"
      }
    end

    private
    def sign(method, url, params, token_secret = nil)
      case params[:oauth_signature_method]
      when "HMAC-SHA1"
        OAuthClient.sign_hmac_sha1(method, url, params, token_secret, @consumer_secret)
      when "RSA-SHA1"
        OAuthClient.sign_rsa_sha1(method, url, params, token_secret, @consumer_secret)
      when "PLAINTEXT"
        OAuthClient.sign_plaintext(method, url, params, token_secret, @consumer_secret)
      else
        raise UnknownSignatureMethod, params[:oauth_signature_method]
      end
    end

    def post(url, token_secret, oauth_params, params)
      url = URI.parse(url)
      default_oauth_params = OAuthClient.gen_default_params
      default_oauth_params[:oauth_consumer_key] = @consumer_key
      default_oauth_params[:oauth_signature_method] = "PLAINTEXT" if url.scheme == 'https'
      oauth_params = default_oauth_params.merge(oauth_params)
      params_signed = params.reject {|k,v| v.is_a? File}.merge(oauth_params)
      oauth_params[:oauth_signature] = sign(:post, url, params_signed, token_secret)

      r = Net::HTTP.start(url.host, url.port,
          @proxy.host, @proxy.port, @proxy.user, @proxy.password,
          :use_ssl => url.scheme == 'https') { |http| 
        request = Net::HTTP::Post.new(url.path)
        request['User-Agent'] = @user_agent if @user_agent
        request['Authorization'] = OAuthClient.authorization_header(url, oauth_params)

        yield request
        http.request(request)
      }
      
      raise FailedResponse.new(r.body) if r.is_a? Net::HTTPClientError
      r
    end
  end

end