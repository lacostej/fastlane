require 'json'

module Spaceship
  module Analytics
    class QOB
      attr_reader :data_convertors
      def initialize
        @hash = {}
        @allowed_keys = [:adam_id, :measures, :group, :dimension_filters, :start_time, :end_time, :frequency]
        @data_convertors = {}

        time_convertor = Proc.new { |data|
          if data.respond_to?('strftime') 
            data = data.strftime("%Y-%m-%dT00:00:00Z")
          end
          data
        }
        @data_convertors[:start_time] = time_convertor
        @data_convertors[:end_time] = time_convertor
      end

      def to_json
        @hash.to_json
      end

      def method_missing(key, *args)
        if (m=key.to_s.match(/last_(.*)_(.*)s/))
          value = m[1].to_i
          unit = m[2].to_sym
          send(:time_last, value, unit)
        elsif @allowed_keys.include?(key)
          if args.count == 0
            data(key)
          elsif args.count == 1
            add_data(key, args[0])            
          else
            super
          end
        else
          super
        end
      end

      def respond_to?(method, include_private = false)
        super || begin
          method.to_s.match(/last_(.*)_(.*)s/) || @allowed_keys.include?(method)
        end
      end

      private

      def time_last(value, unit)
        raise "Invalid unit #{unit}" unless [ :day, :week].include?(unit)
        units_in_second = {
          :day => 60 * 60 * 24,
          :week => 60 * 60 * 24 * 7,
        }
        unit_in_second = units_in_second[unit]
        end_time = Time.now
        start_time = end_time - (unit_in_second * value)
        add_data(:start_time, start_time)
        add_data(:end_time, end_time)
        add_data(:frequency, unit.to_s.upcase)
        self
      end

      def add_data(method_sym, data)
        key_sym = camel_cased(method_sym)
        @hash[key_sym] = converted_data(method_sym, data)
        self
      end

      def data(method_sym)
        key_sym = camel_cased(method_sym)
        @hash[key_sym]
      end

      def converted_data(key_sym, data)
        if @data_convertors.key? key_sym
          data = @data_convertors[key_sym].call(data)
        end
        data
      end

      def camel_cased(method_sym)
        m = method_sym.to_s.split('_')
        a = [m[0]]
        a += m[1..-1].map { |s| s.capitalize } if m.count > 1
        a.join("").to_sym
      end
    end
  end
end
QOB = Spaceship::Analytics::QOB