require "rails_helper"

# Frozen public-API contract for `Curator::Chat` / `Curator.chat`.
# Phase 3a ships method signatures only; Phase 3b lands the real
# `#ask` orchestration via `Curator::ChatAsker`. Phase 4 (the
# `curator:chat_ui` generator) develops in parallel against this
# contract — keep these expectations stable so the generator's
# request specs can rely on them.
RSpec.describe "Curator.chat contract" do
  let!(:kb) { create(:curator_knowledge_base) }

  describe ".chat argument shape" do
    it "raises ArgumentError when neither knowledge_base nor id is passed" do
      expect { Curator.chat }
        .to raise_error(ArgumentError, /knowledge_base.*id|id.*knowledge_base/)
    end

    it "raises ArgumentError when both knowledge_base and id are passed" do
      expect { Curator.chat(knowledge_base: kb, id: 999_999) }
        .to raise_error(ArgumentError, /not both/)
    end
  end

  describe "creation" do
    it "returns a Curator::Chat when given a KB instance" do
      wrapper = Curator.chat(knowledge_base: kb)

      expect(wrapper).to be_a(Curator::Chat)
      expect(wrapper.knowledge_base).to eq(kb)
      expect(wrapper.id).to be_a(Integer)
      expect(wrapper.raw).to be_a(::Chat)
    end

    it "resolves a KB slug" do
      wrapper = Curator.chat(knowledge_base: kb.slug)

      expect(wrapper.knowledge_base).to eq(kb)
    end

    it "persists a curator_chat_bindings row pinning the KB" do
      expect { Curator.chat(knowledge_base: kb) }
        .to change(Curator::ChatBinding, :count).by(1)
        .and change(::Chat, :count).by(1)

      binding = Curator::ChatBinding.last
      expect(binding.knowledge_base).to eq(kb)
      expect(binding.chat_id).to eq(::Chat.last.id)
    end
  end

  describe "resumption" do
    it "rehydrates the same chat + KB by id" do
      original = Curator.chat(knowledge_base: kb)
      resumed  = Curator.chat(id: original.id)

      expect(resumed).to be_a(Curator::Chat)
      expect(resumed.id).to eq(original.id)
      expect(resumed.knowledge_base).to eq(kb)
      expect(resumed.raw.id).to eq(original.raw.id)
    end

    it "raises RecordNotFound when no binding exists for the id" do
      expect { Curator.chat(id: 999_999) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "#ask (Phase 3b)" do
    it "raises NotImplementedError until Phase 3b lands" do
      wrapper = Curator.chat(knowledge_base: kb)

      expect { wrapper.ask("hi") }.to raise_error(NotImplementedError, /Phase 3b/)
    end
  end

  describe "#history (Phase 3b)" do
    it "raises NotImplementedError until Phase 3b lands" do
      wrapper = Curator.chat(knowledge_base: kb)

      expect { wrapper.history }.to raise_error(NotImplementedError, /Phase 3b/)
    end
  end
end
