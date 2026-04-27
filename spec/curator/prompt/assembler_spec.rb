require "rails_helper"

RSpec.describe Curator::Prompt::Assembler do
  let(:kb) do
    build_stubbed(:curator_knowledge_base,
                  include_citations: true,
                  system_prompt:     nil)
  end

  def make_hit(rank:, document_name: "Doc #{rank}", page_number: nil, text: "body #{rank}")
    Curator::Hit.new(
      rank:          rank,
      chunk_id:      rank,
      document_id:   rank,
      document_name: document_name,
      page_number:   page_number,
      text:          text,
      score:         0.5,
      source_url:    nil
    )
  end

  describe "instructions half" do
    it "uses the citing default when include_citations is true and no override is set" do
      result = described_class.new.call(kb: kb, hits: [])
      expect(result[:system_prompt_text]).to include("[N]")
      expect(result[:system_prompt_text])
        .to start_with(Curator::Prompt::Templates::DEFAULT_INSTRUCTIONS_WITH_CITATIONS)
    end

    it "uses the non-citing default when include_citations is false" do
      kb_no_cite = build_stubbed(:curator_knowledge_base,
                                 include_citations: false,
                                 system_prompt:     nil)
      result = described_class.new.call(kb: kb_no_cite, hits: [])
      expect(result[:system_prompt_text]).not_to include("[N]")
      expect(result[:system_prompt_text])
        .to start_with(Curator::Prompt::Templates::DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS)
    end

    it "honors kb.system_prompt as the instructions half and keeps the context block" do
      kb_override = build_stubbed(:curator_knowledge_base,
                                  include_citations: true,
                                  system_prompt:     "Custom instructions.")
      hits   = [ make_hit(rank: 1, document_name: "alpha.md", text: "first body") ]
      result = described_class.new.call(kb: kb_override, hits: hits)

      expect(result[:system_prompt_text]).to start_with("Custom instructions.")
      expect(result[:system_prompt_text]).not_to include("[N]")
      expect(result[:system_prompt_text]).to include(%([1] From "alpha.md":\nfirst body))
    end

    it "treats blank kb.system_prompt as no override" do
      kb_blank = build_stubbed(:curator_knowledge_base,
                               include_citations: true,
                               system_prompt:     "   ")
      result = described_class.new.call(kb: kb_blank, hits: [])
      expect(result[:system_prompt_text])
        .to start_with(Curator::Prompt::Templates::DEFAULT_INSTRUCTIONS_WITH_CITATIONS)
    end
  end

  describe "context block" do
    it "renders each hit with rank, document, and text" do
      hits = [
        make_hit(rank: 1, document_name: "alpha.md", text: "first body"),
        make_hit(rank: 2, document_name: "beta.md",  text: "second body")
      ]
      text = described_class.new.call(kb: kb, hits: hits)[:system_prompt_text]
      expect(text).to include(%([1] From "alpha.md":\nfirst body))
      expect(text).to include(%([2] From "beta.md":\nsecond body))
    end

    it "includes the page parenthetical when page_number is present" do
      hits = [ make_hit(rank: 1, document_name: "alpha.md", page_number: 7, text: "body") ]
      text = described_class.new.call(kb: kb, hits: hits)[:system_prompt_text]
      expect(text).to include(%([1] From "alpha.md" (page 7):\nbody))
    end

    it "omits the page parenthetical when page_number is nil" do
      hits = [ make_hit(rank: 1, document_name: "alpha.md", page_number: nil, text: "body") ]
      text = described_class.new.call(kb: kb, hits: hits)[:system_prompt_text]
      expect(text).to include(%([1] From "alpha.md":\nbody))
      expect(text).not_to match(/\(page /)
    end

    it "separates hits with a blank line" do
      hits = [
        make_hit(rank: 1, text: "first"),
        make_hit(rank: 2, text: "second")
      ]
      text = described_class.new.call(kb: kb, hits: hits)[:system_prompt_text]
      expect(text).to match(/first\n\n\[2\]/)
    end

    it "emits no context block when hits is empty" do
      text = described_class.new.call(kb: kb, hits: [])[:system_prompt_text]
      expect(text).to eq(Curator::Prompt::Templates::DEFAULT_INSTRUCTIONS_WITH_CITATIONS)
    end

    it "joins instructions and context with a single blank line" do
      hits = [ make_hit(rank: 1, document_name: "alpha.md", text: "first body") ]
      text = described_class.new.call(kb: kb, hits: hits)[:system_prompt_text]
      separator = "\n\n#{described_class::CONTEXT_HEADER}\n\n"
      expect(text).to include(separator)
      expect(text.scan(separator).length).to eq(1)
    end
  end

  describe "system_prompt_hash" do
    it "is stable for identical inputs" do
      hits   = [ make_hit(rank: 1, text: "same body") ]
      first  = described_class.new.call(kb: kb, hits: hits)[:system_prompt_hash]
      second = described_class.new.call(kb: kb, hits: hits)[:system_prompt_hash]
      expect(first).to eq(second)
    end

    it "differs when hits differ" do
      h1 = described_class.new.call(kb: kb, hits: [ make_hit(rank: 1, text: "alpha") ])
      h2 = described_class.new.call(kb: kb, hits: [ make_hit(rank: 1, text: "beta") ])
      expect(h1[:system_prompt_hash]).not_to eq(h2[:system_prompt_hash])
    end

    it "matches SHA256 of system_prompt_text" do
      result = described_class.new.call(kb: kb, hits: [])
      expect(result[:system_prompt_hash])
        .to eq(Digest::SHA256.hexdigest(result[:system_prompt_text]))
    end
  end

  describe "prompt_token_estimate" do
    it "matches Curator::TokenCounter.count of the assembled text" do
      result = described_class.new.call(kb: kb, hits: [ make_hit(rank: 1) ])
      expect(result[:prompt_token_estimate])
        .to eq(Curator::TokenCounter.count(result[:system_prompt_text]))
      expect(result[:prompt_token_estimate]).to be_a(Integer).and(be > 0)
    end
  end
end
