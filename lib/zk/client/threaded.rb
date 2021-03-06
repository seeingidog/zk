module ZK
  module Client
    # This is the default client that ZK will use. In the zk-eventmachine gem,
    # there is an Evented client.
    #
    # If you want to register `on_*` callbacks (see {ZK::Client::StateMixin})
    # then you should pass a block, which will be called before the
    # connection is set up (this way you can get the `on_connected` event). See
    # the 'Register on_connected callback' example.
    #
    # A note on event delivery. There has been some confusion, caused by
    # incorrect documentation (which I'm very sorry about), about how many
    # threads are delivering events. The documentation for 0.9.0 was incorrect
    # in stating the number of threads used to deliver events. There was one,
    # unconfigurable, event dispatch thread. In 1.0 the number of event
    # delivery threads is configurable, but still defaults to 1. 
    #
    # If you use the threadpool/event callbacks to perform work, you may be
    # interested in registering an `on_exception` callback that will receive
    # all exceptions that occur on the threadpool that are not handled (i.e.
    # that bubble up to top of a block).
    #
    #
    # @example Register on_connected callback.
    #   
    #   # the nice thing about this pattern is that in the case of a call to #reopen
    #   # all your watches will be re-established
    #
    #   ZK::Client::Threaded.new('localhost:2181') do |zk|
    #     # do not do anything in here except register callbacks
    #     
    #     zk.on_connected do |event|
    #       zk.stat('/foo/bar', watch: true)
    #       zk.stat('/baz', watch: true)
    #     end
    #   end
    #
    class Threaded < Base
      include StateMixin
      include Unixisms
      include Conveniences
      include Logging

      DEFAULT_THREADPOOL_SIZE = 1

      # @private
      module Constants
        CLI_RUNNING   = :running
        CLI_PAUSED    = :paused
        CLI_CLOSE_REQ = :close_requested
        CLI_CLOSED    = :closed
      end
      include Constants

      # Construct a new threaded client.
      #
      # Pay close attention to the `:threaded` option, and have a look at the
      # [EventDeliveryModel](https://github.com/slyphon/zk/wiki/EventDeliveryModel)
      # page in the wiki for a discussion of the relative advantages and
      # disadvantages of the choices available. The default is safe, but the
      # alternative will likely provide better performance.
      #
      # @note The `:timeout` argument here is *not* the session_timeout for the
      #   connection. rather it is the amount of time we wait for the connection
      #   to be established. The session timeout exchanged with the server is 
      #   set to 10s by default in the C implemenation, and as of version 0.8.0 
      #   of slyphon-zookeeper has yet to be exposed as an option. That feature
      #   is planned. 
      #
      # @note The documentation for 0.9.0 was incorrect in stating the number
      #   of threads used to deliver events. There was one, unconfigurable,
      #   event dispatch thread. In 1.0 the number of event delivery threads is
      #   configurable, but still defaults to 1 and users are discouraged from
      #   adjusting the value due to the complexity this introduces. In 1.1
      #   there is a better option for achieving higher concurrency (see the
      #   `:thread` option)
      #
      #   The Management apologizes for any confusion this may have caused. 
      #
      # @since __1.1__: Instead of adjusting the threadpool, users are _strongly_ encouraged
      #   to use the `:thread => :per_callback` option to increase the
      #   parallelism of event delivery safely and sanely. Please see 
      #   [this wiki article](https://github.com/slyphon/zk/wiki/EventDeliveryModel) for more
      #   information and a demonstration.
      #
      # @param host (see Base#initialize)
      #
      # @option opts [true,false] :reconnect (true) if true, we will register
      #   the equivalent of `on_session_expired { zk.reopen }` so that in the
      #   case of an expired session, we will keep trying to reestablish the
      #   connection. You *almost definately* want to leave this at the default.
      #   The only reason not to is if you already have a handler registered 
      #   that does something application specific, and you want to avoid a 
      #   conflict.
      #
      # @option opts [Fixnum] :retry_duration (nil) for how long (in seconds)
      #   should we wait to re-attempt a synchronous operation after we receive a
      #   ZK::Exceptions::Retryable error. This exception (or really, group of
      #   exceptions) is raised when there has been an unintentional network
      #   connection or session loss, so retrying an operation in this situation
      #   is like saying "If we are disconnected, How long should we wait for the
      #   connection to become available before attempthing this operation?"
      #
      #   The default `nil` means automatic retry is not attempted.
      #
      #   This is a global option, and will be used for all operations on this
      #   connection, however it can be overridden for any individual operation.
      #
      # @option opts [:single,:per_callback] :thread (:single) choose your event
      #   delivery model:
      #
      #   * `:single`: There is one thread, and only one callback is called at
      #     a time. This is the default mode (for now), and will provide the most
      #     safety for your app. All events will be delivered as received, to
      #     callbacks in the order they were registered. This safety has the
      #     tradeoff that if one of your callbacks performs some action that blocks
      #     the delivery thread, you will not recieve other events until it returns.
      #     You're also limiting the concurrency of your app. This should be fine
      #     for most simple apps, and is a good choice to start with when
      #     developing your application
      #
      #   * `:per_callback`: This option will use a new-style Actor model (inspired by 
      #     [Celluloid](https://github.com/celluloid/celluloid)) that uses a
      #     per-callback queue and thread to allow for greater concurrency in
      #     your app, whille still maintaining some kind of sanity. By choosing
      #     this option your callbacks will receive events in order, and will
      #     receive only one at a time, but in parallel with other callbacks.
      #     This model has the advantage you can have all of your callbacks
      #     making progress in parallel, and if one of them happens to block,
      #     it will not affect the others.
      #    
      #   * see {https://github.com/slyphon/zk/wiki/EventDeliveryModel the wiki} for a
      #     discussion and demonstration of the effect of this setting.
      #
      # @option opts [Fixnum] :timeout used as a default for calls to {#reopen}
      #   and {#connect} (including the initial default immediate connection)
      #
      # @option opts [true,false] :connect (true) Immediately connect to the
      #   server. It may be useful to pass false if you wish to do callback
      #   setup without passing a block. You must then call {#connect} 
      #   explicitly.
      #
      # @yield [self] calls the block with the new instance after the event
      #   handler and threadpool have been set up, but before any connections
      #   have been made.  This allows the client to register watchers for
      #   session events like `connected`. You *cannot* perform any other
      #   operations with the client as you will get a NoMethodError (the
      #   underlying connection is nil).
      #
      # @return [Threaded] a new client instance
      #
      # @see Base#initialize
      def initialize(host, opts={}, &b)
        super(host, opts)

        tp_size = opts.fetch(:threadpool_size, DEFAULT_THREADPOOL_SIZE)
        @threadpool = Threadpool.new(tp_size)

        @connection_timeout = opts.fetch(:timeout, DEFAULT_TIMEOUT) # maybe move this into superclass?
        @event_handler   = EventHandler.new(self, opts)

        @reconnect = opts.fetch(:reconnect, true)

        @mutex = Monitor.new
        @cond = @mutex.new_cond

        @cli_state = CLI_RUNNING # this is to distinguish between *our* state and the underlying connection state

        # this is the last status update we've received from the underlying connection
        @last_cnx_state = Zookeeper::ZOO_CLOSED_STATE 

        @retry_duration = opts.fetch(:retry_duration, nil).to_i

        @fork_subs = [
          ForkHook.prepare_for_fork(method(:pause_before_fork_in_parent)),
          ForkHook.after_fork_in_parent(method(:resume_after_fork_in_parent)),
          ForkHook.after_fork_in_child(method(:reopen)),
        ]

        ObjectSpace.define_finalizer(self, self.class.finalizer(@fork_subs))

        yield self if block_given?

        connect if opts.fetch(:connect, true)
      end

      def self.finalizer(hooks)
        proc { hooks.each(&:unregister) }
      end

      # @option opts [Fixnum] :timeout how long we will wait for the connection
      #   to be established. If timeout is nil, we will wait forever: *use
      #   carefully*.
       def connect(opts={})
        @mutex.synchronize { unlocked_connect(opts) }
      end

      # (see Base#reopen)
      def reopen(timeout=nil)
        # If we've forked, then we can call all sorts of normally dangerous 
        # stuff because we're the only thread. 
        if forked?
          # ok, just to sanity check here
          raise "[BUG] we hit the fork-reopening code in JRuby!!" if defined?(::JRUBY_VERSION)

          logger.debug { "reopening everything, fork detected!" }

          @mutex      = Mutex.new
          @cond       = ConditionVariable.new
          @pid        = Process.pid
          @cli_state  = CLI_RUNNING                     # reset state to running if we were paused

          old_cnx, @cnx = @cnx, nil
          old_cnx.close! if old_cnx # && !old_cnx.closed?

          @mutex.synchronize do
            # it's important that we're holding the lock, as access to 'cnx' is
            # synchronized, and we want to avoid a race where event handlers
            # might see a nil connection. I've seen this exception occur *once*
            # so it's pretty rare (it was on 1.8.7 too), but just to be double
            # extra paranoid

            @event_handler.reopen_after_fork!
            @threadpool.reopen_after_fork!          # prune dead threadpool threads after a fork()

            unlocked_connect
          end
        else
          @mutex.synchronize do
            if @cli_state == CLI_PAUSED
              # XXX: what to do in this case? does it matter?
            end

            logger.debug { "reopening, no fork detected" }
            @cnx.reopen(timeout)                # ok, we werent' forked, so just reopen
          end
        end

        state
      end

      # Before forking, call this method to peform a "stop the world" operation on all
      # objects associated with this connection. This means that this client will spin down
      # and join all threads (so make sure none of your callbacks will block forever), 
      # and will tke no action to keep the session alive. With the default settings,
      # if a ping is not received within 20 seconds, the session is considered dead
      # and must be re-established so be sure to call {#resume_after_fork_in_parent}
      # before that deadline, or you will have to re-establish your session.
      #
      # @raise [InvalidStateError] when called and not in running? state
      # @private
      def pause_before_fork_in_parent
        @mutex.synchronize do
          raise InvalidStateError, "client must be running? when you call #{__method__}" unless (@cli_state == CLI_RUNNING)
          @cli_state = CLI_PAUSED
      
          logger.debug { "#{self.class}##{__method__}" }

          @cond.broadcast
        end

        [@event_handler, @threadpool, @cnx].each(&:pause_before_fork_in_parent)
      end

      # @private
      def resume_after_fork_in_parent
        @mutex.synchronize do
          raise InvalidStateError, "client must be paused? when you call #{__method__}" unless (@cli_state == CLI_PAUSED)
          @cli_state = CLI_RUNNING

          logger.debug { "#{self.class}##{__method__}" }

          [@cnx, @event_handler, @threadpool].each(&:resume_after_fork_in_parent)

          @cond.broadcast
        end
      end

      # (see Base#close!)
      #
      # @note We will make our best effort to do the right thing if you call
      #   this method while in the threadpool. It is _a much better idea_ to
      #   call us from the main thread, or _at least_ a thread we're not going
      #   to be trying to shut down as part of closing the connection and
      #   threadpool.
      #
      def close!
        @mutex.synchronize do 
          return if [:closed, :close_requested].include?(@cli_state)
          logger.debug { "moving to :close_requested state" }
          @cli_state = CLI_CLOSE_REQ
          @cond.broadcast
        end

        on_tpool = on_threadpool?

        # Ok, so the threadpool will wait up to N seconds while joining each thread.
        # If _we're on a threadpool thread_, have it wait until we're ready to jump
        # out of this method, and tell it to wait up to 5 seconds to let us get
        # clear, then do the rest of the shutdown of the connection 
        #
        # if the user *doesn't* hate us, then we just join the shutdown_thread immediately
        # and wait for it to exit
        #
        shutdown_thread = Thread.new do
          @threadpool.shutdown(10)
          super

          @mutex.synchronize do
            logger.debug { "moving to :closed state" }
            @cli_state = CLI_CLOSED
            @cond.broadcast
          end
        end

        on_tpool ? shutdown_thread : shutdown_thread.join 
      end

      # {see Base#close}
      def close
        super
        subs, @fork_subs = @fork_subs, []
        subs.each(&:unsubscribe)
        nil
      end

      # (see Threadpool#on_threadpool?)
      def on_threadpool?
        @threadpool and @threadpool.on_threadpool?
      end

      # (see Threadpool#on_exception)
      def on_exception(&blk)
        @threadpool.on_exception(&blk)
      end

      # @private
      def raw_event_handler(event)
        return unless event.session_event?
        
        @mutex.synchronize do
          @last_cnx_state = event.state

          if event.client_invalid? and @reconnect and not dead_or_dying?
            logger.error { "Got event #{event.state_name}, calling reopen(0)! things may be messed up until this works itself out!" }

            # reopen(0) means that we don't want to wait for the connection
            # to reach the connected state before returning as we're on the
            # event thread.
            reopen(0)
          end

          @cond.broadcast # wake anyone waiting for a connection state update
        end
      rescue Exception => e
        logger.error { "BUG: Exception caught in raw_event_handler: #{e.to_std_format}" } 
      end

      def closed?
        return true if @mutex.synchronize { @cli_state == CLI_CLOSED }
        super
      end

      # are we in running (not-paused) state?
      def running?
        @mutex.synchronize { @cli_state == CLI_RUNNING }
      end

      # are we in paused state?
      def paused?
        @mutex.synchronize { @cli_state == CLI_PAUSED }
      end

      # has shutdown time arrived?
      def close_requested?
        @mutex.synchronize { @cli_state == CLI_CLOSE_REQ }
      end

      protected
        # in the threaded version of the client, synchronize access around cnx
        # so that callers don't wind up with a nil object when we're in the middle
        # of reopening it
        def cnx
          @mutex.synchronize { @cnx }
        end

        def call_and_check_rc(meth, opts)
          if retry_duration = (opts.delete(:retry_duration) || @retry_duration)
            begin
              super(meth, opts)
            rescue Exceptions::Retryable => e
              time_to_stop = Time.now + retry_duration

              wait_until_connected_or_dying(retry_duration)

              if (@last_cnx_state != Zookeeper::ZOO_CONNECTED_STATE) || (Time.now > time_to_stop) || (@cli_state != CLI_RUNNING)
                raise e
              else
                retry
              end
            end
          else
            super
          end
        end

        def wait_until_connected_or_dying(timeout)
          time_to_stop = Time.now + timeout

          @mutex.synchronize do
            while (@last_cnx_state != Zookeeper::ZOO_CONNECTED_STATE) && (Time.now < time_to_stop) && (@cli_state == CLI_RUNNING)
              @cond.wait(timeout)
            end

            logger.debug { "@last_cnx_state: #{@last_cnx_state}, time_left? #{Time.now.to_f < time_to_stop.to_f}, @cli_state: #{@cli_state.inspect}" }
          end
        end

        def create_connection(*args)
          ::Zookeeper.new(*args)
        end

        def dead_or_dying?
          (@cli_state == CLI_CLOSE_REQ) || (@cli_state == CLI_CLOSED)
        end

      private
        def unlocked_connect(opts={})
          return if @cnx
          timeout = opts.fetch(:timeout, @connection_timeout)
          @cnx = create_connection(@host, timeout, @event_handler.get_default_watcher_block)
        end
    end
  end
end
