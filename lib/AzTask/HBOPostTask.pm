package AzTask::HBOPostTask;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

our @EXPORT = qw();

use POSIX;

sub new {
	my $type = shift;
	my %param = @_;

	my $self = {};

	$self->{'csv_abs'} = $param{'schedules_csv'};
	$self->{'csv2_abs'} = "$param{'schedules_csv'}2";

	return bless $self, $type;
};

sub do {
	my $self = shift;

	open(CSV, $self->{'csv_abs'});
	open(CSV2, ">$self->{'csv2_abs'}");

	my @prev_fields;
	my $duration = 0;

	while ( <CSV> ) {

		if ( $. == 1 ) {
			print CSV2 $_;
			next;
		}

		## split using Lookbehind assertion, to split on ,
		## command not following a \

		my @cur_fields = split /(?<!\\),/;

		if ( scalar(@prev_fields) ) {
			my @p_dt = split /\//, $prev_fields[0];
			$p_dt[1] = $p_dt[1] - 1; $p_dt[2] = $p_dt[2] - 1900;

			my @p_tm = split /[:\s]/, $prev_fields[1];
			$p_tm[0] = 00 if ( $p_tm[2] eq 'AM' && $p_tm[0] == 12);
			$p_tm[0] += 12 if ( $p_tm[2] eq 'PM' &&  $p_tm[0] != 12 );
			# store in 24 hr format
			$prev_fields[1] = "$p_tm[0]:$p_tm[1]";

			my @c_dt  = split /\//, $cur_fields[0];
			$c_dt[1] = $c_dt[1] - 1; $c_dt[2] = $c_dt[2] - 1900;

			my @c_tm = split /[:\s]/, $cur_fields[1];
			$c_tm[0] = 00 if ( $c_tm[2] eq 'AM' && $c_tm[0] == 12);
			$c_tm[0] += 12 if ( $c_tm[2] eq 'PM' &&  $c_tm[0] != 12 );

			my $p_time = mktime(
				0, $p_tm[1], $p_tm[0],
				$p_dt[0], $p_dt[1], $p_dt[2]
			);

			my $c_time = mktime(
				0, $c_tm[1], $c_tm[0],
				$c_dt[0], $c_dt[1], $c_dt[2]
			);

			my $buf = join(",", @prev_fields);
			$buf =~ s/\s+$//g;
			$duration = difftime($c_time, $p_time);
			$duration = $duration / 60;
			print CSV2 "$buf,$duration", "\n";
		}
		@prev_fields = @cur_fields;
	}

	## A tiny compromise to get around the last schedule duration ;-) ##
	my @p_tm = split /[:\s]/, $prev_fields[1];
	$p_tm[0] = 00 if ( $p_tm[2] eq 'AM' && $p_tm[0] == 12 );
	$p_tm[0] += 12 if ( $p_tm[2] eq 'PM' &&  $p_tm[0] != 12 );
	# store in 24 hr format
	$prev_fields[1] = "$p_tm[0]:$p_tm[1]";

	my @p_dt = split /\//, $prev_fields[0];
	$p_dt[1] = $p_dt[1] - 1; $p_dt[2] = $p_dt[2] - 1900;

	my $p_time = mktime(
		0, $p_tm[1], $p_tm[0],
		$p_dt[0], $p_dt[1], $p_dt[2]
	);

	my $c_time = mktime(
		0, 59, 23,
		$p_dt[0], $p_dt[1], $p_dt[2]
	);

	$duration = difftime($c_time, $p_time);
	$duration = $duration / 60;

	my $buf = join(",", @prev_fields);
	$buf =~ s/\s+$//g;
	print CSV2 "$buf,$duration", "\n";
	## The last schedule with duration ^  ##

	close( CSV );
	close( CSV2 );
	`mv $self->{'csv2_abs'} $self->{'csv_abs'}`
};

sub done {
	my $self = shift;
};

1;
