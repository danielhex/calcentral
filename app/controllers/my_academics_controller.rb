class MyAcademicsController < ApplicationController

  before_filter :api_authenticate

  def get_feed
    render :json => MyAcademics::Merged.from_session(session).get_feed_as_json
  end

end
