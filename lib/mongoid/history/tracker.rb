module Mongoid::History
  module Tracker
    extend ActiveSupport::Concern

    included do
      include Mongoid::Document
      include Mongoid::Timestamps

      field       :association_chain,       :type => Array,     :default => []
      field       :modified,                :type => Hash
      field       :original,                :type => Hash
      field       :version,                 :type => Integer
      field       :action,                  :type => String
      field       :scope,                   :type => String
      referenced_in :modifier,              :class_name => Mongoid::History.modifier_class_name

      Mongoid::History.tracker_class_name = self.name.tableize.singularize.to_sym

      if defined?(ActionController) and defined?(ActionController::Base)
        ActionController::Base.class_eval do
          around_filter Mongoid::History::Sweeper.instance
        end
      end
    end

    def undo!(modifier)
      if action.to_sym == :destroy
        re_create
      elsif action.to_sym == :create
        re_destroy
      else
        trackable.update_attributes!(undo_attr(modifier))
      end
    end

    def redo!(modifier)
      if action.to_sym == :destroy
        re_destroy
      elsif action.to_sym == :create
        re_create
      else
        trackable.update_attributes!(redo_attr(modifier))
      end
    end

    def undo_attr(modifier)
      undo_hash = affected.easy_unmerge(modified)
      undo_hash.easy_merge!(original)
      modifier_field = trackable.history_trackable_options[:modifier_field]
      undo_hash[modifier_field] = modifier
      undo_hash
    end

    def redo_attr(modifier)
      redo_hash = affected.easy_unmerge(original)
      redo_hash.easy_merge!(modified)
      modifier_field = trackable.history_trackable_options[:modifier_field]
      redo_hash[modifier_field] = modifier
      redo_hash
    end

    def trackable_root
      @trackable_root ||= trackable_parents_and_trackable.first
    end

    def trackable
      @trackable ||= trackable_parents_and_trackable.last
    end

    def trackable_parents
      @trackable_parents ||= trackable_parents_and_trackable[0, -1]
    end

    def affected
      @affected ||= (modified.keys | original.keys).inject({}){ |h,k| h[k] = 
        trackable ? trackable.attributes[k] : modified[k]; h}
    end

private

    def re_create
      association_chain.length > 1 ? create_on_parent : create_standalone
    end
    
    def re_destroy
      trackable.destroy
    end

    def create_standalone
      class_name = association_chain.first["name"]
      restored = class_name.constantize.new(modified)
      restored.save!
    end
    
    def create_on_parent
      trackable_parents_and_trackable[-2].send(association_chain.last["name"].tableize).create!(modified)
    end

    def trackable_parents_and_trackable
      @trackable_parents_and_trackable ||= traverse_association_chain
    end
    
    def traverse_association_chain
      chain = association_chain.dup
      doc = nil
      documents = []
      begin
        node = chain.shift
        name = node['name']
        
        # this breakes on embeds_one relationships
        #col  = doc.nil? ? name.classify.constantize : doc.send(name.tableize)
        #doc  = col.where(:_id => node['id']).first
        
        # this doesn't break but if feels hackish (is there a better way to recognize if the relationship is 1..1 or 1..N?)
        if doc.nil?
          col  = name.classify.constantize
          doc  = col.where(:_id => node['id']).first
        else
          if doc.respond_to?(name.tableize)
            # this works for embeds_many
            col  = doc.send(name.tableize)
            doc  = col.where(:_id => node['id']).first
          else
            # this works for embeds_one
            doc  = doc.send(name.tableize.singularize)
          end
        end
        
        documents << doc
      end while( !chain.empty? )
      documents
    end

  end
end
