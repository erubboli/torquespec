require 'torquespec'
require 'rspec/core'
require 'drb'
require 'torquebox-core'

module TorqueSpec
  class Daemon

    include TorqueBox::Injectors

    def initialize(opts={})
      puts "daemon: create opts=#{opts.inspect}"
      dir = opts['pwd'].to_s
      raise "The 'pwd' option must contain a valid directory name" if dir.empty? || !File.exist?(dir)
      @analyzer = inject( 'runtime-injection-analyzer' ) 
      $: << opts['spec_dir'] if opts['spec_dir']
      Dir.chdir( dir ) do
        RSpec::Core::Runner.disable_autorun! # avoid a bunch of at_exit finalizer errors
        @options = RSpec::Core::ConfigurationOptions.new( opts['argv'].to_a )
        @options.parse_options

        @configuration = RSpec::configuration
        @world         = RSpec::world

        @options.configure(@configuration)
        @configuration.load_spec_files
        @configuration.configure_mock_framework
        @configuration.configure_expectation_framework
      end
    end

    def start
      puts "daemon: start"
      DRb.start_service("druby://127.0.0.1:#{TorqueSpec.drb_port}", self)
    end

    def stop
      puts "daemon: stop"
      DRb.stop_service
    rescue Exception
      # ignore
    end

    def run(alien, reporter)
      puts "daemon: run #{alien}"
      simple_name = alien.name.split("::").last
      example_group = @world.example_groups.inject([]) {|all,g| all + g.descendants}.find do |group| 
        group.name.split("::").last == simple_name && group.description == alien.description
      end
      example_group.descendant_filtered_examples.each do |example| 
        @analyzer.analyze_and_inject( example.instance_eval {@example_block} )
      end
      example_group.run( reporter )
    end

    # Intended to extend an RSpec::Core::ExampleGroup
    module Client

      def torquespec_before_alls
        if respond_to?(:eval_before_alls)
          eval_before_alls(new) # v 2.3
        elsif respond_to?(:run_before_all_hooks)
          run_before_all_hooks(new) # 2.7
        else
          raise "Unknown method to run before(:all) hooks"
        end
      end

      def torquespec_after_alls
        if respond_to?(:eval_after_alls)
          eval_after_alls(new) # v 2.3
        elsif respond_to?(:run_after_all_hooks)
          run_after_all_hooks(new) # 2.7
        else
          raise "Unknown method to run after(:all) hooks"
        end
      end

      def run(reporter)
        begin
          torquespec_before_alls
          run_remotely(reporter)
        rescue Exception => ex
          fail_filtered_examples(ex, reporter)
        ensure
          torquespec_after_alls
        end
      end

      # Delegate all examples (and nested groups) to remote daemon
      def run_remotely(reporter)
        DRb.start_service("druby://127.0.0.1:0")
        daemon = DRbObject.new_with_uri("druby://127.0.0.1:#{TorqueSpec.drb_port}")
        attempts = 10
        begin
          daemon.run( self, reporter )
        rescue DRb::DRbConnError
          # Overcome DRb.start_service() race condition
          raise unless (attempts-=1) > 0
          sleep(0.4)
          retry
        ensure
          DRb.stop_service
        end
      end
      
      def deploy_paths
        [ DeploymentDescriptor.new( {}, display_name, true ).path ]
      end

    end
  end
end

# Reporters really only care about metadata, which is good since not
# much else is serializable.
module RSpec
  module Core
    class Example
      def marshal_dump
        @metadata
      end
      def marshal_load data
        @example_group_class = ExampleGroup.describe
        @metadata = data
      end
    end
  end
end

# We don't actually serialize Proc objects, but we prevent a TypeError
# when an object containing a Proc is serialized, e.g. when an Example
# is passed to a remote Reporter.  This works for us because the
# Reporter doesn't use the Example's Proc objects.
class Proc
  def marshal_dump
  end
  def marshal_load *args
  end
end

# We want any Java exceptions tossed on the server to be passed back
# to the Reporter on the client, and NativeExceptions have no
# allocator, hence they're not marshalable.
class NativeException
  def _dump(*)
    Marshal.dump( [cause, backtrace] )
  end
  def self._load(str)
    exception, trace = Marshal.load(str)
    meta = class << exception; self; end
    meta.send(:define_method, :backtrace) { trace }
    exception
  end
end
