require 'erb'
require 'mongo'
require 'active_support'
require 'active_support/core_ext'
require 'mongodb_logger/replica_set_helper'

module MongodbLogger
  class Logger < ActiveSupport::BufferedLogger
    include ReplicaSetHelper

    DEFAULT_COLLECTION_SIZE = 250.megabytes
    # Looks for configuration files in this order
    CONFIGURATION_FILES = ["mongodb_logger.yml", "mongoid.yml", "database.yml"]
    LOG_LEVEL_SYM = [:debug, :info, :warn, :error, :fatal, :unknown]

    attr_reader :db_configuration, :mongo_connection, :mongo_collection_name, :mongo_collection

    def initialize(options={})
      path = options[:path] || File.join(Rails.root, "log/#{Rails.env}.log")
      level = options[:level] || DEBUG
      internal_initialize
    rescue => e
      # should use a config block for this
      Rails.env.production? ? (raise e) : (puts "MongodbLogger WARNING: Using BufferedLogger due to exception: " + e.message)
    ensure
      if disable_file_logging?
        @level          = level
        @buffer         = {}
        @auto_flushing  = 1
        @guard          = Mutex.new
      else
        super(path, level)
      end
    end

    def add_metadata(options={})
      options.each do |key, value|
        unless [:messages, :request_time, :ip, :runtime, :application_name, :is_exception, :params, :method].include?(key.to_sym)
          @mongo_record[key] = value
        else
          raise ArgumentError, ":#{key} is a reserved key for the mongodb logger. Please choose a different key"
        end
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      if @level && @level <= severity && message.present? && @mongo_record.present?
        # do not modify the original message used by the buffered logger
        msg = logging_colorized? ? message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip : message
        @mongo_record[:messages][LOG_LEVEL_SYM[severity]] << msg
      end
      # may modify the original message
      disable_file_logging? ? message : (@level ? super : message)
    end

    # Drop the capped_collection and recreate it
    def reset_collection
      if @mongo_connection && @mongo_collection
        @mongo_collection.drop
        create_collection
      end
    end

    def mongoize(options={})
      @mongo_record = options.merge({
        :messages => Hash.new { |hash, key| hash[key] = Array.new },
        :request_time => Time.now.getutc,
        :application_name => @application_name
      })

      runtime = Benchmark.measure{ yield }.real if block_given?
    rescue Exception => e
      add(3, e.message + "\n" + e.backtrace.join("\n"))
      @mongo_record[:is_exception] = true
      # Reraise the exception for anyone else who cares
      raise e
    ensure
      # In case of exception, make sure runtime is set
      @mongo_record[:runtime] = ((runtime ||= 0) * 1000).ceil
      begin
        @insert_block.call
      rescue
        # do extra work to inpect (and flatten)
        force_serialize @mongo_record
        @insert_block.call rescue nil
      end
    end

    def authenticated?
      @authenticated
    end

    private
      # facilitate testing
      def internal_initialize
        configure
        connect
        check_for_collection
      end
      
      def disable_file_logging?
        @db_configuration.fetch('disable_file_logging', false)
      end

      def configure
        default_capsize = DEFAULT_COLLECTION_SIZE
        @authenticated = false
        @db_configuration = {
          'host' => 'localhost',
          'port' => 27017,
          'capsize' => default_capsize}.merge(resolve_config)
        @mongo_collection_name = @db_configuration[:collection] || "#{Rails.env}_log"
        @application_name = resolve_application_name
        @safe_insert = @db_configuration['safe_insert'] || false

        @insert_block = @db_configuration.has_key?('replica_set') && @db_configuration['replica_set'] ?
          lambda { rescue_connection_failure{ insert_log_record(@safe_insert) } } :
          lambda { insert_log_record }
      end

      def resolve_application_name
        if @db_configuration.has_key?('application_name')
          @db_configuration['application_name']
        else
          Rails.application.class.to_s.split("::").first
        end
      end

      def resolve_config
        config = {}
        CONFIGURATION_FILES.each do |filename|
          config_file = Rails.root.join("config", filename)
          if config_file.file?
            config = YAML.load(ERB.new(config_file.read).result)[Rails.env]
            config = config['mongodb_logger'] if config && config.has_key?('mongodb_logger')
            break unless config.blank?
          end
        end
        config
      end

      def connect
        @mongo_connection ||= Mongo::Connection.new(@db_configuration['host'],
                                                    @db_configuration['port'],
                                                    :auto_reconnect => true,
                                                    :pool_timeout => 6).db(@db_configuration['database'])

        if @db_configuration['username'] && @db_configuration['password']
          # the driver stores credentials in case reconnection is required
          @authenticated = @mongo_connection.authenticate(@db_configuration['username'],
                                                          @db_configuration['password'])
        end
      end

      def create_collection
        @mongo_connection.create_collection(@mongo_collection_name,
                                            {:capped => true, :size => @db_configuration['capsize']})
      end

      def check_for_collection
        # setup the capped collection if it doesn't already exist
        create_collection unless @mongo_connection.collection_names.include?(@mongo_collection_name)
        @mongo_collection = @mongo_connection[@mongo_collection_name]
      end

      def insert_log_record(safe = false)
        @mongo_collection.insert(@mongo_record, :safe => safe)
      end

      def logging_colorized?
        # Cache it since these ActiveRecord attributes are assigned after logger initialization occurs in Rails boot
        @colorized ||= Object.const_defined?(:ActiveRecord) && ActiveRecord::LogSubscriber.colorize_logging
      end

      # force the data in the db by inspecting each top level array and hash element
      # this will flatten other hashes and arrays
      def force_serialize(rec)
        if msgs = rec[:messages]
          LOG_LEVEL_SYM.each do |i|
            msgs[i].collect! { |j| j.inspect } if msgs[i]
          end
        end
        if pms = rec[:params]
          pms.each { |i, j| pms[i] = j.inspect }
        end
      end
  end
end