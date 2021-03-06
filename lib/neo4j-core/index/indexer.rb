module Neo4j
  module Core
    module Index

      # This class is delegated from the Neo4j::Core::Index::ClassMethod
      # @see Neo4j::Core::Index::ClassMethods
      class Indexer
        # @return [Neo4j::Core::Index::IndexConfig]
        attr_reader :config

        def initialize(config)
          @config = config
          @indexes = {} # key = type, value = java neo4j index
                        # to enable subclass indexing to work properly, store a list of parent indexers and
                        # whenever an operation is performed on this one, perform it on all
        end


        def to_s
          "Indexer @#{object_id} index on: [#{@config.fields.map { |f| @config.numeric?(f) ? "#{f} (numeric)" : f }.join(', ')}]"
        end

        # Add an index on a field so that it will be automatically updated by neo4j transactional events.
        # Notice that if you want to numerical range queries then you should specify a field_type of either Fixnum or Float.
        # The index type will by default be <tt>:exact</tt>.
        # Index on property arrays are supported.
        #
        # @example
        #    MyIndex.index(:age, :field_type => Fixnum) # default :exact
        #    MyIndex.index(:wheels, :field_type => Fixnum)
        #    MyIndex.index(:description, :type => :fulltext)
        #
        # @see Neo4j::Core::Index::LuceneQuery
        # @see #find
        def index(*args)
          @config.index(args)
        end

        # @return [true,false] if there is an index on the given field.
        def index?(field)
          @config.index?(field)
        end

        # @return [true,false] if the
        def trigger_on?(props)
          @config.trigger_on?(props)
        end

        # @return [Symbol] the type of index for the given field (e.g. :exact or :fulltext)
        def index_type(field)
          @config.index_type(field)
        end

        # @return [true,false]  if there is an index of the given type defined.
        def has_index_type?(type)
          @config.has_index_type?(type)
        end

        # Adds an index on the given entity
        # This is normally not needed since you can instead declare an index which will automatically keep
        # the lucene index in sync.
        # @see #index
        def add_index(entity, field, value)
          return false unless index?(field)
          if (java_array?(value))
            conv_value = value.map{|x| indexed_value_for(field, x)}.to_java(Java::OrgNeo4jIndexLucene::ValueContext)
          else
            conv_value = indexed_value_for(field, value)
          end
          index = index_for_field(field.to_s)
          index.add(entity, field, conv_value)
        end

        def java_array?(value)
          value.respond_to?(:java_class) && value.java_class.to_s[0..0] == '['
        end

        # Removes an index on the given entity
        # This is normally not needed since you can instead declare an index which will automatically keep
        # the lucene index in sync.
        # @see #index
        def rm_index(entity, field, value)
          return false unless index?(field)
          #return value.each {|x| rm_index(entity, field, x)} if value.respond_to?(:each)
          index_for_field(field).remove(entity, field, value)
        end

        # Performs a Lucene Query.
        #
        # In order to use this you have to declare an index on the fields first, see #index.
        # Notice that you should close the lucene query after the query has been executed.
        # You can do that either by provide an block or calling the Neo4j::Core::Index::LuceneQuery#close
        # method. When performing queries from Ruby on Rails you do not need this since it will be automatically closed
        # (by Rack).
        #
        # @example with a block
        #   Person.find('name: kalle') {|query| puts "First item #{query.first}"}
        #
        # @example using an exact lucene index
        #   query = Person.find('name: kalle')
        #   puts "First item #{query.first}"
        #   query.close
        #
        # @example using an fulltext lucene index
        #   query = Person.find('name: kalle', :type => :fulltext)
        #   puts "First item #{query.first}"
        #   query.close
        #
        # @example Sorting, descending by one property
        #    Person.find({:name => 'kalle'}, :sort => {:name => :desc})
        #
        # @example Sorting using the builder pattern
        #    Person.find(:name => 'kalle').asc(:name)
        #
        # @example Searching by a set of values, OR search
        #    Person.find(:name => ['kalle', 'sune', 'jimmy'])
        #
        # @example Compound queries and Range queries
        #    Person.find('name: pelle').and(:age).between(2, 5)
        #    Person.find(:name => 'kalle', :age => (2..5))
        #    Person.find("name: 'asd'").and(:wheels => 8)
        #
        # @example Using the lucene java object
        #   # using the Neo4j query method directly
        #   # see, http://api.neo4j.org/1.6.1/org/neo4j/graphdb/index/ReadableIndex.html#query(java.lang.Object)
        #   MyIndex.find('description: "hej"', :type => :fulltext, :wrapped => false).get_single
        #
        # @param [String, Hash] query the lucene query
        # @param [Hash] params lucene configuration parameters
        # @return [Neo4j::Core::Index::LuceneQuery] a query object which uses the builder pattern for creating compound and sort queries.
        # @note You must specify the index type <tt>:fulltext<tt>) if the property is index using that index (default is <tt>:exact</tt>)
        def find(query, params = {})
          index = index_for_type(params[:type] || :exact)
          query.delete(:sort) if query.is_a?(Hash) && query.include?(:sort)
          query = (params[:wrapped].nil? || params[:wrapped]) ? LuceneQuery.new(index, @config, query, params) : index.query(query)

          if block_given?
            begin
              ret = yield query
            ensure
              query.close
            end
            ret
          else
            query
          end
        end

        # Add the entity to this index for the given key/value pair if this particular key/value pair doesn't already exist.
        # This ensures that only one entity will be associated with the key/value pair even if multiple transactions are trying to add it at the same time.
        # One of those transactions will win and add it while the others will block, waiting for the winning transaction to finish.
        # If the winning transaction was successful these other transactions will return the associated entity instead of adding it.
        # If it wasn't successful the waiting transactions will begin a new race to add it.
        #
        # @param [Neo4j::Node, Neo4j::Relationship] entity the entity (i.e Node or Relationship) to associate the key/value pair with.
        # @param [String, Symbol] key the key in the key/value pair to associate with the entity.
        # @param [String, Fixnum, Float] value the value in the key/value pair to associate with the entity.
        # @param [Symbol] index_type the type of lucene index
        # @return [nil, Neo4j:Node, Neo4j::Relationship] the previously indexed entity, or nil if no entity was indexed before (and the specified entity was added to the index).
        # @see Neo4j::Core::Index::UniqueFactory as an alternative which probably simplify creating unique entities
        def put_if_absent(entity, key, value, index_type = :exact)
          index = index_for_type(index_type)
          index.put_if_absent(entity, key.to_s, value)
        end

        # Delete all index configuration. No more automatic indexing will be performed
        def rm_index_config
          @config.rm_index_config
        end

        # delete the index, if no type is provided clear all types of indexes
        def rm_index_type(type=nil)
          if type
            key = @config.index_name_for_type(type)
            @indexes[key] && @indexes[key].delete
            @indexes[key] = nil
          else
            @indexes.each_value { |index| index.delete }
            @indexes.clear
          end
        end

        # Called when the neo4j shutdown in order to release references to indexes
        def on_neo4j_shutdown
          @indexes.clear
        end

        # Called from the event handler when a new node or relationships is about to be committed.
        def update_index_on(node, field, old_val, new_val)
          if index?(field)
            rm_index(node, field, old_val) if old_val
            add_index(node, field, new_val) if new_val
          end
        end

        # Called from the event handler when deleting a property
        def remove_index_on(node, old_props)
          @config.fields.each { |field| rm_index(node, field, old_props[field]) if old_props[field] }
        end

        # Creates a wrapped ValueContext for the given value. Checks if it's numeric value in the configuration.
        # @return [Java::OrgNeo4jIndexLucene::ValueContext] a wrapped neo4j lucene value context
        def indexed_value_for(field, value)
          if @config.numeric?(field)
            Java::OrgNeo4jIndexLucene::ValueContext.new(value).indexNumeric
          else
            Java::OrgNeo4jIndexLucene::ValueContext.new(value)
          end
        end

        # @return [Java::OrgNeo4jGraphdb::Index] for the given field
        def index_for_field(field)
          type = @config.index_type(field)
          index_name = index_name_for_type(type)
          @indexes[index_name] ||= create_index_with(type, index_name)
        end

        # @return [Java::OrgNeo4jGraphdb::Index] for the given index type
        def index_for_type(type)
          index_name = index_name_for_type(type)
          @indexes[index_name] ||= create_index_with(type, index_name)
        end

        # @return [String] the name of the index which are stored on the filesystem
        def index_name_for_type(type)
          @config.index_name_for_type(type)
        end

        # @return [Hash] the lucene config for the given index type
        def lucene_config(type)
          conf = Neo4j::Config[:lucene][type.to_s]
          raise "unknown lucene type #{type}" unless conf
          conf
        end

        # Creates a new lucene index using the lucene configuration for the given index_name
        #
        # @param [:node, :relationship] type relationship or node index
        # @param [String] index_name the (file) name of the index
        # @return [Java::OrgNeo4jGraphdb::Index] for the given index type
        def create_index_with(type, index_name)
          db = Neo4j.started_db
          index_config = lucene_config(type)
          if config.entity_type == :node
            db.lucene.for_nodes(index_name, index_config)
          else
            db.lucene.for_relationships(index_name, index_config)
          end
        end


      end
    end
  end
end