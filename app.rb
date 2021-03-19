# frozen_string_literal: true

require 'sinatra/base'
require './middlewares/snatch_backend'

module Snatch
  class App < Sinatra::Base
    enable :sessions
    use Snatch::SnatchBackend

    get '/' do
      create_authenticity_token
      erb :"index.html"
    end

    get '/assets/js/application.js' do
      content_type :js
      @scheme = ENV['RACK_ENV'] == 'production' ? 'wss://' : 'ws://'
      erb :"application.js"
    end

    private

    def create_authenticity_token
      # Authenticate = I am roughly who I say I am.
      # Add a token to the session. Have the user submit the token with each request to show that the request comes from
      # whoever we gave the token to.
      @authenticity_token = rand().to_s
      session[:authenticity_token] = @authenticity_token
    end
  end
end
