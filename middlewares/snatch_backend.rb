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
            p "sending message"
            @clients.each { |ws| ws.send(msg) }
          end
        end
      end
    end

    def call(env)
      if Faye::WebSocket.websocket?(env)
        ws = Faye::WebSocket.new(env, nil, { ping: KEEPALIVE_TIME })

        ws.on :onopen do |_event|
          p "WebSocket handshake complete."
        end

        ws.on :open do |_event|
          p [:open, ws.object_id]
          @clients << ws
        end

        ws.on :message do |event|
          @data = JSON.parse(event.data).transform_values { |value| ERB::Util.html_escape(value) }

          puts "\n\n\n\n\n\n"
          p [:data, data]

          initialize_room if @redis.hget(room_key, 'tiles').nil?
          perform_any_actions

          data_to_publish = data.merge(room_info)
          p "Data to publish: #{data_to_publish}"
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

    def initialize_room
      p "Initializing room"
      @redis.del(room_key)
      tiles = LETTER_FREQUENCIES.shuffle
      @redis.hset(room_key, {
        'tiles' => JSON.generate(tiles),
        'players' => JSON.generate([]),
        'overturned_letters' => JSON.generate([]),
        'overturned_indexes' => JSON.generate([]),
        'taken_indexes' => JSON.generate([])
      })
    end

    def perform_any_actions
      case data['action']
      when 'flip'
        flip_tile
      when 'word'
        take_any_used_letters
      when 'join'
        add_player_to_room
      end
    end

    def flip_tile
      @redis.hset(room_key, {
        'overturned_letters' => JSON.generate(overturned_letters.push(data['tile_letter'])),
        'overturned_indexes' => JSON.generate(overturned_indexes.push(data['tile_index']))
      })
    end

    def submitted_word_builds_on?(player_word)
      word_in?(player_word, submitted_word.split('')) && submitted_word.length > player_word.length
    end

    def word_in?(word, letters)
      letters.each(&:upcase!)
      word.split('').each { |letter| return false if letters.delete(letter) == letters }
      true
    end

    def take_any_used_letters
      word_source, word_index = place_where_word_found
      return if word_source.nil?

      if word_source == :board_only
        overturned = overturned_letters

        newly_taken_indexes = submitted_word.split('').map do |letter|
          index = overturned.index(letter)
          # Mark taken letters with '!' because index method always returns index of first instance
          overturned[index] = '!'
          index
        end

        @redis.hset(room_key, {
          'taken_indexes' => JSON.generate((taken_indexes + newly_taken_indexes))
        })
      else
        @redis.hset(room_key, {
          "words:#{word_source}" => JSON.generate((words_of_player(word_source).delete_at(word_index)))
        })
      end

      @redis.hset(room_key, {
        "words:#{current_player}" => JSON.generate(words_of_player(current_player).push(data['word']))
      })
    end

    def place_where_word_found
      return :board_only, nil if word_in?(submitted_word, overturned_letters)

      all_players_words.each do |player, words|
        words.each do |word, index|
          if word_in?(submitted_word, (overturned_letters + word.split(''))) && submitted_word_builds_on?(word)
            return player.to_sym, index
          end
        end
      end

      nil
    end

    def add_player_to_room
      unless players.include?(current_player)
        @redis.hset(room_key, {
          'players' => JSON.generate(players.push(current_player)),
          "words:#{current_player}" => JSON.generate([])
        })
      end
    end

    def room_info
      room_info = { 'overturned_letters' => overturned_letters,
        'overturned_indexes' => overturned_indexes,
        'players' => players,
        'tiles' => tiles }.merge(all_players_words)
      p [:room_info, room_info]
      room_info
    end

    def all_players_words
      p [:players_length, players.length]
      players.each_with_object({}) do |player, hash|
        hash["#{player}_words"] = words_of_player(player)
      end
    end

    def words_of_player(player)
      words_of_player = @redis.hget(room_key, "words:#{player}")
      p :words_of_player, words_of_player
      JSON.parse(words_of_player)
    end

    def submitted_word
      data['word'].upcase
    end

    def overturned_letters
      p overturned_letters
      JSON.parse(@redis.hget(room_key, 'overturned_letters'))
    end

    def overturned_indexes
      JSON.parse(@redis.hget(room_key, 'overturned_indexes'))
    end

    def taken_indexes
      JSON.parse(@redis.hget(room_key, 'taken_indexes'))
    end

    def players
      JSON.parse(@redis.hget(room_key, 'players'))
    end

    def tiles
      JSON.parse(@redis.hget(room_key, 'tiles'))
    end

    def words
      JSON.parse(@redis.hget(room_key, 'words'))
    end

    def current_player
      data['handle']
    end

    def room_key
      p [:room_key, "room:#{data['room']}"]
      "room:#{data['room']}"
    end
  end
end
