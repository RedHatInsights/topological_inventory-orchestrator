source 'https://rubygems.org'

plugin "bundler-inject", "~> 1.1"
require File.join(Bundler::Plugin.index.load_paths("bundler-inject")[0], "bundler-inject") rescue nil

gem "activesupport",        '~> 5.2.4.3'
gem "cloudwatchlogger",     "~> 0.2.1"
gem "config",               "~> 1.7.2"
gem "http",                 "~> 4.1.1"
gem "kubeclient",           "~> 4.0"
gem "manageiq-loggers",     "~> 0.4.0", ">= 0.4.2"
gem "manageiq-messaging",   '~> 0.1.5'
gem "more_core_extensions", "~> 3.7.0"
gem "optimist"
gem "prometheus_exporter",  "~> 0.4.5"
gem "rest-client",          "~> 2.0"

group :test do
  gem "rake",                ">= 12.3.3"
  gem "rubocop",             "~> 1.0.0", :require => false
  gem "rubocop-performance", "~> 1.8",   :require => false
  gem "rubocop-rails",       "~> 2.8",   :require => false
  gem "simplecov",           "~> 0.17.1"
  gem "rspec",               "~> 3.8"
end
