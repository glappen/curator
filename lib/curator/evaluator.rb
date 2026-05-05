module Curator
  # Service object for `Curator.evaluate`. Canonical write path for
  # creating evaluations from admin and host-app code alike.
  #
  # Both new and update flows go through here: pass `evaluation_id:` to
  # update an existing row in place (used by Console's edit-in-place
  # rating flow); omit it to create a new row.
  class Evaluator
    EVALUATOR_ROLES = %i[reviewer end_user].freeze

    def self.call(*args, **kwargs) = new(*args, **kwargs).call

    def initialize(retrieval:, rating:, evaluator_role:,
                   evaluator_id: nil, feedback: nil, ideal_answer: nil,
                   failure_categories: [], evaluation_id: nil)
      @retrieval          = retrieval
      @rating             = rating
      @evaluator_role     = evaluator_role
      @evaluator_id       = evaluator_id
      @feedback           = feedback
      @ideal_answer       = ideal_answer
      @failure_categories = Array(failure_categories)
      @evaluation_id      = evaluation_id
    end

    def call
      validate_rating!
      validate_evaluator_role!

      retrieval = resolve_retrieval

      attrs = {
        rating:             @rating.to_s,
        evaluator_role:     @evaluator_role.to_s,
        evaluator_id:       @evaluator_id,
        feedback:           @feedback,
        ideal_answer:       @ideal_answer,
        failure_categories: @failure_categories
      }

      if @evaluation_id
        evaluation = retrieval.evaluations.find(@evaluation_id)
        evaluation.update!(attrs)
        evaluation
      else
        retrieval.evaluations.create!(attrs)
      end
    end

    private

    def validate_rating!
      return if Curator::Evaluation::RATINGS.include?(@rating.to_sym)

      raise ArgumentError,
            "rating must be one of #{Curator::Evaluation::RATINGS.inspect} (got #{@rating.inspect})"
    end

    def validate_evaluator_role!
      return if EVALUATOR_ROLES.include?(@evaluator_role.to_sym)

      raise ArgumentError,
            "evaluator_role must be one of #{EVALUATOR_ROLES.inspect} (got #{@evaluator_role.inspect})"
    end

    def resolve_retrieval
      return @retrieval if @retrieval.is_a?(Curator::Retrieval)

      Curator::Retrieval.find(@retrieval)
    end
  end
end
