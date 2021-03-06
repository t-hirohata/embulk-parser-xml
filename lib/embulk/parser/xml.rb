require "nokogiri"

module Embulk
  module Parser

    class XmlParserPlugin < ParserPlugin
      Plugin.register_parser("xml", self)

      def self.transaction(config, &control)
        schema = config.param("schema", :array)
        schema_serialized = schema.inject({}) do |memo, s|
          memo[s["name"]] = {"type" => s["type"]}
          if s["type"] == "timestamp"
            memo[s["name"]].merge!({
              "format" => s["format"],
              "timezone" => s["timezone"] || "+0900"
            })
          end
          memo
        end
        task = {
          :schema => schema_serialized,
          :root => config.param("root", :string).split("/")
        }
        columns = schema.each_with_index.map do |c, i|
          Column.new(i, c["name"], c["type"].to_sym)
        end
        yield(task, columns)
      end

      def run(file_input)
        doc = RecordBinder.new(@task["root"], @task["schema"], @page_builder)
        parser = Nokogiri::XML::SAX::Parser.new(doc)
        while file = file_input.next_file
          data = file.read
          unless data.nil?
            doc.clear
            parser.parse(data)
          end
        end
        @page_builder.finish
      end
    end

    class RecordBinder  < Nokogiri::XML::SAX::Document

      def initialize(route, schema, page_builder)
        @route = route
        @schema = schema
        @page_builder = page_builder
        clear
        super()
      end

      def clear
        @find_route_idx = 0
        @enter = false
        @current_element_name = nil
        @current_data = new_map_by_schema
      end

      def start_element(name, attributes = [])
        if !@enter
          if name == @route[@find_route_idx]
            if @find_route_idx == @route.size - 1
              @enter = true
            else
              @find_route_idx += 1
            end
          end
        else
          @current_element_name = (@schema[name].nil?) ? nil : name
        end
      end

      def characters(string)
        return if !@enter || string.strip.size == 0 || @current_element_name.nil?
        val = @current_data[@current_element_name]
        val = "" if val.nil?
        val += string
        @current_data[@current_element_name] = val
      end

      def end_element(name, attributes = [])
        if @enter
          if name == @route.last
            @enter = false
            @page_builder.add(@current_data.map{|k, v| v})
            @current_data = new_map_by_schema
          elsif !@current_element_name.nil? && @schema.key?(name)
            @current_data[name] = convert(@current_data[name], @schema[name])
          end
        end
      end

      private

      def new_map_by_schema
        @schema.keys.inject({}) do |memo, k|
          memo[k] = nil
          memo
        end
      end

      def convert(val, config)
        v = val.nil? ? "" : val
        case config["type"]
          when "string"
            v
          when "long"
            v.to_i
          when "double"
            v.to_f
          when "boolean"
            ["yes", "true", "1"].include?(v.downcase)
          when "timestamp"
            unless v.empty?
              dest = Time.strptime(v, config["format"])
              utc_offset = dest.utc_offset
              zone_offset = Time.zone_offset(config["timezone"])
              dest.localtime(zone_offset) + utc_offset - zone_offset
            else
              nil
            end
          else
            raise "Unsupported type '#{type}'"
        end
      end
    end
  end
end
