package AzParser::ParseHBO;

use strict;
use warnings;

our $VERSION = '0.01';

use base qw(Exporter);

use Date::Handler;
use Date::Handler::Delta;

sub new {
	my $type = shift;
	my %param = @_;

	$param{'args'} ||= [];

	my $self = new HTML::Parser;

	# Instance variable to keep track of which portion of html page we are parsing
	# hboparser_flag -> 1  -- when parsing the date range span
	# hboparser_flag -> 2 -- whhen parsing the schedules table
	$self->{'hboparser_flag'} = 0;

	# Instance variable to keep track of the schedules table element being parsed
	# hboparser_tag -> h2 & /h2 -- opening & closing element that has the schedule day
	# hboparser_tag -> time & /time -- opening & closing element having schedule hour
	# hboparser_tag -> title & /title -- opening & closing element having program name
	$self->{'hboparser_tag'} = '';

	# Open the file to which the schedules ar to be written and store its reference in
	# an intance variable
	open(SCHED_FH, ">$param{'schedules_csv'}");
	$self->{'SCHED_FH'} = *SCHED_FH{IO};

	# FIRST LINE IS THE CHANNEL NAME IS GIVE IN THE DB
	$param{'args'}->[0] ||= 'HBO';
	print {$self->{'SCHED_FH'}} "$param{'args'}->[0]\n";

	# instance variable to store date
	$self->{'date'} = [];
	# instance variable to build/store one line of csv file, before printing it
	$self->{'csv_line'} = '';

	return bless $self, $type;
}

sub done {
	close(SCHED_FH);
}

sub start {
	my ($self, $tag, $attr, $attrseq, $origtext) = @_;

	# If null, initialize instance variable to sane values
	$self->{'hboparser_flag'} ||= 0;
	$attr->{'class'} ||= '';

	## If opening date range span, flag this so that text() can extract the date range
	if( $tag eq 'span' && $attr->{'class'} eq 'date' ) {
		$self->{'hboparser_flag'} = 1;
		return;
	}

	## if opening schedules table flag this so that text() can extract the schedules
	if ( $tag eq 'table' && $attr->{'class'} eq 'schedule' ) {
		$self->{'hboparser_flag'} = 2;
		return;
	}

	## if within the schedules table and in the h2 that has the day
	if ( $self->{'hboparser_flag'} == 2 && $tag eq 'h2' ) {

		# set the current date, if csv_line is empty, we initialize it
		# with the first date of the range, else, we increment the currnet
		# date by 1
		unless ( $self->{'csv_line'} ) {
			$self->{'csv_line'} = join('/', @{$self->{'date'}}) . ",";
		} else {
			my $curr_date = new Date::Handler({
				date => [
					$self->{'date'}->[2],
					$self->{'date'}->[1],
					$self->{'date'}->[0],
				],
				locale => 'en_IN',
			});
			my $one_day = new Date::Handler::Delta([0, 0, 1, 0, 0, 0]);
			$curr_date = $curr_date + $one_day;
			$self->{'date'} = [
				$curr_date->Day(),
				$curr_date->Month(),
				$curr_date->Year()
			];
			$self->{'csv_line'} = join('/', @{$self->{'date'}}) . ",";
		}

		# flag if instance variable so that text() can extract required data
		$self->{'hboparser_tag'} = $tag;
	}

	## if within the schedules table and in the span that has the schedule time
	if ( $self->{'hboparser_flag'} == 2 && $tag eq 'span' && $attr->{'class'} eq 'time' ) {
		# flag if instance variable so that text() can extract required data
		$self->{'hboparser_tag'} = 'time';
	}

	## if within the schedules table and in the span that has the schedule title
	if ( $self->{'hboparser_flag'} == 2 && $tag eq 'span' && $attr->{'class'} eq 'title' ) {
		# flag if instance variable so that text() can extract required data
		$self->{'hboparser_tag'} = 'title';
	}
};

