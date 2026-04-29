module Curator
  class KnowledgeBasesController < ApplicationController
    before_action :set_knowledge_base, only: %i[show edit update destroy]

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

    def create_params
      params.require(:knowledge_base)
            .permit(KnowledgeBase.permitted_params(action: :create))
    end

    def update_params
      params.require(:knowledge_base)
            .permit(KnowledgeBase.permitted_params(action: :update))
    end
  end
end
