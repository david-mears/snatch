# frozen_string_literal: true

require 'faye/websocket'
require 'redis'
require 'json'
require 'erb'

module Snatch
  class SnatchBackend
    KEEPALIVE_TIME = 15 # in seconds
    CHANNEL = 'snatch'
    LETTER_FREQUENCIES = %w[J J K K Q Q X X Z Z B B B C C C F F F H H H M M M P P P V V V W W W Y Y Y G G G G L L L L
                            L D D D D D D S S S S S S U U U U U U N N N N N N N N T T T T T T T T T R R R R R R R R R
                            O O O O O O O O O O O I I I I I I I I I I I I A A A A A A A A A A A A A E E E E E E E E E
                            E E E E E E E E E].freeze

    attr_reader :data

    def initialize(app)
      @app     = app
      @clients = []
      uri = URI.parse(ENV['REDISCLOUD_URL'])
      @redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
      Thread.new do
        redis_sub = Redis.new(host: uri.host, port: uri.port, password: uri.password)
        redis_sub.subscribe(CHANNEL) do |on|
          on.message do |_channel, msg|
            @clients.each { |ws| ws.send(msg) }
          end
        end
      end
    end

    def call(env)
      if Faye::WebSocket.websocket?(env)
        ws = Faye::WebSocket.new(env, nil, { ping: KEEPALIVE_TIME })
        ws.on :open do |_event|
          p [:open, ws.object_id]
          @clients << ws
        end

        ws.on :message do |event|
          @data = JSON.parse(event.data).transform_values { |value| ERB::Util.html_escape(value) }

          p data

          initialize_room if @redis.hget("room:#{current_room}", 'tiles').nil?
          perform_any_actions

          data_to_publish = data.merge(room_info)
          p :data_to_publish, data_to_publish
          @redis.publish(CHANNEL, JSON.generate(data_to_publish))
        end

        ws.on :close do |event|
          p [:close, ws.object_id, event.code, event.reason]
          @clients.delete(ws)
          ws = nil
        end

        # Return async Rack response
        ws.rack_response

      else
        @app.call(env)
      end
    end

    private

    def perform_any_actions
      case data['action']
      when 'flip'
        @redis.hset("room:#{current_room}", {
                      'overturned_letters' => JSON.generate(overturned_letters.push(data['tile_letter'])),
                      'overturned_indexes' => JSON.generate(overturned_indexes.push(data['tile_index']))
                    })
      when 'word'
        if valid_word?
          @redis.hset("room:#{current_room}", {
            "words:#{current_player}" => JSON.generate(words_of_player(current_player).push(data['word']))
          })
        end
      when 'join'
        unless players.include?(current_player)
          @redis.hset("room:#{current_room}", {
            'players' => JSON.generate(players.push(current_player)),
            "words:#{current_player}" => JSON.generate([])
          })
        end
      end
    end

    def valid_word?
      overturned = overturned_letters
      data['word'].upcase.split('').each do |letter|
        p :overturned, overturned
        p :letter, letter
        if overturned.include?(letter)
          overturned.delete(letter)
        else
          return false
        end
      end
      true
    end

    def initialize_room
      tiles = LETTER_FREQUENCIES.shuffle
      @redis.hset("room:#{current_room}", {
        'tiles' => JSON.generate(tiles),
        'players' => JSON.generate([]),
        'overturned_letters' => JSON.generate([]),
        'overturned_indexes' => JSON.generate([])
      })
    end

    def room_info
      { 'overturned_letters' => overturned_letters,
        'overturned_indexes' => overturned_indexes,
        'players' => players,
        'tiles' => tiles }.merge(all_players_words)
    end

    def all_players_words
      players.each_with_object({}) do |player, hash|
        hash["#{player}_words"] = words_of_player(player)
      end
    end

    def words_of_player(player)
      JSON.parse(@redis.hget("room:#{current_room}", "words:#{player}"))
    end

    def overturned_letters
      JSON.parse(@redis.hget("room:#{current_room}", 'overturned_letters'))
    end

    def overturned_indexes
      JSON.parse(@redis.hget("room:#{current_room}", 'overturned_indexes'))
    end

    def players
      JSON.parse(@redis.hget("room:#{current_room}", 'players'))
    end

    def tiles
      JSON.parse(@redis.hget("room:#{current_room}", 'tiles'))
    end

    def words
      JSON.parse(@redis.hget("room:#{current_room}", 'words'))
    end

    def current_player
      data['handle']
    end

    def current_room
      data['room']
    end
  end
end
