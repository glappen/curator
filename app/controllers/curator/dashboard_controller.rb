module Curator
  class DashboardController < ApplicationController
    def index
      render plain: "Curator"
    end
  end
end
