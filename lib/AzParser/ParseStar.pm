package AzParser::ParseStar;

use strict;
use warnings;

our $VERSION = '0.01';

use base qw(Exporter);

use Date::Handler;
use Date::Handler::Delta;

sub new {
        my $type = shift;
        my %param = @_;

	## We are expect the channel name and date, in case we dont get that
	## set to an empty array ref
	$param{'args'} ||= [];

        my $self = new HTML::Parser;

        $self->{'starparser_flag'} = 0;
        $self->{'starparser_tag'} = '';

        open(SCHED_FH, ">$param{'schedules_csv'}");
        $self->{'SCHED_FH'} = *SCHED_FH{IO};

	# FIRST LINE IS THE CHANNEL NAME IS GIVE IN THE DB
	$param{'args'}->[0] ||= 'Star';
	print {$self->{'SCHED_FH'}} "$param{'args'}->[0]\n";

        $self->{'date'} = $param{'args'}->[1];

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
        $self->{'starparser_flag'} ||= 0;
	$self->{'starparser_tag'} ||= '';
	$attr->{'class'} ||= '';
	$attr->{'valign'} ||= '';
	$attr->{'bgcolor'} ||= '';

	# at schedules feed header
	if ( $tag eq 'tr' && $attr->{'class'} eq 'schdlFeedHeader' ) {
		$self->{'starparser_flag'} = 1;
                return;
	}

	# if at the schedules feed row
	if (
		$self->{'starparser_flag'} ==  1 && $tag eq 'td'
		&& $attr->{'class'} eq 'schdlDailyFeedRow'
	) {
		$self->{'starparser_tag'} = 'sched_row';
		$self->{'starparser_flag'} = 2;

		# Reset the csv line buffer
		$self->{'csv_line'} = '';

                return;
	}

	# detect when to stop parsing
	if (
		$self->{'starparser_flag'} ==  1 && $tag eq 'tr'
		&& $attr->{'valign'} eq 'middle'
	) {
		## Parsing done
		$self->{'starparser_flag'} = 0;
	}
};

sub end {
        my ($self, $tag, $origtext) = @_;

	## If at end of schedule row add an new line to the line and print to file
        if ( $self->{'starparser_flag'} == 2 && $tag eq 'tr' ) {

		$self->{'starparser_tag'} = '/sched_row';
		$self->{'starparser_flag'} = 1;

		$self->{'csv_line'} =~ s/\,$//;
		$self->{'csv_line'} .= "\n";
		print {$self->{'SCHED_FH'}} $self->{'date'}, ',', $self->{'csv_line'};

		return;
        }
};

sub text {
	my($self, $text) = @_;

	# if the instance variable are empty set them to sane intital value
	$self->{'starparser_flag'} ||= 0;
	$self->{'starparser_tag'} ||= '';

	# remove all loeading and trailing whitespaces
	$text =~ s/\^s+//g; $text =~ s/\s+$//g;

	if ( $self->{'starparser_flag'} == 2 && $self->{'starparser_tag'} eq 'sched_row' ) {
		$text =~ s/,/\\,/g;
		$self->{'csv_line'} .= $text . ',' if ( $text );
	}
};

1;
