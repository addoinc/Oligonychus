#!/usr/bin/ksh

export OLIGONYCHUS_HOME=/home/mrblue/perl/oligonychus

$OLIGONYCHUS_HOME/bin/fetch-imdb-movies.pl -file $OLIGONYCHUS_HOME/data/hbo_schedules.csv
for file in $OLIGONYCHUS_HOME/data/Star_Movies_*.csv;
do
	$OLIGONYCHUS_HOME/bin/fetch-imdb-movies.pl -file $file
done
