#!/usr/bin/perl
use DBI;
use IMDB::Persons;
use LWP::Simple qw(get);
use IO::File;
use Error qw(:try);
use lib qw(../lib/);
use Yahoo::Movies;

sub trim($);

sub trim($)
{
  my $string = shift;
  $string =~ s/^\s+//;
  $string =~ s/\s+$//;
  $string =~ s/["',]//g;
  return $string;
}

sub fetch_cover_img {
  my ($movie_id,$url) = @_;
  my $cover_img = get($url);
  my $img_file = $movie_id."_cover.jpg";
  open (IMG,">../data/images/$img_file") || die ("cannot open file");
  print IMG "$cover_img";
  close IMG;
  return $img_file;
}

my $db="tvgaga_dev2";
my $host="localhost";
my $userid="tvgaga";
my $passwd="azrihyd";
my $connectionInfo="dbi:mysql:$db:$host";
my $dbh= DBI->connect($connectionInfo,$userid,$passwd);
open (FILE, "../data/yahoomovies") || die "couldn't open the file!";
open(ERR,">../data/errmovies") || die("Cannot open file");

while ($moviename = <FILE>) {
  if ($moviename) {
    $moviename=trim($moviename);
    try {
      my $movie = new Yahoo::Movies(id => $moviename);
      if ($movie->error() eq '0') {
        my $title=trim($movie->title());
        my $descr=trim(substr($movie->plot_summary(), 0, 90)." ...");
        my $plot=trim($movie->plot_summary());
        my $cover_img_url=$movie->cover;
        my $year=$movie->year();
        my $movie_query = $dbh->prepare("select id from movies where title = \"$title\"");
        $movie_query->execute;
        my($movie_id) = $movie_query->fetchrow_array;
        if ( $movie_id eq '') {

            $dbh->do("insert into movies (title,description,plotline,year) values (\"$title\",\"$descr\",\"$plot\",\"$year\")");
            $movie_query->execute;
            $movie_id = $movie_query->fetchrow_array;
            if ($cover_img_url) {
              my $cover_img = fetch_cover_img($movie_id,$cover_img_url);
              $dbh->do("update movies set cover_image='$cover_img' where id=$movie_id");
            }
            my $cast = $movie->cast;
            for(@$cast) {
              my $actor_name = $_->[1];
              my $actor_query = $dbh->prepare("select id from actors where name = '$actor_name'");
              $actor_query->execute;
              my($actor_id) = $actor_query->fetchrow_array;
              if ($actor_id eq '') {
                my $person = new IMDB::Persons(crit => $actor_name);
                if($person->status) {
                  my $name=$person->name();
                  $name =~ s/['",]//g;
                  my $url = $person->photo();
                  my $dob = trim($person->date_of_birth());
                  my $place_of_birth = trim($person->place_of_birth());
                  my $bio = trim($person->mini_bio());
                  $dbh->do("insert into actors(name,url,bio,dob,place_of_birth) values(\"$name\",\"$url\",\"$bio\",\"$dob\",\"$place_of_birth\")");
                }
              }
              $actor_query->execute;
              $actor_id = $actor_query->fetchrow_array;
              $dbh->do("insert into cast_items_map(item_id_one,item_id_two) values(?,?)",undef,$movie_id,$actor_id);
            }

            my $directors = $movie->directors;
            for(@$directors) {
              my $director=$_->[1];
              my $director_query = $dbh->prepare("select id from directors where name = '$director'");
              $director_query->execute;
              my($director_id) = $director_query->fetchrow_array;
              if ($director_id eq '') {
                my $person = new IMDB::Persons(crit => $director);
                if($person->status) {
                  my $name=$person->name();
                  $name =~ s/['",]//g;
                   my $url = $person->photo();
                   my $dob = trim($person->date_of_birth());
                   my $place_of_birth = trim($person->place_of_birth());
                   my $bio = trim($person->mini_bio());
                   $dbh->do("insert into directors(name,url,bio,dob,place_of_birth) values(\"$name\",\"$url\",\"$bio\",\"$dob\",\"$place_of_birth\")");
                 }
                }
                $director_query->execute;
                $director_id = $director_query->fetchrow_array;
                $dbh->do("insert into directors_items_map(item_id_one,item_id_two) values(?,?)",undef,$movie_id,$director_id);
            }

            my @genres = @{$movie->genres};
            foreach $id (0 .. $#genres) {
                my $genre_name = $genres[$id];
                my $genre_query = $dbh->prepare("select id from genres where name = '$genre_name'");
                $genre_query->execute;
                my($genre_id) = $genre_query->fetchrow_array;
                if ($genre_id eq '') {
                    $dbh->do("insert into genres(name) values(?)",undef,$genre_name);
                }
                $genre_query->execute;
                $genre_id = $genre_query->fetchrow_array;
                $dbh->do("insert into genre_items_map(item_id_one,item_id_two) values(?,?)",undef,$movie_id,$genre_id);
              }
            print $moviename." saved \n";
          } else {
            print $moviename." exists \n";
          }
        } else {
            print "Unable to retrieve movie info ".$moviename."\n";
            print ERR "$moviename\n";
          }
     } catch Error with {
           print "Error while retrieving movie" .$moviename;

         }
   }
}

close(FILE);

