module Curator
  class Evaluation < ApplicationRecord
    self.table_name = "curator_evaluations"

    RATINGS = %i[positive negative].freeze

    FAILURE_CATEGORIES = %w[
      hallucination
      wrong_retrieval
      incomplete
      wrong_citation
      refused_incorrectly
      off_topic
      other
    ].freeze

    FAILURE_CATEGORY_TOOLTIPS = {
      "hallucination"       => "The answer states facts that aren't supported by any retrieved source.",
      "wrong_retrieval"     => "The retrieved sources aren't relevant to the question.",
      "incomplete"          => "The right sources were retrieved, but the answer omits relevant information from them.",
      "wrong_citation"      => "A citation marker points to a source that doesn't actually support the claim.",
      "refused_incorrectly" => "The answer says \"I don't know\" but the information exists in the knowledge base.",
      "off_topic"           => "The answer doesn't address the question being asked.",
      "other"               => "Something else is wrong — please describe in the feedback field."
    }.freeze

    belongs_to :retrieval, class_name: "Curator::Retrieval"

    enum :rating, RATINGS.index_with(&:to_s)

    validate :failure_categories_are_known
    validate :failure_categories_only_on_negative

    # Distinct chat_models drawn from retrievals that have at least one
    # evaluation. Used to populate the chat-model filter dropdown on the
    # Evaluations index — restricting to evaluated retrievals means the
    # dropdown only surfaces values that can actually narrow the list.
    def self.distinct_chat_models
      joins(:retrieval)
        .where.not(curator_retrievals: { chat_model: nil })
        .distinct
        .order("curator_retrievals.chat_model")
        .pluck("curator_retrievals.chat_model")
    end

    private

    def failure_categories_are_known
      unknown = Array(failure_categories) - FAILURE_CATEGORIES
      return if unknown.empty?

      errors.add(:failure_categories, "contains unknown values: #{unknown.join(', ')}")
    end

    def failure_categories_only_on_negative
      return if Array(failure_categories).empty?
      return if rating == "negative"

      errors.add(:failure_categories, "are only allowed on :negative evaluations")
    end
  end
end