sub end {
	my ($self, $tag, $origtext) = @_;

	# if within the schedules tables and the tag is h2 set instance var to signal
	# the closing of tag
	if ( $self->{'hboparser_flag'} == 2 && $tag eq 'h2' ) {
		$self->{'hboparser_tag'} = "/$tag";
	}

	# if within the schedules tables and tag is 'time span' set instance var to signal
	# the closing of tag
	if (
		$self->{'hboparser_flag'} == 2 && $tag eq 'span'
		&& $self->{'hboparser_tag'} eq 'time'
	) {
		$self->{'hboparser_tag'} = '/time';
	}

	# if within the schedules tables and tag is 'title span' set instance var to signal
	# the closing of tag
	if (
		$self->{'hboparser_flag'} == 2 && $tag eq 'span'
		&& $self->{'hboparser_tag'} eq 'title'
	) {
		$self->{'hboparser_tag'} = '/title';
	}
};

sub text {
	my($self, $text) = @_;

	# if the instance variable are empty set them to sane intital value
	$self->{'hboparser_flag'} ||= 0;
	$self->{'hboparser_tag'} ||= '';

	# remove all loeading and trailing whitespaces
	$text =~ s/\^s+//g; $text =~ s/\s+$//g;

	# if span elem having date range is being currently parsed
	if( $self->{'hboparser_flag'} == 1 ) {

		### Extract the date range of schedules given in the feed ###
		my (@rng) = $text =~ m~(\d+/\d+/\d+)[^\d]+(\d+/\d+/\d+)~;
		### Print it directly to csv file ###
		##print {$self->{'SCHED_FH'}} "Schedule Range: $rng[0] : $rng[1]", "\n";

		$self->{'date'} = \@{[split(/\//, $rng[0])]};

		# done parsing the date range element
		$self->{'hboparser_flag'} = 0;

		return;
	}

	# if parsing within the schedules table
	if( $self->{'hboparser_flag'} == 2 ) {

		# if currently parsing the h2 tag having the day/DD:MM
		if ( $self->{'hboparser_tag'} eq 'h2' ) {

			# Do nothing, we are not using this date to determin current date
			return;

		} elsif ( $self->{'hboparser_tag'} eq '/h2' ) {

			# Do nothing, we are not using this date to determin current date
			return;
		}

		# if currently parsing the span containing the time of the schedule
		if ( $self->{'hboparser_tag'} eq 'time' ) {

			## Append time to csv_line buffer
			$self->{'csv_line'} .= "$text ";
			return;

		} elsif ( $self->{'hboparser_tag'} eq '/time' ) {

			# if done parsing the span containing the time of the schedule

			# removing the trailing whitespace
			$self->{'csv_line'} =~ s/\s+$//g;
			# append field seperator, comma in our case
			$self->{'csv_line'} .= ",";

			# set tag being currently parsed as none
			$self->{'hboparser_tag'} = '';

			return;
		}

		# if currently parsing the span containing the title of the schedule
		if ( $self->{'hboparser_tag'} eq 'title' ) {

			# Append title to csv_line buffer
			$text =~ s/,/\\,/g;
			$self->{'csv_line'} .= "$text ";
			return;

		} elsif ( $self->{'hboparser_tag'} eq '/title' ) {

			# if done parsing the span containing the title of the schedule

			# remove trailing whitespace
			$self->{'csv_line'} =~ s/\s+$//g;
			#append record seperator, newline in our case
			$self->{'csv_line'} .= "\n";

			# print the csv line to outfile
			print {$self->{'SCHED_FH'}} "$self->{'csv_line'}";

			# clear all fields from csv_line however, dont remove the first
			# field, it has the current date, it will be reset in start()
			$self->{'csv_line'} =~ s/([^,]+,).+/$1/g;
			$self->{'csv_line'} =~ s/\s+$//g;

			# set tag being currently parsed as none
			$self->{'hboparser_tag'} = '';

			return;

		}
	}
};

1;
