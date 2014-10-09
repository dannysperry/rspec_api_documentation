require 'faraday'

Faraday::Request.register_middleware :request_saver => lambda { RspecApiDocumentation::RequestSaver }

module RspecApiDocumentation
  class RequestSaver < Faraday::Middleware
    attr_reader :client

    def initialize(app, client)
      super(app)
      @client = client
    end

    def call(env)
      client.last_request = env

      @app.call(env).on_complete do |env|
        client.last_response = env
      end
    end
  end

  class HttpTestClient < ClientBase
    attr_reader :last_response, :last_request

    LastRequest = Struct.new(:url, :method, :request_headers, :body)

    def request_headers
      env_to_headers(last_request.request_headers)
    end

    def response_headers
      last_response.response_headers
    end

    def query_string
      last_request.url.query
    end

    def status
      last_response.status
    end

    def response_body
      last_response.body
    end

    def request_content_type
      last_request.request_headers["CONTENT_TYPE"]
    end

    def response_content_type
      last_response.request_headers["CONTENT_TYPE"]
    end

    def do_request(method, path, params, request_headers)
      http_test_session.send(method, path, params, headers(method, path, params, request_headers))
    end

    def last_request=(env)
      @last_request = LastRequest.new(env.url, env.method, env.request_headers, env.body)
    end

    def last_response=(env)
      @last_response = env
    end

    protected

    def query_hash(query_string)
      Faraday::Utils.parse_query(query_string)
    end

    def headers(*args)
      headers_to_env(super)
    end

    def handle_multipart_body(request_headers, request_body)
      parsed_parameters = Rack::Request.new({
        "CONTENT_TYPE" => request_headers["Content-Type"],
        "rack.input" => StringIO.new(request_body)
      }).params

      clean_out_uploaded_data(parsed_parameters, request_body)
    end

    def document_example(method, path)
      return unless metadata[:document]

      req_method = last_request.method
      if req_method == :post || req_method == :put
        request_body = last_request.body
      else
        request_body = ""
      end
      request_body = "" unless request_body # could be nil if nothing is sent

      request_metadata = {}

      if request_content_type =~ /multipart\/form-data/ && respond_to?(:handle_multipart_body, true)
        request_body = handle_multipart_body(request_headers, request_body)
      end

      request_metadata[:request_method] = method
      request_metadata[:request_path] = path
      request_metadata[:request_body] = request_body.empty? ? nil : request_body
      request_metadata[:request_headers] = last_request.request_headers
      request_metadata[:request_query_parameters] = query_hash(query_string)
      request_metadata[:request_content_type] = request_content_type
      request_metadata[:response_status] = status
      request_metadata[:response_status_text] = Rack::Utils::HTTP_STATUS_CODES[status]
      request_metadata[:response_body] = response_body.empty? ? nil : response_body
      request_metadata[:response_headers] = response_headers
      request_metadata[:response_content_type] = response_content_type
      request_metadata[:curl] = Curl.new(method, path, request_body, request_headers)

      metadata[:requests] ||= []
      metadata[:requests] << request_metadata
    end

    private

    def clean_out_uploaded_data(params, request_body)
      params.each do |_, value|
        if value.is_a?(Hash)
          if value.has_key?(:tempfile)
            data = value[:tempfile].read
            request_body = request_body.gsub(data, "[uploaded data]")
          else
            request_body = clean_out_uploaded_data(value,request_body)
          end
        end
      end
      request_body
    end


    def http_test_session
      ::Faraday.new(:url => options[:host]) do |faraday|
        faraday.request :url_encoded            # form-encode POST params
        faraday.request :request_saver, self    # save the request and response
        faraday.adapter Faraday.default_adapter # make requests with Net::HTTP
      end
    end
  end
end
