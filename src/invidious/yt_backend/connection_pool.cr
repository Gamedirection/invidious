{% unless flag?(:disable_quic) %}
  require "lsquic"

  alias HTTPClientType = QUIC::Client | HTTP::Client
{% else %}
  alias HTTPClientType = HTTP::Client
{% end %}

def add_yt_headers(request)
  if request.headers["User-Agent"] == "Crystal"
    request.headers["User-Agent"] ||= "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"
  end

  request.headers["Accept-Charset"] ||= "ISO-8859-1,utf-8;q=0.7,*;q=0.7"
  request.headers["Accept"] ||= "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  request.headers["Accept-Language"] ||= "en-us,en;q=0.5"
  # Preserve original cookies and add new YT consent cookie for EU servers
  request.headers["Cookie"] = "#{request.headers["cookie"]?}; CONSENT=YES+"
  if !CONFIG.cookies.empty?
    request.headers["Cookie"] = "#{(CONFIG.cookies.map { |c| "#{c.name}=#{c.value}" }).join("; ")}; #{request.headers["cookie"]?}"
  end
end

struct YoutubeConnectionPool
  property! url : URI
  property! capacity : Int32
  property! timeout : Float64
  property pool : DB::Pool(HTTPClientType)

  def initialize(url : URI, @capacity = 5, @timeout = 5.0, use_quic = true)
    @url = url
    @pool = build_pool(use_quic)
  end

  def client(region = nil, &block)
    if region
      conn = make_client(url, region)
      response = yield conn
    else
      conn = pool.checkout
      begin
        response = yield conn
      rescue ex
        conn.close
        {% unless flag?(:disable_quic) %}
          conn = CONFIG.use_quic ? QUIC::Client.new(url) : HTTP::Client.new(url)
        {% else %}
          conn = HTTP::Client.new(url)
        {% end %}

        conn.family = (url.host == "www.youtube.com") ? CONFIG.force_resolve : Socket::Family::INET
        conn.family = Socket::Family::INET if conn.family == Socket::Family::UNSPEC
        conn.before_request { |r| add_yt_headers(r) } if url.host == "www.youtube.com"
        response = yield conn
      ensure
        pool.release(conn)
      end
    end

    response
  end

  private def build_pool(use_quic)
    DB::Pool(HTTPClientType).new(initial_pool_size: 0, max_pool_size: capacity, max_idle_pool_size: capacity, checkout_timeout: timeout) do
      conn = nil # Declare
      {% unless flag?(:disable_quic) %}
        if use_quic
          conn = QUIC::Client.new(url)
        else
          conn = HTTP::Client.new(url)
        end
      {% else %}
        conn = HTTP::Client.new(url)
      {% end %}

      conn.family = (url.host == "www.youtube.com") ? CONFIG.force_resolve : Socket::Family::INET
      conn.family = Socket::Family::INET if conn.family == Socket::Family::UNSPEC
      conn.before_request { |r| add_yt_headers(r) } if url.host == "www.youtube.com"
      conn
    end
  end
end

def make_client(url : URI, region = nil)
  # TODO: Migrate any applicable endpoints to QUIC
  client = HTTPClient.new(url, OpenSSL::SSL::Context::Client.insecure)
  client.family = (url.host == "www.youtube.com") ? CONFIG.force_resolve : Socket::Family::UNSPEC
  client.before_request { |r| add_yt_headers(r) } if url.host == "www.youtube.com"
  client.read_timeout = 10.seconds
  client.connect_timeout = 10.seconds

  if region
    PROXY_LIST[region]?.try &.sample(40).each do |proxy|
      begin
        proxy = HTTPProxy.new(proxy_host: proxy[:ip], proxy_port: proxy[:port])
        client.set_proxy(proxy)
        break
      rescue ex
      end
    end
  end

  return client
end

def make_client(url : URI, region = nil, &block)
  client = make_client(url, region)
  begin
    yield client
  ensure
    client.close
  end
end
