module AhoyEmail
  class Processor
    attr_reader :mailer, :options

    UTM_PARAMETERS = %w(utm_source utm_medium utm_term utm_content utm_campaign)

    def initialize(mailer, options)
      @mailer = mailer
      @options = options

      unknown_keywords = options.keys - AhoyEmail.default_options.keys
      raise ArgumentError, "unknown keywords: #{unknown_keywords.join(", ")}" if unknown_keywords.any?
    end

    def perform
      track_open if options[:open]
      track_links if options[:utm_params] || options[:click] || options[:url_params]
      track_message
    end

    protected

    def message
      mailer.message
    end

    def token
      @token ||= SecureRandom.urlsafe_base64(32).gsub(/[\-_]/, "").first(32)
    end

    def track_message
      data = {
        mailer: options[:mailer],
        extra: options[:extra],
        user: options[:user]
      }

      # legacy, remove in next major version
      user = options[:user]
      if user
        data[:user_type] = user.model_name.name
        id = user.id
        data[:user_id] = id.is_a?(Integer) ? id : id.to_s
      end

      if options[:open] || options[:click]
        data[:token] = token
      end

      if options[:utm_params]
        UTM_PARAMETERS.map(&:to_sym).each do |k|
          data[k] = options[k] if options[k]
        end
      end

      if options[:url_params].present?
        options[:url_params].each do |k, v|
          next if data.has_key?(k) # 이미 정의 된 파라미터의 경우 무시
          data[k] = v if v.present?
        end
      end

      mailer.message.ahoy_data = data
    end

    def track_open
      if html_part?
        part = message.html_part || message
        raw_source = part.body.raw_source

        regex = /<body>/i
        trackable_regex = /<trackable>/i
        url =
          url_for(
            controller: "ahoy/messages",
            action: "open",
            id: token,
            format: "gif"
          )
        pixel = ActionController::Base.helpers.image_tag(url, size: "1x1", alt: "")

        # try to add before body tag
        if raw_source.match(trackable_regex)
          part.body = raw_source.gsub(trackable_regex, "\\0#{pixel}")
        elsif raw_source.match(regex)
          part.body = raw_source.gsub(regex, "\\0#{pixel}")
        else
          part.body = pixel + raw_source
        end
      end
    end

    def track_links
      if html_part?
        part = message.html_part || message

        # TODO use Nokogiri::HTML::DocumentFragment.parse in 2.0
        doc = Nokogiri::HTML(part.body.raw_source)
        doc.css("a[href]").each do |link|
          uri = parse_uri(link["href"])
          next unless trackable?(uri)
          # utm params first
          if options[:utm_params] && !skip_attribute?(link, "utm-params")
            params = uri.query_values(Array) || []
            UTM_PARAMETERS.each do |key|
              next if params.any? { |k, _v| k == key } || !options[key.to_sym]
              params << [key, options[key.to_sym]]
            end
            uri.query_values = params
            link["href"] = uri.to_s
          end

          if options[:url_params].present? && !skip_attribute?(link, "tag-params")
            params = uri.query_values(Array) || []
            options[:url_params].each do |key, value|
              next if params.any? { |k, _v| k == key } || value.blank?
              params << [key, value]
            end
            uri.query_values = params
            link["href"] = uri.to_s
          end

          if options[:click] && !skip_attribute?(link, "click")
            raise "Secret token is empty" unless AhoyEmail.secret_token

            # TODO sign more than just url and transition to HMAC-SHA256
            signature = OpenSSL::HMAC.hexdigest("SHA1", AhoyEmail.secret_token, link["href"])
            link["href"] =
              url_for(
                controller: "ahoy/messages",
                action: "click",
                id: token,
                url: link["href"],
                signature: signature
              )
          end
        end

        # ampersands converted to &amp;
        # https://github.com/sparklemotion/nokogiri/issues/1127
        # not ideal, but should be equivalent in html5
        # https://stackoverflow.com/questions/15776556/whats-the-difference-between-and-amp-in-html5
        # escaping technically required before html5
        # https://stackoverflow.com/questions/3705591/do-i-encode-ampersands-in-a-href
        part.body = doc.to_s
      end
    end

    def html_part?
      (message.html_part || message).content_type =~ /html/
    end

    def skip_attribute?(link, suffix)
      attribute = "data-skip-#{suffix}"
      if link[attribute]
        # remove it
        link.remove_attribute(attribute)
        true
      elsif link["href"].to_s =~ /unsubscribe/i && !options[:unsubscribe_links]
        # try to avoid unsubscribe links
        true
      else
        false
      end
    end

    # Filter trackable URIs, i.e. absolute one with http
    def trackable?(uri)
      uri && uri.absolute? && %w(http https).include?(uri.scheme)
    end

    # Parse href attribute
    # Return uri if valid, nil otherwise
    def parse_uri(href)
      # to_s prevent to return nil from this method
      Addressable::URI.heuristic_parse(href.to_s) rescue nil
    end

    def url_for(opt)
      opt = (ActionMailer::Base.default_url_options || {})
            .merge(options[:url_options])
            .merge(opt)
      AhoyEmail::Engine.routes.url_helpers.url_for(opt)
    end
  end
end
