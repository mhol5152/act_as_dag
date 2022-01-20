module Dag
  # Validations on model instance creation. Ensures no duplicate links, no cycles, correct count and direct attributes
  class CreateCorrectnessValidator < ActiveModel::Validator
    def validate(record)
      record.errors.add(:base, "Link already exists between these points") if duplicates?(record)
      record.errors.add(:base, "Link already exists in the opposite direction") if long_cycles?(record)
      record.errors.add(:base, "Link must start and end in different places") if short_cycles?(record)
      cnt = check_possible(record)
      record.errors.add(:base, "Cannot create a direct link with a count other than 0") if cnt == 1
      record.errors.add(:base, "Cannot create an indirect link with a count less than 1") if cnt == 2
    end

    private

    # Check for duplicates
    def duplicates?(record)
      record.class.find_link(record.source, record.sink)
    end

    # Check for long cycles
    def long_cycles?(record)
      record.class.find_link(record.sink, record.source)
    end

    # Check for short cycles
    def short_cycles?(record)
      record.sink.matches?(record.source)
    end

    # Check not impossible
    def check_possible(record)
      if record.direct?
        record.count.positive? ? 1 : 0
      else
        record.count < 1 ? 2 : 0
      end
    end
  end

  # Validations on update. Makes sure that something changed, that not making a lonely link indirect, count is correct.
  class UpdateCorrectnessValidator < ActiveModel::Validator
    def validate(record)
      record.errors.add(:base, "No changes") unless record.changed?
      record.errors.add(:base, "Do not manually change the count value") if manual_change?(record)
      record.errors.add(:base, "Cannot make a direct link with count 1 indirect") if direct_indirect?(record)
    end

    private

    def manual_change?(record)
      record.direct_changed? && record.count_changed?
    end

    def direct_indirect?(record)
      record.direct_changed? && !record.direct? && record.count == 1
    end
  end
end
