package AzTask::TaskBase;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

our @EXPORT = qw();

sub new {
	my $type = shift;
	my %param = @_;
	my $self = {};
	return bless $self, $type;
};

sub do {
};

sub done {
};

1;
