module Pushy
  class Handler

    attr_reader :received

    def on_readable(socket, parts)
      if valid?(parts[0].copy_out_string)
        parse_json parts[1].copy_out_string
      end
    end

    private

    def valid?(auth)
      true
    end

    def parse_json(json)
      parser = Yajl::Parser.new
      hash = parser.parse(json)

      puts hash['type']
      puts hash['host']
    end

  end
end
