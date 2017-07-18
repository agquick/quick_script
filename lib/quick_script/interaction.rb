require 'ostruct'

module QuickScript
  module Interaction

    ## HELPER ACTIONS
    
    def layout_only
      render :text => '', :layout => 'application'
    end

    protected

    class << self
      def included(base)
        base.send :extend, ClassMethods
      end
    end

    module ClassMethods

      def prepare_api_for(cls, tr)
        api_object_transformers[cls] = tr
      end

      def api_object_transformers
        @api_object_transformers ||= begin
          if self.superclass.respond_to?(:api_object_transformers)
            self.superclass.api_object_transformers
          else
            {
              default: lambda {|m, opts|
                if m.respond_to?(:to_api)
                  if opts[:in_array] == true
                    m.to_api(:default)
                  else
                    m.to_api
                  end
                else
                  m
                end
              }
            }
          end
        end
      end
    end

    module Classes

      class SmartScope

        attr_accessor :selectors, :args, :limit, :page, :offset, :includes, :sort
        attr_reader :params

        def initialize(params)
          @params = params
          @limit = 100
          @page = 1
          @offset = 0
          if params[:scope]
            @selectors = JSON.parse(params[:scope])
          end
          @limit = params[:limit].to_i if params[:limit]
          @page = params[:page].to_i if params[:page]
          @offset = (@page - 1) * @limit if params[:page] && params[:limit]
          @includes = QuickScript.parse_opts(params[:includes]) if params[:includes]
          @sort = QuickScript.parse_opts(params[:sort]) if params[:sort]
        rescue => ex
          Rails.logger.info ex.message
          Rails.logger.info ex.backtrace.join("\n\t")
        end

        def actor
          return @params[:actor]
        end

        def selector_names
          @selectors.keys
        end

      end

      class ScopeResponder
        attr_reader :scope

        def initialize(request_scope, opts={}, &block)
          @options = opts
          @scope = request_scope
          @names = {}.with_indifferent_access
          @required_scope = nil
          block.call(self) if block
        end

        def scopes
          @names
        end

        def scope_for_name(name)
          @names[name]
        end

        def required_scope(&block)
          @required_scope = block
        end

        def actor
          scope.actor
        end

        def criteria(opts={})
          crit = nil
          incls = opts[:includes] || scope.includes
          sort = opts[:sort] || scope.sort

          if @required_scope
            crit = @required_scope.call
          end

          scope.selectors.each do |k, v|
            ds = scope_for_name(k)

            if ds.nil? and @options[:strict_scopes]
              raise QuickScript::Errors::APIError, "#{k} is not a valid scope"
            end
            next if ds.nil?

            if crit.nil?
              crit = ds.call(*v)
            else
              crit.merge!(ds.call(*v))
            end
          end
          if crit && incls.present? && (@options[:use_orm_includes] == true)
            crit = crit.includes(incls)
          end
          if crit && sort.present?
            if sort_scope = scope_for_name('sort')
              crit.merge!(sort_scope.call(sort))
            elsif crit.respond_to?(:order)
              crit = crit.order(sort)
            end
          end
          return crit
        end

        def items(crit=nil)
          crit ||= criteria
          return [] if crit.nil?
          if crit.respond_to? :limit
            items = crit.limit(scope.limit).offset(scope.offset).to_a
          else
            items = crit[scope.offset..(scope.offset + scope.limit)]
          end
          return items
        end

        def count(crit=nil)
          crit ||= criteria
          return 0 if crit.nil?
          crit.count
        end

        def result(opts={})
          crit = self.criteria(opts)
          count = self.count(crit)
          if count > 0
            data = self.items(crit)
          else
            data = []
          end
          if scope.limit > 0
            pages_count = (count / scope.limit.to_f).ceil
          else
            pages_count = 0
          end
          return {success: true, data: data, count: count, pages_count: pages_count, page: scope.page}
        end

        def method_missing(method_sym, *args, &block)
          @names[method_sym.to_s] = block
        end

      end

      class ModelScopeResponder < ScopeResponder

        def initialize(request_scope, model, opts={}, &block)
          @model = model

          if opts[:allowed_scope_names]
            @allowed_scope_names = opts[:allowed_scope_names].collect(&:to_s)
          elsif @model.const_defined?("PUBLIC_SCOPES")
            @allowed_scope_names = @model.const_get("PUBLIC_SCOPES").collect(&:to_s)
          else
            @allowed_scope_names = nil
          end
          super(request_scope, opts, &block)
        end

        def scope_for_name(name)
          if @allowed_scope_names && !@allowed_scope_names.include?(name.to_s)
            return nil
          end
          return @names[name] if @names[name]
          return @model.method(name.to_sym) if @model.respond_to?(name.to_sym)
          return nil
        end

      end

    end
    include Classes

    def json_resp(data, meta=true, opts = {})
      meta = 200 if meta == true 
      meta = 404 if meta == false 
      opts[:data] = data
      opts[:meta] = meta
      opts[:success] = meta == 200

      if meta != 200 && opts[:error].blank?
        opts[:error] = "An error occurred"
      end
      opts.to_json
    end

    def params_with_actor
      if self.respond_to?(:current_user, true)
        return params.merge(actor: self.current_user)
      else
        return params
      end
    end

    def request_includes(sub=nil)
      incs = params[:include] || params[:includes]
      if incs
        rs = JSON.parse(incs).collect(&:to_s)
        if sub
          sub = sub.to_s
          sl = sub.length + 1
          rs = rs.select{|r| r.start_with?(sub + ".")}.collect{|r| r[(sl..-1)]}
        end
        # only top level
        return rs.select{|r| !r.include?(".")}.collect(&:to_sym)
      else
        return []
      end
    end
    def requested_includes(sub=nil)
      request_includes(sub)
    end

    def json_error(errors, meta = 404, opts = {})
      json_resp({:errors => errors}, meta, {error: errors[0]})
    end

    def render_data(data, meta=true, opts={})
      render :json => json_resp(data, meta, opts)
    end

    def render_error(err)
      render :json => json_error([err])
    end

    # Called as part of render_result. Serializes the individual
    # fields of the result to prepare it for transmission to the
    # client.
    #
    # Per field manipulations can be inserted by overriding
    # prepare_api_field in your controller.
    #
    # @param [Hash] result to serialize
    # @param [Hash] parameters that will be provided to object transformers (typically your model's to_api method)
    # @return [Hash] json compatible serialized result
    def prepare_result(result, opts={})
      ret = {}
      result.each do |key, val|
        val = prepare_api_field(key, val)
        if val.is_a?(Array)
          ret[key] = val.collect {|v| prepare_api_object(v, opts.merge(in_array: true))}
        else
          ret[key] = prepare_api_object(val, opts)
        end
      end
      return ret
    end

    # Prepare an individual field in the result object for
    # serialization. This is an appropriate place to insert
    # transformations over the entire contents of a field whereas
    # api_object_transformers is more appropriate for transforming
    # each member of the field individually.
    #
    # By default this method performs no transformation and exists
    # only to be overridden.
    #
    # @param [String] name of the field
    # @param [Hash, Model, String, ...] 
    def prepare_api_field(key, val)
      val
    end

    def prepare_api_object(model, opts)
      trs = self.class.api_object_transformers
      tr = trs[model.class.name] || trs[:default]
      self.instance_exec(model, opts, &tr)
    end

    def render_result(result, opts = {}, &block)
      result = self.prepare_result(result, opts)

      resp = OpenStruct.new
      opts[:include_all] = true if opts[:include_all].nil?
      # set required fields
      resp.success = result[:success]
      resp.meta = result[:meta] || (result[:success] ? 200 : 500)
      resp.error = result[:error]

      # prepare data
      if !((data = result[:data]).nil?)
        resp.data = QuickScript.prepare_api_param(data)
      end

      # prepare additional fields
      result.each do |key, val|
        next if [:success, :meta, :data, :error].include?(key.to_sym)
        next if opts[:include] && !opts[:include].include?(key.to_sym)
        resp[key] = QuickScript.prepare_api_param(val)
      end

      block.call(resp) unless block.nil?

      resp_h = resp.marshal_dump
      status = opts[:status] || resp.meta

      render :json => resp_h.to_json, :status => status
    end

    def handle_params
      # handle api_ver
      @api_version = request.headers['API-Version'] || 0
      ENV['API_VER'] = @api_version.to_s
    end

    def request_scope
      QuickScript::SmartScope.new(params_with_actor)
    end

    def get_scoped_items(model, scope, limit, offset)
        @items = model
        scope.each do |m, args|
          # validate scope
          next unless can? m.to_sym, model
          args = [current_user.id.to_s] if m.include?("my_") && current_user
          if args == []
            @items = @items.send(m)
          else
            @items = @items.send(m, *args)
          end
        end
        return [] if @items == model
        @items = @items.limit(limit).offset(offset)
    end

    def respond_to_scope(resp_action=:items, responder=nil, &block)
      responder ||= ScopeResponder.new(request_scope, &block)
      responder.send(resp_action)
    end

  end
end
