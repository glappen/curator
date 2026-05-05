module Curator
  class KnowledgeBasesController < ApplicationController
    # Strong-params permit list, partitioned by form action. `embedding_model`
    # and `slug` are creation-time-only — `update` permits the editable subset
    # so a hand-crafted POST can't bypass the `disabled` form attributes and
    # corrupt embeddings or break URLs.
    EDITABLE_PARAMS = %i[
      name description is_default
      retrieval_strategy chunk_limit similarity_threshold
      tsvector_config include_citations strict_grounding
      chunk_size chunk_overlap chat_model system_prompt
    ].freeze
    LOCKED_PARAMS = %i[embedding_model slug].freeze

    before_action :set_knowledge_base, only: %i[show edit update destroy]
    before_action :set_model_options, only: %i[new edit create update]

    def index
      @knowledge_bases = KnowledgeBase.order(:name, :id)
      # Two grouped aggregates — constant query count independent of the
      # number of KBs. Without these the card partial issues `count` +
      # `maximum(:created_at)` per KB on every render.
      @doc_counts    = Document.group(:knowledge_base_id).count
      @last_ingested = Document.group(:knowledge_base_id).maximum(:created_at)
    end

    def show; end

    def new
      @knowledge_base = KnowledgeBase.new(
        embedding_model: KnowledgeBase::DEFAULT_EMBEDDING_MODEL,
        chat_model:      KnowledgeBase::DEFAULT_CHAT_MODEL
      )
    end

    def create
      @knowledge_base = KnowledgeBase.new(create_params)

      if @knowledge_base.save
        redirect_to knowledge_base_path(@knowledge_base),
                    notice: "Knowledge base \"#{@knowledge_base.name}\" created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @knowledge_base.update(update_params)
        redirect_to knowledge_base_path(@knowledge_base),
                    notice: "Knowledge base \"#{@knowledge_base.name}\" updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      name = @knowledge_base.name
      # Sync destroy in v1: cascades to documents → chunks → embeddings →
      # retrievals via dependent: :destroy. Operators rarely delete KBs;
      # accepting the latency over an async :deleting status flow.
      @knowledge_base.destroy!
      redirect_to root_path, notice: "Knowledge base \"#{name}\" deleted."
    end

    private

    def set_knowledge_base
      @knowledge_base = KnowledgeBase.find_by!(slug: params[:slug])
    end

    # Re-resolved on every form render (including create/update validation
    # re-renders) so the (custom)-group fallback reflects whatever model
    # value the user last typed, not just the persisted one.
    def set_model_options
      current_chat      = @knowledge_base&.chat_model      || params.dig(:knowledge_base, :chat_model)
      current_embedding = @knowledge_base&.embedding_model || params.dig(:knowledge_base, :embedding_model)
      @chat_model_options      = ModelOptions.chat(current_chat)
      @embedding_model_options = ModelOptions.embedding(current_embedding)
    end

    def create_params
      params.require(:knowledge_base).permit(permitted_params(action: :create))
    end

    def update_params
      params.require(:knowledge_base).permit(permitted_params(action: :update))
    end

    def permitted_params(action:)
      case action.to_sym
      when :new, :create then EDITABLE_PARAMS + LOCKED_PARAMS
      when :edit, :update then EDITABLE_PARAMS
      else raise ArgumentError, "unknown action: #{action.inspect}"
      end
    end
  end
end
