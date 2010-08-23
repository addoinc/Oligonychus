use strict;
use warnings;

package dbutils;

require Exporter;
use DBI;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw( $dbh connect query disconnect );

our $VERSION = 0.01;
our $dbh;

sub connect {
	$dbh = DBI->connect(
		"dbi:mysql:engine:localhost",
		'root',
		'azriroot',
	);
};

sub query {
	my %param = @_;
	my $output;

	$param{'param'} ||= [];

	my $stmt = $dbh->prepare( $param{'query'} );

	if ( scalar( @{ $param{'param'}} ) ) {
		$output = $stmt->execute( @{ $param{'param'} } );
	} else {
		$output = $stmt->execute();
	}
	if ( $stmt->{NUM_OF_FIELDS} && $stmt->{NUM_OF_FIELDS} > 0 ) {
		$output = $stmt->fetchall_arrayref;
	}

	return $output;
};

sub disconnect {
	$dbh->disconnect;
};

1;
