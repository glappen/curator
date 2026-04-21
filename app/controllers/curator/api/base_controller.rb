module Curator
  module Api
    class BaseController < ActionController::API
      include Curator::Authentication

      curator_authenticate :api
    end
  end
end
