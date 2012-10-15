if defined?(Bacon)
    require 'bacon/torquespec-bacon.rb'
elsif defined?(Rspec)
    require 'rspec/core/torquespec-extensions.rb'
end
