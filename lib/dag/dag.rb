module Dag
  # Sets up a model to act as dag links for models specified under the :for option
  def acts_as_dag_links(options = {})
    conf = {
      ancestor_id_column: "ancestor_id",
      ancestor_type_column: "ancestor_type",
      descendant_id_column: "descendant_id",
      descendant_type_column: "descendant_type",
      direct_column: "direct",
      count_column: "count",
      scope_column: nil,
      node_class_name: nil
    }
    conf.update(options)

    if conf[:node_class_name].nil?
      raise(ActiveRecord::ActiveRecordError,
            "ERROR: Non-polymorphic graphs need to specify :node_class_name with the receiving class like belong_to")
    end

    class_attribute :acts_as_dag_options, instance_writer: false
    self.acts_as_dag_options = conf

    extend Columns
    include Columns

    # access to _changed? and _was for (edge,count) if not default
    unless direct_column_name == "direct"
      module_eval <<-"END_EVAL", __FILE__, __LINE__ + 1
        def direct_changed?
          self.#{direct_column_name}_changed?
        end

        def direct_was
          self.#{direct_column_name}_was
        end
      END_EVAL
    end

    unless count_column_name == "count"
      module_eval <<-"END_EVAL", __FILE__, __LINE__ + 1
        def count_changed?
          self.#{count_column_name}_changed?
        end

        def count_was
          self.#{count_column_name}_was
          end
      END_EVAL
    end

    internal_columns = [ancestor_id_column_name, descendant_id_column_name]

    direct_column_name.intern
    count_column_name.intern

    # links to ancestor and descendant
    belongs_to :ancestor, foreign_key: ancestor_id_column_name, class_name: acts_as_dag_options[:node_class_name]
    belongs_to :descendant, foreign_key: descendant_id_column_name, class_name: acts_as_dag_options[:node_class_name]

    if scope_column_name.present?
      validates ancestor_id_column_name.to_sym, uniqueness: { scope: [scope_column_name, descendant_id_column_name] }

      scope :reference_scope, ->(reference_id) { where(scope_column_name => reference_id) }
    else
      validates ancestor_id_column_name.to_sym, uniqueness: { scope: [descendant_id_column_name] }
    end

    scope :with_ancestor, ->(ancestor) { where(ancestor_id_column_name => ancestor.id) }

    scope :with_descendant, ->(descendant) { where(descendant_id_column_name => descendant.id) }

    scope :with_ancestor_point, ->(point) { where(ancestor_id_column_name => point.id) }

    scope :with_descendant_point, ->(point) { where(descendant_id_column_name => point.id) }

    extend Standard
    include Standard

    scope :direct, -> { where(direct: true) }

    scope :indirect, -> { where(direct: false) }

    scope :ancestor_nodes, -> { joins(:ancestor) }

    scope :descendant_nodes, -> { joins(:descendant) }

    extend Edges
    include Edges

    before_destroy :destroyable!, :perpetuate
    before_save :perpetuate
    before_validation :field_check, :fill_defaults, on: :update
    before_validation :fill_defaults, on: :create

    include ActiveModel::Validations
    validates_with CreateCorrectnessValidator, on: :create
    validates_with UpdateCorrectnessValidator, on: :update

    # internal fields
    code = "def field_check \n"
    internal_columns.each do |column|
      code += "if #{column}_changed? \n
                 raise(ActiveRecord::ActiveRecordError,
                       \"Column: #{column} cannot be changed for an existing record it is immutable\")
               end
              "
    end
    code += "end"
    module_eval code

    [count_column_name].each do |column|
      module_eval <<-"END_EVAL", __FILE__, __LINE__ + 1
        def #{column}=(x)
          raise(ActiveRecord::ActiveRecordError,
                "ERROR: Unauthorized assignment to #{column}: it's an internal field handled by acts_as_dag code.")
          end
      END_EVAL
    end
  end

  def has_dag_links(options = {})
    conf = {
      class_name: nil,
      prefix: "",
      ancestor_class_names: [],
      descendant_class_names: []
    }
    conf.update(options)

    # check that class_name is filled
    if conf[:link_class_name].nil?
      raise(ActiveRecord::ActiveRecordError, "has_dag_links must be provided with :link_class_name option")
    end

    # add trailing "_" to prefix
    conf[:prefix] += "_" unless conf[:prefix] == ""

    prefix = conf[:prefix]
    dag_link_class_name = conf[:link_class_name]
    dag_link_class = conf[:link_class_name].constantize

    class_eval <<-EOL4, __FILE__, __LINE__ + 1
      has_many :#{prefix}links_as_ancestor, foreign_key: "#{dag_link_class.ancestor_id_column_name}",
                                            class_name: "#{dag_link_class_name}"
      has_many :#{prefix}links_as_descendant, foreign_key: "#{dag_link_class.descendant_id_column_name}",
                                              class_name: "#{dag_link_class_name}"

      has_many :#{prefix}ancestors, through: :#{prefix}links_as_descendant, source: :ancestor
      has_many :#{prefix}descendants, through: :#{prefix}links_as_ancestor, source: :descendant

      has_many :#{prefix}links_as_parent, lambda { where(#{dag_link_class.direct_column_name}: true) },
                                          foreign_key: "#{dag_link_class.ancestor_id_column_name}",
                                          class_name: "#{dag_link_class_name}", inverse_of: :ancestor
      has_many :#{prefix}links_as_child, lambda { where(#{dag_link_class.direct_column_name}: true) },
                                         foreign_key: "#{dag_link_class.descendant_id_column_name}",
                                         class_name: "#{dag_link_class_name}", inverse_of: :descendant

      has_many :#{prefix}parents, through: :#{prefix}links_as_child, source: :ancestor
      has_many :#{prefix}children, through: :#{prefix}links_as_parent, source: :descendant
    EOL4

    class_eval <<-EOL5, __FILE__, __LINE__ + 1
      def #{prefix}self_and_ancestors
        [self] + #{prefix}ancestors
      end

      def #{prefix}self_and_descendants
        [self] + #{prefix}descendants
      end

      def #{prefix}leaf?
        self.#{prefix}links_as_ancestor.empty?
      end

      def #{prefix}root?
        self.#{prefix}links_as_descendant.empty?
      end
    EOL5

    if dag_link_class.scope_column_name.present?
      class_eval <<-EOL6, __FILE__, __LINE__ + 1
        def #{prefix}scoped_ancestors(scoped_id)
          #{prefix}ancestors.merge(#{dag_link_class}.reference_scope(scoped_id))
        end

        def #{prefix}scoped_descendants(scoped_id)
          #{prefix}descendants.merge(#{dag_link_class}.reference_scope(scoped_id))
        end

        def #{prefix}scoped_parents(scoped_id)
          #{prefix}parents.merge(#{dag_link_class}.reference_scope(scoped_id))
        end

        def #{prefix}scoped_children(scoped_id)
          #{prefix}children.merge(#{dag_link_class}.reference_scope(scoped_id))
        end

        def #{prefix}self_and_ancestors(scoped_id)
          [self] + #{prefix}scoped_ancestors(scoped_id)
        end

        def #{prefix}self_and_descendants(scoped_id)
          [self] + #{prefix}scoped_descendants(scoped_id)
        end

        def #{prefix}scoped_leaf?(scoped_id)
          self.#{prefix}links_as_ancestor.merge(#{dag_link_class}.reference_scope(scoped_id)).empty?
        end

        def #{prefix}scoped_root?(scoped_id)
          self.#{prefix}links_as_descendant.merge(#{dag_link_class}.reference_scope(scoped_id)).empty?
        end
      EOL6
    end
  end
end
