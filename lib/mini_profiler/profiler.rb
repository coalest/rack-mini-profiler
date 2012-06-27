require 'json'
require 'timeout'
require 'thread'

require 'mini_profiler/page_timer_struct'
require 'mini_profiler/sql_timer_struct'
require 'mini_profiler/client_timer_struct'
require 'mini_profiler/request_timer_struct'
require 'mini_profiler/body_add_proxy'
require 'mini_profiler/storage/abstract_store'
require 'mini_profiler/storage/memory_store'
require 'mini_profiler/storage/redis_store'
require 'mini_profiler/storage/file_store'

module Rack

	class MiniProfiler

		VERSION = 'rZlycOOTnzxZvxTmFuOEV0dSmu4P5m5bLrCtwJHVXPA='.freeze
		@@instance = nil

		def self.instance
			@@instance
		end

		def self.generate_id
			rand(36**20).to_s(36)
		end

    # Defaults for MiniProfiler's configuration
    def self.configuration_defaults
      {
        :auto_inject => true, # automatically inject on every html page
        :base_url_path => "/mini-profiler-resources/",
        :authorize_cb => lambda {|env| true}, # callback returns true if this request is authorized to profile
        :position => 'left',  # Where it is displayed
        :backtrace_remove => nil,
        :backtrace_filter => nil,
        :skip_schema_queries => true,
        :storage => MiniProfiler::MemoryStore,
        :user_provider => Proc.new{|env| "TODO" }
      }
    end

    def self.reset_configuration
      @configuration = configuration_defaults
    end

    # So we can change the configuration if we want
    def self.configuration
      @configuration ||= configuration_defaults.dup
    end

    def self.share_template
      return @share_template unless @share_template.nil?
      @share_template = ::File.read(::File.expand_path("../html/share.html", ::File.dirname(__FILE__)))
    end

		#
		# options:
		# :auto_inject - should script be automatically injected on every html page (not xhr)
		def initialize(app, opts={})
			@@instance = self
      MiniProfiler.configuration.merge!(opts)
      @options = MiniProfiler.configuration 
			@app = app
			@options[:base_url_path] << "/" unless @options[:base_url_path].end_with? "/"
      unless @options[:storage_instance]
        @storage = @options[:storage_instance] = @options[:storage].new(@options[:storage_options])
      end
		end
    
    def user(env)
      options[:user_provider].call(env)
    end

		def serve_results(env)
			request = Rack::Request.new(env)      
			page_struct = @storage.load(request['id'])
      unless page_struct
        @storage.set_viewed(user(env), request['Id']) 
			  return [404, {}, ["No such result #{request['id']}"]] 
      end
			unless page_struct['HasUserViewed']
				page_struct['ClientTimings'].init_from_form_data(env, page_struct)
				page_struct['HasUserViewed'] = true
        @storage.save(page_struct) 
        @storage.set_viewed(user(env), page_struct['Id']) 
			end

      result_json = page_struct.to_json
      # If we're an XMLHttpRequest, serve up the contents as JSON
      if request.xhr?
  			[200, { 'Content-Type' => 'application/json'}, [result_json]]
      else

        # Otherwise give the HTML back
        html = MiniProfiler.share_template.dup  
        html.gsub!(/\{path\}/, @options[:base_url_path])      
        html.gsub!(/\{version\}/, MiniProfiler::VERSION)      
        html.gsub!(/\{json\}/, result_json)
        html.gsub!(/\{includes\}/, get_profile_script(env))
        html.gsub!(/\{name\}/, page_struct['Name'])
        html.gsub!(/\{duration\}/, page_struct.duration_ms.round(1).to_s)
        
        [200, {'Content-Type' => 'text/html'}, [html]]
      end

		end

		def serve_html(env)
			file_name = env['PATH_INFO'][(@options[:base_url_path].length)..1000]
			return serve_results(env) if file_name.eql?('results')
			full_path = ::File.expand_path("../html/#{file_name}", ::File.dirname(__FILE__))
			return [404, {}, ["Not found"]] unless ::File.exists? full_path
			f = Rack::File.new nil
			f.path = full_path
			f.cache_control = "max-age:86400"
			f.serving env
		end

    def self.current
      Thread.current['profiler.mini.private']
    end

    def self.current=(c)
      # we use TLS cause we need access to this from sql blocks and code blocks that have no access to env
 			Thread.current['profiler.mini.private'] = c
    end
   
    def current
      MiniProfiler.current
    end

    def current=(c)
      MiniProfiler.current=c
    end

    def options
      @options
    end

    def self.create_current(env={}, options={})
      # profiling the request
      self.current = {}
      self.current['inject_js'] = options[:auto_inject] && (!env['HTTP_X_REQUESTED_WITH'].eql? 'XMLHttpRequest')
      self.current['page_struct'] = PageTimerStruct.new(env)
      self.current['current_timer'] = current['page_struct']['Root']
    end

		def call(env)
			status = headers = body = nil

			# only profile if authorized
			return @app.call(env) unless @options[:authorize_cb].call(env)

			# handle all /mini-profiler requests here
			return serve_html(env) if env['PATH_INFO'].start_with? @options[:base_url_path]

      MiniProfiler.create_current(env, @options)
      if env["QUERY_STRING"] =~ /pp=skip-backtrace/
        current['skip-backtrace'] = true
      end

      start = Time.now 

      done_sampling = false
      quit_sampler = false
      backtraces = nil
      if env["QUERY_STRING"] =~ /pp=sample/
        backtraces = []
        t = Thread.current
        Thread.new {
          i = 10000 # for sanity never grab more than 10k samples 
          unless done_sampling || i < 0
            i -= 1
            backtraces << t.backtrace
            sleep 0.001
          end
          quit_sampler = true
        }
      end

			status, headers, body = nil
      begin 
        status,headers, body = @app.call(env)
      ensure
        if backtraces 
          done_sampling = true
          sleep 0.001 until quit_sampler
        end
      end

      page_struct = current['page_struct']
			page_struct['Root'].record_time((Time.now - start) * 1000)

			# inject headers, script
			if status == 200
				@storage.save(page_struct)
        @storage.set_unviewed(user(env), page_struct['Id']) 
        
				# inject header
        if headers.is_a? Hash
          headers['X-MiniProfiler-Ids'] = ids_json(env)
        end

				# inject script
				if current['inject_js'] \
					&& headers.has_key?('Content-Type') \
					&& !headers['Content-Type'].match(/text\/html/).nil? then
					body = MiniProfiler::BodyAddProxy.new(body, self.get_profile_script(env))
				end
			end

      # mini profiler is meddling with stuff, we can not cache cause we will get incorrect data
      # Rack::ETag has already inserted some nonesense in the chain
      headers.delete('ETag')
      headers.delete('Date')
      headers['Cache-Control'] = 'must-revalidate, private, max-age=0'
			[status, headers, body]
    ensure
      # Make sure this always happens
      current = nil
		end

    def ids_json(env)
      ids = [current['page_struct']["Id"]] + (@storage.get_unviewed_ids(user(env)) || [])
      ::JSON.generate(ids.uniq)
    end

		# get_profile_script returns script to be injected inside current html page
		# By default, profile_script is appended to the end of all html requests automatically.
		# Calling get_profile_script cancels automatic append for the current page
		# Use it when:
		# * you have disabled auto append behaviour throught :auto_inject => false flag
		# * you do not want script to be automatically appended for the current page. You can also call cancel_auto_inject
		def get_profile_script(env)
			ids = ids_json(env)
			path = @options[:base_url_path]
			version = MiniProfiler::VERSION
			position = @options[:position]
			showTrivial = false
			showChildren = false
			maxTracesToShow = 10
			showControls = false
			currentId = current['page_struct']["Id"]
			authorized = true
      useExistingjQuery = false
			# TODO : cache this snippet 
			script = IO.read(::File.expand_path('../html/profile_handler.js', ::File.dirname(__FILE__)))
			# replace the variables
			[:ids, :path, :version, :position, :showTrivial, :showChildren, :maxTracesToShow, :showControls, :currentId, :authorized, :useExistingjQuery].each do |v|
				regex = Regexp.new("\\{#{v.to_s}\\}")
				script.gsub!(regex, eval(v.to_s).to_s)
			end
			# replace the '{{' and '}}''
			script.gsub!(/\{\{/, '{').gsub!(/\}\}/, '}')
			current['inject_js'] = false
			script
		end

		# cancels automatic injection of profile script for the current page
		def cancel_auto_inject(env)
		  current['inject_js'] = false
		end

		# perform a profiling step on given block
		def self.step(name)
      if current
        old_timer = current['current_timer']
        new_step = RequestTimerStruct.new(name, current['page_struct'])
        current['current_timer'] = new_step
        new_step['Name'] = name
        start = Time.now
        result = yield if block_given?
        new_step.record_time((Time.now - start)*1000)
        old_timer.add_child(new_step)
        current['current_timer'] = old_timer
        result
      else
        yield if block_given?
      end
		end

    def self.profile_method(klass, method, &blk)
      default_name = klass.to_s + " " + method.to_s
      with_profiling = (method.to_s + "_with_mini_profiler").intern
      without_profiling = (method.to_s + "_without_mini_profiler").intern
      
      klass.send :alias_method, without_profiling, method
      klass.send :define_method, with_profiling do |*args, &orig|
        name = default_name 
        name = blk.bind(self).call(*args) if blk
        ::Rack::MiniProfiler.step name do 
          self.send without_profiling, *args, &orig
        end
      end
      klass.send :alias_method, method, with_profiling
    end

		def record_sql(query, elapsed_ms)
      c = current
			c['current_timer'].add_sql(query, elapsed_ms, c['page_struct'], c['skip-backtrace']) if (c && c['current_timer'])
		end

	end

end

