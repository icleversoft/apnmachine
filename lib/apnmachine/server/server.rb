module ApnMachine
  module Server
    class Server
        attr_accessor :client, :bind_address, :port, :redis

      def initialize(pem, redis_address, redis_port, log = '/apnmachined.log')
        @client = ApnMachine::Server::Client.new(pem)
        @bind_address, @port  = bind_address, redis_port
        @redis = Redis.new
    
        #set logging options
        if log == STDOUT
          Config.logger = Logger.new STDOUT
        elsif File.exist?(log)
          @flog = File.open(log, File::WRONLY | File::APPEND)
          Config.logger = Logger.new(@flog, 'daily')
        else
          FileUtils.mkdir_p(File.dirname(log))
  	      @flog = File.open(log, File::WRONLY | File::APPEND | File::CREAT)
          Config.logger = Logger.new(@flog, 'daily')
        end
    
      end

      def start!
        EM.synchrony do
          EM::Synchrony.add_periodic_timer(5) { @flog.flush if @flog }
          Config.logger.info "Connecting to Apple Servers"
          @client.connect!
          @last_conn_time = Time.now.to_i
      
          Config.logger.info "Starting APN Server on Redis"
          loop do  
            notification = @redis.blpop("apnmachine.queue", 0)[1]
            retries = 2
        
            begin
              #prepare notification
              #next if Notification.valid?(notification)
              notif_bin = Notification.to_bytes(notification)
        
              #force deconnection/reconnection after 10 min
              if (@last_conn_time + 1000) < Time.now.to_i || !@client.connected?
                Config.logger.error 'Reconnecting connection to APN'
                @client.disconnect!
                @client.connect!
                @last_conn_time = Time.now.to_i
              end
          
              #sending notification
              Config.logger.debug 'Sending notification to APN'
              @client.write(notif_bin)
              Config.logger.debug 'Notif sent'
          
            rescue Errno::EPIPE, OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::ETIMEDOUT
              if retries > 1
                Config.logger.error "Connection to APN servers idle for too long. Trying to reconnect"
                @client.disconnect!
                @client.connect!
                @last_conn_time = Time.now
                retries -= 1
                retry
              else
                Config.logger.error "Can't reconnect to APN Servers! Ignoring notification #{notification.to_s}"
                @client.disconnect! 
                @redis.rpush(notification)
              end
            rescue Exception => e
              Config.logger.error "Unable to handle: #{e}"
            end #end of begin

          end #end of loop
        end # synchrony
      end # def start!
    end #class Server
  end #module Server
end #module ApnMachine