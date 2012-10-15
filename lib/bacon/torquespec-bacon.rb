class Bacon::Context
    include TorqueSpec
end

TorqueSpec.remote do
    module BaconExtension
        def deploy(*descriptiors)
        end
    end
    class Bacon::Context
        include BaconExtension
    end
end

TorqueSpec.local do

  require 'torquespec/server'
  class Bacon::Context
      def run
        Thread.current[:app_server] = TorqueSpec::Server.new
        Thread.current[:app_server].start(:wait => 120)
        super
        Thread.current[:app_server].stop
      end
  
      def initialize
         super
         before do
          self.class.deploy_paths.each do |path|
            Thread.current[:app_server].deploy(path)
          end if self.class.respond_to?( :deploy_paths )
         end

         after do
          self.class.deploy_paths.each do |path|
            Thread.current[:app_server].undeploy(path)
          end if self.class.respond_to?( :deploy_paths )
         end
      end
  end
end
