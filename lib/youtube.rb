require 'rubygems'
require 'net/http'
require 'xmlsimple'
require 'cgi'

module YouTube

  class Category
    FILMS_ANIMATION = 1
    AUTOS_VEHICLES = 2
    COMEDY = 23
    ENTERTAINMENT = 24
    MUSIC = 10
    NEWS_POLITICS = 25
    PEOPLE_BLOGS = 22
    PETS_ANIMALS = 15
    HOWTO_DIY = 26
    SPORTS = 17
    TRAVEL_PLACES = 19
    GADGETS_GAMES = 20
  end

  class Client

    DEFAULT_HOST = 'http://www.youtube.com'
    DEFAULT_API_PATH = '/api2_rest'

    def initialize(dev_id = nil, host = DEFAULT_HOST, api_path = DEFAULT_API_PATH)
      raise "developer id required" unless dev_id

      @host = host
      @api_path = api_path
      @dev_id = dev_id
    end

    def favorite_videos(username)
      response = users_list_favorite_videos(:user => username)
      _parse_video_response(response)
    end

    def videos_by_tag(tag, page = 1, per_page = 20)
      response = videos_list_by_tag(:tag => tag, :page => page, :per_page => per_page)
      _parse_video_response(response)
    end

    def videos_by_related(tag, page = 1, per_page = 20)
      response = videos_list_by_related(:tag => tag, :page => page, :per_page => per_page)
      _parse_video_response(response)
    end

    def videos_by_playlist(id, page = 1, per_page = 20)
      response = videos_list_by_playlist(:id => id, :page => page, :per_page => per_page)
      _parse_video_response(response)
    end

    def videos_by_category_id_and_tag(id, tag, page = 1, per_page = 20)
      response = videos_list_by_category_and_tag(:category_id => id, :tag => tag, :page => page, :per_page => per_page)
      _parse_video_response(response)
    end

    def videos_by_category_and_tag(category, tag, page = 1, per_page = 20)
      videos_by_category_id_and_tag(category, tag, page, per_page)
    end

    def videos_by_user(username, page = 1, per_page = 20)
      response = videos_list_by_user(:user => username, :page => page, :per_page => per_page)
       _parse_video_response(response)
     end

    def featured_videos
      response = videos_list_featured
      _parse_video_response(response)
    end

    def video_details(video_id)
      raise ArgumentError.new("invalid video id parameter, must be string") unless video_id.is_a?(String)
      response = videos_get_details(:video_id => video_id)
      VideoDetails.new(response['video_details'])
    end

    private

      def method_missing(method_id, *params)
        _request(method_id.to_s.sub('_', '.'), *params)
      end

      def _request(method, *params)
        url = _request_url(method, *params)
        response = XmlSimple.xml_in(_http_get(url), { 'ForceArray' => [ 'video', 'friend' ] })
        raise response['error']['description'] + " : url=#{url}" unless response['status'] == 'ok'
        response
      end

      def _request_url(method, *params)
        param_list = String.new
        unless params.empty?
          params.first.each_pair { |k, v| param_list << "&#{k.to_s}=#{CGI.escape(v.to_s)}" }
        end
        url = "#{@host}#{@api_path}?method=youtube.#{method}&dev_id=#{@dev_id}#{param_list}"
      end

      def _http_get(url)
        Net::HTTP.get_response(URI.parse(url)).body.to_s
      end

      def _parse_video_response(response)
        videos = response['video_list']['video']
        videos.is_a?(Array) ? videos.compact.map { |video| Video.new(video) } : nil
      end
  end

  class Video
    attr_reader :author
    attr_reader :comment_count
    attr_reader :description
    attr_reader :embed_url
    attr_reader :id
    attr_reader :length_seconds
    attr_reader :rating_avg
    attr_reader :rating_count
    attr_reader :tags
    attr_reader :thumbnail_url
    attr_reader :title
    attr_reader :upload_time
    attr_reader :url
    attr_reader :view_count

    def initialize(payload)
      @author = payload['author'].to_s
      @comment_count = payload['comment_count'].to_i
      @description = payload['description'].to_s
      @id = payload['id']
      @length_seconds = payload['length_seconds'].to_i
      @rating_avg = payload['rating_avg'].to_f
      @rating_count = payload['rating_count'].to_i
      @tags = payload['tags']
      @thumbnail_url = payload['thumbnail_url']
      @title = payload['title'].to_s
      @upload_time = YouTube._string_to_time(payload['upload_time'])
      @url = payload['url']
      @view_count = payload['view_count'].to_i

      # the url provided via the API links to the video page -- for
      # convenience, generate the url used to embed in a page
      @embed_url = @url.delete('?').sub('=', '/')
    end

    def embed_html(width = 425, height = 350)
      <<edoc
<object width="#{width}" height="#{height}">
  <param name="movie" value="#{embed_url}"></param>
  <param name="wmode" value="transparent"></param>
  <embed src="#{embed_url}" type="application/x-shockwave-flash"
   wmode="transparent" width="#{width}" height="#{height}"></embed>
</object>
edoc
    end
  end

  class VideoDetails
    attr_reader :author
    attr_reader :channel_list
    attr_reader :comment_list
    attr_reader :description
    attr_reader :length_seconds
    attr_reader :rating_avg
    attr_reader :rating_count
    attr_reader :recording_location
    attr_reader :recording_country
    attr_reader :recording_date
    attr_reader :tags
    attr_reader :thumbnail_url
    attr_reader :title
    attr_reader :update_time
    attr_reader :upload_time
    attr_reader :view_count
    attr_reader :embed_status
    attr_reader :embed_allowed

    def initialize(payload)
      @author = payload['author'].to_s
      @channel_list = payload['channel_list']
      @comment_list = payload['comment_list']
      @description = payload['description'].to_s
      @length_seconds = payload['length_seconds'].to_i
      @rating_avg = payload['rating_avg'].to_f
      @rating_count = payload['rating_count'].to_i
      @recording_country = payload['recording_country'].to_s
      @recording_date = payload['recording_date'].to_s
      @recording_location = payload['recording_location'].to_s
      @tags = payload['tags']
      @thumbnail_url = payload['thumbnail_url']
      @title = payload['title'].to_s
      @update_time = YouTube._string_to_time(payload['update_time'])
      @upload_time = YouTube._string_to_time(payload['upload_time'])
      @view_count = payload['view_count'].to_i
      @embed_status = payload['embed_status']
      @embed_allowed = ( payload['embed_status'] == "ok" )
    end
  end

  private

    def self._string_to_boolean(bool_str)
      (bool_str && bool_str.downcase == "true")
    end


    def self._string_to_time(time_str)
      (time_str) ? Time.at(time_str.to_i) : nil
    end
end
