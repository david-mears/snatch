# frozen_string_literal: true

require 'sinatra/base'

module Snatch
  class App < Sinatra::Base
    get '/' do
      erb :"index.html"
    end

    get '/assets/js/application.js' do
      content_type :js
      @scheme = ENV['RACK_ENV'] == 'production' ? 'wss://' : 'ws://'
      erb :"application.js"
    end
  end
end
