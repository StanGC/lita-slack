require 'eventmachine'
require 'faye/websocket'
require 'multi_json'

require 'lita/adapters/slack/api'
require 'lita/adapters/slack/message_handler'
require 'lita/adapters/slack/im_mapping'
require 'lita/adapters/slack/user_creator'

module Lita
  module Adapters
    class Slack < Adapter
      # Required configuration attributes.
      config :token, type: String, required: true

      def initialize(robot)
        super

        @api = API.new(config.token)
        @im_mapping = IMMapping.new(api)
      end

      # Starts the connection.
      def run
        response = api.rtm_start

        raise response.error if response.error

        populate_data(response)

        rtm_connect(response.ws_url)
      end

      def send_messages(target, strings)
        strings.each do |string|
          ws.send MultiJson.dump({
            id: 1,
            type: 'message',
            text: string
            channel: channel_for(target)
          }
        end
      end

      def shut_down
        if ws
          log.debug("Closing connection to the Slack Real Time Messaging API.")
          ws.close
        end

        if EM.reactor_running?
          EM.stop
          robot.trigger(:disconnected)
        end
      end

      private

      attr_reader :api
      attr_reader :im_mapping
      attr_reader :url
      attr_reader :ws

      def channel_for(target)
        if target.room
          target.room
        else
          im_mapping.im_for(target.user.id)
        end
      end

      def populate_data(data)
        UserCreator.new.create_users(data.users)
        im_mapping.create_ims(data.ims)
      end

      def receive_message(event)
        data = MultiJson.load(event.data)

        MessageHandler.new(robot, data).handle
      end

      def rtm_connect
        EM.run do
          log.debug("Connecting to the Slack Real Time Messaging API.")
          @ws = Faye::WebSocket::Client.new(url, nil, ping: 10)

          ws.on(:open) { log.debug("Connected to the Slack Real Time Messaging API.") }
          ws.on(:message) { |event| receive_message(event) }
          ws.on(:close) { log.info("Disconnected from Slack.") }
          ws.on(:error) { |event| log.debug("WebSocket error: #{event.message}") }
        end
      end
    end

    # Register Slack adapter to Lita
    Lita.register_adapter(:slack, Slack)
  end
end

Lita.register_handler(:echo) do
  route /(.+)/i do |response|
    response.reply response.matches
  end
end
