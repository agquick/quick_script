require 'faraday'
require 'quick_script/base'
require 'quick_script/helpers'
require 'quick_script/interaction'
require 'quick_script/model'
require 'quick_script/hash_model'
require 'quick_script/stateable'
require 'quick_script/eventable'
require 'quick_script/short_keyable'
require 'quick_script/custom_associations'
require 'quick_script/api_endpoints'
require 'quick_script/model_endpoints'
require 'quick_script/engine'
require 'quick_script/jst_haml_processor'
require 'quick_script/qsc_transformer'
require 'quick_script/elastic_search_query'
require 'quick_script/elastic_searchable'
require 'quick_script/pundit_model'
require "quick_script/oauth2/interaction"
require "quick_script/oauth2/endpoints"


module QuickScript

  DEFAULT_ROUTING_RULE = lambda{|req| !req.env['REQUEST_URI'].include?('/api/') && !req.env['REQUEST_URI'].include?('/assets/')}
  HAS_LETTERS_REGEX = /[a-z]/i

  class Configuration

    def initialize
      self.jst_path_separator = "-"
      self.jst_name_prefix = "view-"
      self.jst_name_processor = lambda {|logical_path|
        QuickScript.jst_path_to_name(logical_path)
      }
      self.default_model_index_method = :index_as_action!
      self.default_model_save_method = :update_as_action!
      self.default_model_delete_method = :delete_as_action!
      self.default_current_user_session_fields = ['id']
    end

    attr_accessor :jst_path_separator
    attr_accessor :jst_name_prefix
    attr_accessor :jst_name_processor

    attr_accessor :default_model_index_method
    attr_accessor :default_model_save_method
    attr_accessor :default_model_delete_method

    attr_accessor :default_current_user_session_fields

    # defer setting the default because we load before Rails
    def sass_import_paths
      @sass_import_paths ||= [Rails.root.join("app/assets/stylesheets")]
    end
  end

  module Errors
    class APIError < StandardError
        def initialize(opts={})
          super
          if opts.is_a?(String)
            @message = opts
            @human_message = nil
            @resp = {}
          else
            opts ||= {}
            @resp = opts
            @message = opts[:message]
            @human_message = opts[:human_message]
          end
        end
        def message
          @message ||= "An error occurred at the server."
        end
        def human_message
          @human_message || message
        end
        def code
          1000
        end
        def type
          "APIError"
        end
        def resp
          @resp[:success] = false
          @resp[:meta] = self.code
          @resp[:data] ||= nil
          @resp[:error] = self.message
          @resp[:error_type] = self.type
          return @resp
        end
    end
    class ResourceNotFoundError < APIError
      def message
        @message ||= "The resource you are trying to load or update could not be found."
      end
      def code
        1003
      end
      def type
        "ResourceNotFoundError"
      end
    end
    class InvalidParamError < APIError
      def message
        @message ||= "A parameter you specified was invalid."
      end
      def code
        1004
      end
      def type
        "InvalidParamError"
      end
    end
  end
  include Errors
  include Interaction::Classes
  

  def self.initialize
    return if @intialized
    raise "ActionController is not available yet." unless defined?(ActionController)
    ActionController::Base.send(:include, QuickScript::Base)
    ActionController::Base.send(:helper, QuickScript::Helpers)
    @intialized = true
  end

  def self.install_or_update(asset)
    case asset
    when :js
      dest_sub = "javascripts"
    when :css
      dest_sub = "stylesheets"
    end
    asset_s = asset.to_s
    require 'fileutils'
    orig = File.join(File.dirname(__FILE__), 'quick_script', 'assets', asset_s)
    dest = File.join(Rails.root.to_s, 'vendor', 'assets', dest_sub, 'quick_script')
    main_file = File.join(dest, "quick_script.#{asset_s}")

    unless File.exists?(main_file) && FileUtils.identical?(File.join(orig, "quick_script.#{asset_s}"), main_file)
      if File.exists?(main_file)
        # upgrade
        begin
          puts "Removing directory #{dest}..."
          FileUtils.rm_rf dest
          puts "Creating directory #{dest}..."
          FileUtils.mkdir_p dest
          puts "Copying QuickScript #{dest_sub} to #{dest}..."
          FileUtils.cp_r "#{orig}/.", dest
          puts "Successfully updated QuickScript #{dest_sub}."
        rescue
          puts 'ERROR: Problem updating QuickScript. Please manually copy '
          puts orig
          puts 'to'
          puts dest
        end
      else
        # install
        begin
          puts "Creating directory #{dest}..."
          FileUtils.mkdir_p dest
          puts "Copying QuickScript #{dest_sub} to #{dest}..."
          FileUtils.cp_r "#{orig}/.", dest
          puts "Successfully installed QuickScript #{dest_sub}."
        rescue
          puts "ERROR: Problem installing QuickScript. Please manually copy "
          puts orig
          puts "to"
          puts dest
        end
      end
    end

  end

  def self.config
    @config ||= QuickScript::Configuration.new
  end

  def self.parse_bool(val)
    if val == true || val == "true" || val == 1
      return true
    else
      return false
    end
  end

  def self.parse_opts(opts)
    return nil if opts.nil?
    new_opts = opts
    if opts.is_a?(String) && !opts.blank?
      begin
        new_opts = JSON.parse(opts)
      rescue => ex
        new_opts = opts
      end
    end
    if new_opts.is_a?(Hash)
      return new_opts.with_indifferent_access
    else
      return new_opts
    end
  end

  def self.parse_data(opts)
    self.parse_opts(opts)
  end

  def self.parse_template(name, vars, opts={})
    fp = File.join Rails.root, 'app', 'views', name
    fp += ".html.erb" unless fp.ends_with?(".html.erb")
    tpl = File.read(fp)
    html = QuickScript::DynamicErb.new(vars).render(tpl)
    return html
  end

  def self.prepare_api_param(val)
    if val.respond_to?(:to_api)
      val.to_api
    elsif val.is_a?(Array)
      val.collect{|d| QuickScript.prepare_api_param(d) }
    else
      val
    end
  end

  def self.convert_to_js_string(string)
    string.gsub(/[\n\t]/, "").gsub(/\"/, "\\\"").strip
  end

  def self.jst_path_to_name(path, opts={})
    prefix = opts[:prefix] || QuickScript.config.jst_name_prefix
    sep = opts[:separator] || QuickScript.config.jst_path_separator
    "#{prefix}#{path.gsub("/", sep)}"
  end

  def self.log_exception(ex, opts={})
    Rails.logger.info ex.message
    Rails.logger.info ex.backtrace.join("\n\t")
    if defined?(ExceptionNotifier) && opts[:notify] != false
      ExceptionNotifier.notify_exception(ex, opts)
    end
  rescue => ex
    Rails.logger.info ex.message
    Rails.logger.info ex.backtrace.join("\n\t")
  end

  def self.bool_tree(arr)
    ret = {}
    return nil if arr.nil?
    return arr if arr.is_a?(Hash)
    arr.each do |val|
      if val.is_a?(Hash)
        val.each do |hk, hv|
          ret[hk] = self.bool_tree(hv)
        end
      else
        ret[val] = {}
      end
    end
    return ret
  end

  def self.bool_tree_intersection(tree1, tree2)
    ret = {}
    return nil if tree1.nil? || tree2.nil?
    tree1.each do |k, v|
      t2v = tree2[k]
      if t2v.nil?
        next
      elsif !v.empty?
        ret[k] = self.bool_tree_intersection(v, t2v)
      else
        ret[k] = {}
      end
    end
    return ret
  end

  def self.bool_tree_to_array(tree)
    ret = []
    tree.each do |k, v|
      if !v.empty?
        ret << {k => self.bool_tree_to_array(v)}
      else
        ret << k
      end
    end
    return ret
  end

  def self.enhance_models(models, opts)
    puts models.inspect
    idfn = opts[:id]
    findfn = opts[:find]
    enhfn = opts[:enhance]
    pk = opts[:primary_key] || :id
    # get ids from models
    idm = {}
    models.each do |m|
      id = idfn.call(m)
      next if id.blank?
      idstr = id.to_s
      idm[idstr] ||= []
      idm[idstr] << m
    end
    ids = idm.keys
    puts "IDS======="
    puts ids
    return if ids.blank?

    # find enhance models
    ems = findfn.call(ids)
    puts ems.inspect

    # enhance models
    ems.each do |em|
      ms = idm[em.send(pk).to_s]
      ms.each do |m|
        enhfn.call(m, em)
      end
    end
  end

  class DynamicErb

    def initialize(vars)
      vars.each {|k,v|
        self.instance_variable_set("@#{k}".to_sym, v)
      }
    end

    def render(template)
      ERB.new(template).result(binding)
    end

  end
  
end

# Finally, lets include the TinyMCE base and helpers where
# they need to go (support for Rails 2 and Rails 3)
if defined?(Rails::Railtie)
  require 'quick_script/railtie'
else
  QuickScript.initialize
end

