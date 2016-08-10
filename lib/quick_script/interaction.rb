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
        base.send :include, Classes
        base.send :before_filter, :handle_params if base.respond_to? :before_filter
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
                  m.to_api
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

        attr_accessor :selectors, :args, :limit, :page, :offset
        attr_reader :params

        def initialize(params)
          @params = params
          @limit = 100
          @page = 1
          @offset = 0
          if params[:scope]
            if params[:scope].is_a? Array
              @selectors = {params[:scope].first => params[:scope][1..-1]}
              @args = params[:scope][1..-1]
            else
              # json selectors
              @selectors = JSON.parse(params[:scope])
            end
          end
          @limit = params[:limit].to_i if params[:limit]
          @page = params[:page].to_i if params[:page]
          @offset = (@page - 1) * @limit if params[:page] && params[:limit]
        end

        def actor
          return @params[:actor]
        end

        def selector_names
          @selectors.keys
        end

      end

      class ScopeResponder

        def initialize(scope=nil, &block)
          @scope = scope
          @names = {}.with_indifferent_access
          @before_filter = nil
          block.call(self) if block
        end

        def scopes
          @names
        end

        def scope_for_name(name)
          @names[name]
        end

        def before_filter(&block)
          @before_filter = block
        end

        def criteria(scope)
          crit = nil

          if @before_filter
            crit = @before_filter.call
          end

          scope.selectors.each do |k, v|
            ds = scope_for_name(k)
            next if ds.nil?
            if crit.nil?
              crit = ds.call(*v)
            else
              crit.merge!(ds.call(*v))
            end
          end
          return crit
        end

        def items(scope=nil, crit=nil)
          scope ||= @scope
          crit ||= criteria(scope)
          if crit.respond_to? :limit
            items = crit.limit(scope.limit).offset(scope.offset).to_a
          else
            items = crit[scope.offset..(scope.offset + scope.limit)]
          end
          return items
        end

        def count(scope=nil, crit=nil)
          scope ||= @scope
          crit ||= criteria(scope)
          crit.count
        end

        def result(scope=nil, opts={})
          scope = SmartScope.new(scope) if (scope && !scope.is_a?(SmartScope))
          scope ||= @scope
          crit = self.criteria(scope)
          count = self.count(scope, crit)
          if count > 0
            data = self.items(scope, crit)
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

        def initialize(model, opts={}, &block)
          @model = model
          @options = opts
          @allowed_scope_names = opts[:allowed_scope_names] || @model.const_get("PUBLIC_SCOPES")
          super(&block)
        end

        def scope_for_name(name)
          return @names[name] if @names[name]
          return @model.scopes[name.to_sym][:scope] if @model.scopes[name.to_sym]
          return nil
        end

      end

    end

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

    def requested_includes(sub=nil)
      if params[:include].present?
        rs = JSON.parse(params[:include]).collect(&:to_s)
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

    def json_error(errors, meta = 404, opts = {})
      json_resp({:errors => errors}, meta, {error: errors[0]})
    end

    def render_data(data, meta=true, opts={})
      render :json => json_resp(data, meta, opts)
    end

    def render_error(err)
      render :json => json_error([err])
    end

    def prepare_api_result(result, opts={})
      ret = {}
      result.each do |key, val|
        if val.is_a?(Array)
          ret[key] = val.collect {|v| prepare_api_object(v, opts)}
        else
          ret[key] = prepare_api_object(val, opts)
        end
      end
      return ret
    end

    def prepare_api_object(model, opts)
      trs = self.class.api_object_transformers
      tr = trs[model.class.name] || trs[:default]
      self.instance_exec(model, opts, &tr)
    end

    def render_result(result, opts = {}, &block)
      result = self.prepare_api_result(result, opts)

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
      # handle scope
      @scope = QuickScript::SmartScope.new(params_with_actor)

      # handle api_ver
      @api_version = request.headers['API-Version'] || 0
      ENV['API_VER'] = @api_version.to_s
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
      responder ||= ScopeResponder.new(@scope, &block)
      responder.send(resp_action)
    end

  end
end
