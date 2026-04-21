module Curator
  class ApplicationController < ActionController::Base
    include Curator::Authentication

    curator_authenticate :admin
  end
end
