#!/usr/bin/perl
use strict;
use warnings;

BEGIN {
	if ( -e $ENV{OLIGONYCHUS_HOME} && -d $ENV{OLIGONYCHUS_HOME} ) {
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/lib/");
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/conf/");
	} else {
		print "Error(1): Environment variable OLIGONYCHUS_HOME incorrect/not set.\n";
	}
};

use Getopt::Long;
use DBI;
use IMDB::Film;
use IMDB::Persons;
use LWP::RobotUA;
use LWP::Simple qw(get);
use IO::File;
use Error qw(:try);

my $channel_id;
my $sched_csv = '';

my $res = GetOptions(
	'file=s' => sub {
		my ($k, $v) = @_;
		unless ( -e $v && -f $v ) {
			print "Invalid file: $v\n";
	        } else {
			$sched_csv = $v;
		}
	}
);

die "No file to load!\n" unless ( $sched_csv );

my $dbh = DBI->connect(
	"dbi:mysql:tvgaga_dev2:localhost",,
	'tvgaga',
	'azrihyd',
);

sub trim($) {

	my $string = shift;

	if ( $string ) {
		$string =~ s/^\s+//;
		$string =~ s/\s+$//;
		$string =~ s/["']//g;
	}

	return $string;
}


sub fetch_cover_img {

	my ($movie_id,$url) = @_;
	my $cover_img = get($url);
	my $img_file = $movie_id."_cover.jpg";

	open (IMG,">$ENV{OLIGONYCHUS_HOME}/data/images/$img_file") || die ("cannot open file");
	print IMG "$cover_img";
	close IMG;

	return $img_file;
}

open(ERR,">$ENV{OLIGONYCHUS_HOME}/data/yahoomovies") || die("Cannot open file");
open (CSV, "<", $sched_csv) || die $!;

while (<CSV>) {

	chomp;

	if ( $. == 1 ) {

		my $getchan = $dbh->prepare(qq~
		select id from channels where name like ?
		~);
		$getchan->execute( $_ );
		($channel_id) = $getchan->fetchrow_array;

		die "Channel $_ not found.\n" unless ( $channel_id );

		next;
	}

	my @columns = split /(?<!\\),/;

	unless ( scalar(@columns) ) {
		next;
	}

	my $imdb_moviename = $columns[2];
	$imdb_moviename =~ s~\\,~,~g;
	my $sched_date = $columns[0];
	$sched_date =~ s~(\d/\d+/\d+)~0$1~ if ( $sched_date =~ m~^\d/~ );
	my $start_time = $columns[1];
	$start_time =~ s/^(\d:\d\d)$/0$1/;
	my $duration = $columns[3];
	my $imdbObj;

	eval {
		$imdbObj = new IMDB::Film(crit => $imdb_moviename);
	};
	if ( $@ ) {
		print $@, "\n";
	}

	if($imdbObj->status) {

		my $title=$imdbObj->title();
		my $descr=$imdbObj->plot();
		my $plot=$imdbObj->full_plot();
		my $year=$imdbObj->year();
		my $cover_img_url=$imdbObj->cover();
		my $ratings=$imdbObj->rating();

		print $title, "\n\n";
		$title = trim($title);
		$descr = trim($descr);
		$plot = trim($plot);

		my $movie_query = $dbh->prepare(qq~
		select id from movies where title = ?
		~);
		$movie_query->execute( $title );
		my($movie_id) = $movie_query->fetchrow_array;
		$movie_id ||= '';

		if ( $movie_id eq '') {

			$title ||= ''; $descr ||= ''; $plot ||= '';
			$year ||= ''; $ratings ||= '';

			$dbh->do(qq~
			insert into movies(
				title,description,plotline,color,year,ratings
			)
			values (
				"$title", "$descr", "$plot", 'color', "$year",
				"$ratings"
			)
			~);

			$movie_query->execute;
			($movie_id) = $movie_query->fetchrow_array;

			if ($cover_img_url) {

				my $cover_img = fetch_cover_img(
					$movie_id, $cover_img_url
				);
				$dbh->do(qq~
				update movies set cover_image="$cover_img"
				where id=$movie_id
				~);
			}
			my @writers = @{$imdbObj->writers()};

			foreach my $id (0 .. $#writers) {

				my $writer_name = $writers[$id]{name};
				$writer_name = trim($writer_name);

				if ( $writer_name ne '' ) {

					my $writer_query = $dbh->prepare(qq~
					select id from writers where name = "$writer_name"
					~);
					$writer_query->execute;

					my($writer_id) = $writer_query->fetchrow_array;
					$writer_id ||= '';

					if ($writer_id eq '') {
						my $person = new IMDB::Persons(
							crit => $writer_name
						);

						if($person->status) {

							my $name=trim($person->name());
							my $url = $person->photo();
							my $dob =trim($person->date_of_birth());
							my $place_of_birth = trim(
								$person->place_of_birth()
							);
							my $bio = trim($person->mini_bio());
							$name ||= '';
							$url ||= '';
							$dob ||= '';
							$place_of_birth ||= '';

							$dbh->do(qq~
							insert into writers(name,url,bio,dob,place_of_birth) values ("$name", "$url", "$bio", "$dob","$place_of_birth")
							~) if ( $name );
						}
					}
					$writer_query->execute;
					($writer_id) = $writer_query->fetchrow_array;
					$writer_id ||= '';
					$dbh->do(qq~
					insert into writers_items_map(
						item_id_one,item_id_two
					) values(?,?)~,
						undef, $movie_id, $writer_id
					) if ( $writer_id );
				}
			}

			my @directors = @{$imdbObj->directors()};

			foreach my $id (0 .. $#directors) {

				my $director_name = $directors[$id]{name};

				my $director_query = $dbh->prepare(qq~
					select id from directors where name = "$director_name"
				~);
				$director_query->execute;
				my($director_id) = $director_query->fetchrow_array;
				$director_id ||= '';

				if ($director_id eq '') {

					my $person = new IMDB::Persons(crit => $director_name);

					if($person->status) {

						my $name=trim($person->name());
						my $url = $person->photo();
						my $dob = trim($person->date_of_birth());
						my $place_of_birth = trim(
							$person->place_of_birth()
						);
						my $bio = trim($person->mini_bio());
						$name ||= '';
						$url ||= '';
						$dob ||= '';
						$place_of_birth ||= '';
						$bio ||= '';

						$dbh->do(qq~
						insert into directors(
						name,url,bio,dob,place_of_birth
						) values(
						"$name", "$url", "$bio", "$dob",
						"$place_of_birth")
						~) if ( $name );

					}
				}

				$director_query->execute;
				($director_id) = $director_query->fetchrow_array;
				$director_id ||= '';
				$dbh->do(qq~
				insert into directors_items_map(item_id_one,item_id_two)
				values(?,?)~,
				undef, $movie_id, $director_id
				) if ( $director_id );
			}

			my @actors = @{$imdbObj->cast()};

			foreach my $id (0 .. $#actors) {

				my $actor_name = $actors[$id]{name};
				#print $actor_name."\n";
				my $actor_query = $dbh->prepare(qq~
					select id from actors where name = "$actor_name"
				~);
				$actor_query->execute;
				my($actor_id) = $actor_query->fetchrow_array;
				$actor_id ||= '';

				if ($actor_id eq '') {

					my $person;
					eval {
					$person = new IMDB::Persons(
						crit => $actor_name
					);
					};
					unless ( $@ ) {
					if($person->status) {

						my $name=trim($person->name());
						my $url = $person->photo();
						my $dob = trim(
							$person->date_of_birth()
						);
						my $place_of_birth = trim(
							$person->place_of_birth()
						);
						my $bio = trim($person->mini_bio());
						$name ||= '';
						$url ||= '';
						$dob ||= '';
						$place_of_birth ||= '';
						$bio ||= '';

						$dbh->do(qq~
						insert into actors(
						name,url,bio,dob,place_of_birth)
						values("$name","$url","$bio","$dob",
						"$place_of_birth")
						~) if ( $name );
					}
					}
				}
				$actor_query->execute;
				($actor_id) = $actor_query->fetchrow_array;
				$actor_id ||= '';

				$dbh->do(qq~
				insert into cast_items_map(item_id_one,item_id_two)
				values(?,?)~,
				undef, $movie_id, $actor_id
				) if ( $actor_id );
			}

			my @genres = @{$imdbObj->genres()};

			foreach my $id (0 .. $#genres) {

				my $genre_name = $genres[$id];
				my $genre_query = $dbh->prepare(qq~
					select id from genres where name = "$genre_name"
				~);
				$genre_query->execute;

				my ($genre_id) = $genre_query->fetchrow_array;
				$genre_id ||= '';

				if ($genre_id eq '') {
					$dbh->do(qq~
					insert into genres(name) values(?)
					~,
					undef, $genre_name
					);
				}
				$genre_query->execute;
				($genre_id) = $genre_query->fetchrow_array;
				$dbh->do(qq~
				insert into genre_items_map(item_id_one, item_id_two)
				values(?,?)~,
				undef, $movie_id, $genre_id
				);
			}

			my @languages = @{$imdbObj->language()};

			foreach my $id (0 .. $#languages) {

				my $language = $languages[$id];
				my $language_query = $dbh->prepare(qq~
				select id from languages where name="$language"
				~
				);
				$language_query->execute;
				my($language_id) = $language_query->fetchrow_array;
				$language_id ||= '';

				if ( $language_id eq '' ) {
					$dbh->do(
					qq~insert into languages(name) values (?)~,
					undef, $language
					);
				}

				$language_query->execute;
				($language_id) = $language_query->fetchrow_array;
				$dbh->do(qq~
				insert into language_items_map(
				item_id_one, item_id_two
				) values(?,?)~,
				undef, $movie_id, $language_id
				);
			}

			my @countries = @{$imdbObj->country()};

			foreach my $id (0 .. $#countries) {

				my $country = $countries[$id];
				my $country_query = $dbh->prepare(
					qq~select id from countries where name="$country"~
				);
				$country_query->execute;
				my($country_id) = $country_query->fetchrow_array;
				$country_id ||= '';

				if ( $country_id eq '') {
					$dbh->do(qq~
					insert into countries(name)
					values (?)~,
					undef, $country
					);
				}

				$country_query->execute;
				($country_id) = $country_query->fetchrow_array;
				$dbh->do(qq~
				insert into country_items_map(item_id_one,item_id_two)
				values(?,?)~,
				undef, $movie_id, $country_id
				);
			}
			print "movie saved ".$imdb_moviename."\n";
		} else {
			print $imdb_moviename." exists in database\n";
		}

		## if schedule exists in db - get id
		my $getsched = qq~
		select id from schedules
		where channel_id = ? and date_format(sched_date, '%d/%m/%Y') = ?
		and time_format(start_time, '%H:%i') = ?
		and duration = ? and programname = ?
		~;
		my $stmt = $dbh->prepare($getsched);
		$stmt->execute(
			$channel_id, $sched_date, $start_time,
			$duration, $imdb_moviename
		);
		my ($sched_id) = $stmt->fetchrow_array;

		if ( $sched_id ) {

			$dbh->do(qq~
			insert into movies_schedules_map(schedule_id, movie_id)
			values(?,?)~,
			undef, $sched_id, $movie_id
			);
			print "Added to db .. $imdb_moviename";

		}

	} else {
		print "cannot retrieve movie info for " . $imdb_moviename."\n";
		print ERR "$imdb_moviename\n";
	}
}

close(CSV);
close(ERR);
