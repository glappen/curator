module Curator
  class ConsoleController < ApplicationController
    include ActionController::Live

    def show
      @knowledge_base  = KnowledgeBase.resolve(params[:knowledge_base_slug])
      @knowledge_bases = KnowledgeBase.order(:name, :id)
    end

    def run
      # TODO Phase 2B: stream Asker output through Curator::Streaming::TurboStream.
      head :not_implemented
    end
  end
end
