require "rails_helper"
require "rake"

RSpec.describe "curator rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("curator:seed_defaults")
  end

  describe "curator:seed_defaults" do
    let(:task) { Rake::Task["curator:seed_defaults"] }

    after { task.reenable }

    def silently(&block)
      original = $stdout
      $stdout  = StringIO.new
      block.call
    ensure
      $stdout = original
    end

    it "creates exactly one default KB on a fresh DB" do
      expect { silently { task.invoke } }.to change(Curator::KnowledgeBase, :count).from(0).to(1)

      kb = Curator::KnowledgeBase.find_by(is_default: true)
      expect(kb.slug).to eq("default")
    end

    it "is a no-op on a second run" do
      silently { task.invoke }
      task.reenable

      expect { silently { task.invoke } }.not_to change(Curator::KnowledgeBase, :count)
    end
  end
end
