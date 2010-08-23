package AzriSpider;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

our @EXPORT = qw(spider);

use HTTP::Request;
use HTTP::Response;
use LWP::RobotUA;
use Compress::Zlib;

sub spider {

	my %param = @_;
	my $err_stat = 0;

	my $ua = LWP::RobotUA->new(
		agent => $param{'config'}->{'name'},
		from => $param{'config'}->{'email'},
	);
	$ua->delay( $param{'delay'} );

	my $req = HTTP::Request->new( 'GET', $param{'url'} );
	$req->header('Accept-encoding', 'gzip; deflate');
	my $res = $ua->request( $req );

	${$param{'content'}} = $res->content;

	unless ( $res->is_success ) {
		$err_stat = 1;
		return $err_stat;
	}

	if ( my $enc = $res->header('Content-Encoding') ) {

		${$param{'content'}} = Compress::Zlib::memGunzip(
			${$param{'content'}}
		) if $enc =~ /gzip/i;

		${$param{'content'}} = Compress::Zlib::uncompress(
			${$param{'content'}}
		) if $enc =~ /deflate/i;
	}

	return $err_stat;
};

1;
