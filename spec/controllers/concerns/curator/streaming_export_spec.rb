require "rails_helper"
require "csv"
require "json"

RSpec.describe Curator::StreamingExport, type: :controller do
  controller(ApplicationController) do
    include Curator::StreamingExport

    def csv_action
      rows = [ { name: "alpha", count: 1 }, { name: "beta", count: 2 } ]
      stream_csv(io: response.stream, rows: rows, columns: %i[name count]) { |r| r }
    end

    def json_action
      rows = [ { name: "alpha", count: 1 }, { name: "beta", count: 2 } ]
      stream_json(io: response.stream, rows: rows) { |r| r }
    end
  end

  before do
    routes.draw do
      get "csv_action"  => "anonymous#csv_action"
      get "json_action" => "anonymous#json_action"
    end
  end

  describe "#stream_csv" do
    it "writes a header and one row per item" do
      get :csv_action
      lines = response.body.lines(chomp: true)
      expect(lines[0]).to eq("name,count")
      expect(lines[1]).to eq("alpha,1")
      expect(lines[2]).to eq("beta,2")
    end
  end

  describe "#stream_json" do
    it "writes a single JSON array" do
      get :json_action
      parsed = JSON.parse(response.body)
      expect(parsed).to eq([
        { "name" => "alpha", "count" => 1 },
        { "name" => "beta", "count" => 2 }
      ])
    end
  end
end
