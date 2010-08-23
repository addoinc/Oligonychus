#!/usr/bin/ruby -w
require "mysql"
require "../lib/youtube"

begin
  youtube = YouTube::Client.new 'GTZBgTrtzyI'
  dbh = Mysql.real_connect("localhost", "harsha", "letmein", "tvgaga1")
  res = dbh.query("SELECT id,title FROM movies where trailer is null")
  while row = res.fetch_row do
    movie = row[1]+ " trailer movie"
    videos = youtube.videos_by_category_and_tag(YouTube::Category::FILMS_ANIMATION, movie)
    if videos
      dbh.query("update movies set trailer='"+videos.first.embed_url+"' where id="+row[0])
      puts "added trailer to "+row[1]
    end
  end
rescue Mysql::Error => e
  puts "Error code: #{e.errno}"
  puts "Error message: #{e.error}"
  puts "Error SQLSTATE: #{e.sqlstate}" if e.respond_to?("sqlstate")
ensure
  # disconnect from server
  dbh.close if dbh
end
