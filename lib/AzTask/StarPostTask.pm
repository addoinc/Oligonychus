package AzTask::StarPostTask;

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

	return bless $self, $type;
};

sub do {
	my $self = shift;
	my $file = $self->{'csv_abs'};

	# get total number of records
	my $count = `wc -l $file | awk -F' ' '{print \$1}'`;
	$count =~ s/\s+//g;
	# get time of last record
	my $last = `tail -1 $file | awk -F',' '{print \$2}'`;
	$last =~ s/\s+//g;

	# delete last record if it is redundant
	if ( $count > 2 && $last eq '00:00' ) {

		open (CSV, $file);
		## slurp the whole file into array, bcos we wont have
		## too many records (100 records max)
		my @records = <CSV>;
		close(CSV);

		pop @records;

		open(CSV, ">$file");
		print CSV join('', @records);
		close(CSV);
	}
};

sub done {
};

1;
