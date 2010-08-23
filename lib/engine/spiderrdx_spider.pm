use strict;
use warnings;

package spiderrdx_spider;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw();
our $VERSION = 0.01;

use dbutils qw($dbh);
use spiderrdx_vars;
use spiderrdx_config qw( $spiderrdx_config );
use spiderrdx_parse;
use LWP::Charset qw(getCharset);
use LWP::RobotUA;
use HTML::LinkExtor;
use HTML::Tagset;
use HTML::TokeParser;
use Compress::Zlib;
use Time::HiRes;

use vars qw( $dbh );
use vars qw( $spiderrdx_config );

use vars '$bit';
use constant DEBUG_ERRORS   => $bit = 1;    # program errors
use constant DEBUG_URL      => $bit <<= 1;  # print out every URL processes
use constant DEBUG_HEADERS  => $bit <<= 1;  # prints the response headers
use constant DEBUG_FAILED   => $bit <<= 1;  # failed to return a 200
use constant DEBUG_SKIPPED  => $bit <<= 1;  # didn't index for some reason
use constant DEBUG_INFO     => $bit <<= 1;  # more verbose
use constant DEBUG_LINKS    => $bit <<= 1;  # prints links as they are extracted
use constant DEBUG_REDIRECT => $bit <<= 1;  # prints links that are redirected

use constant MAX_REDIRECTS  => 20;  # keep from redirecting forever

use constant MAX_SIZE       => 5_000_000;   # Max size of document to fetch
use constant MAX_WAIT_TIME  => 30;          # request time.

###########################################################################
#site_hash_tmpl - returns template hash for a site to be spidered
###########################################################################
sub site_hash_tmpl {
	return (
		site_id => '',
		skip => 0, #Flag to disable spidering this host.

		base_url => '',
		same_hosts => [],

		agent => 'Spider beta',
		email => 'gautam.chekuri@gmail.com',

		keep_alive => 1, #Try to keep the connection open
		max_wait_time => 120,

		cookies => [],

		#max_depth => 0,
		#max_files => 1, #Max files to spider
		delay_sec => 1, #Delay in seconds between requests
		ignore_robots_file => 0, #Don't set that to one, unless you are sure.

		use_cookies => 1,
		# True will keep cookie jar
		# Some sites require cookies
		# Requires HTTP::Cookies

		use_md5 => 1,
		# If true, this will use the Digest::MD5
		# module to create checksums on content
		# This will very likely catch files
		# with differet URLs that are the same
		# content. Will trap / and /index.html,
		# for example.

		incremental_update => 0,

		# This will generate A LOT of debugging information to STDOUT
		#debug => DEBUG_URL | DEBUG_SKIPPED | DEBUG_HEADERS,
		#debug => DEBUG_SKIPPED | DEBUG_URL,

		base_rule => '',
		skip_rule => '',

		# Here are hooks to callback routines to validate urls and responses
		# Probably a good idea to use them so you don't try to index
		# Binary data.  Look at content-type headers!

		test_url => \&test_url,
		test_response => undef,
		filter_content => undef,
		output_function => \&output_sub,
	)
};

###########################################################################
#get_site_hash - pushes a %site hash into @servers
# PARAM:
# servers_ref => refrence to @servers array
# site_id => site_id of website to spider
###########################################################################
sub get_site_hash {
	my %param = @_;

	my $query = qq~
	SELECT submitted_site_id, submitted_site_url, submitted_site_index_page,
	submitted_site_cookies
	FROM spiderrdx_submitted_sites
	WHERE submitted_site_spider = 1
	AND submitted_site_id = ?
	~;
	my $site = &dbutils::query(
		query => $query,
		param => [$param{'site_id'}],
	);

	my %site = spiderrdx_spider::site_hash_tmpl();

	$site{'site_id'} = $site->[0]->[0];
	$site{'base_url'} = $site->[0]->[1] . $site->[0]->[2];
	$site{'max_depth'} = 5;

	# Initialize cookies that are to be sent to the webserver of this site
	my @cookies = ();
	if ( $site->[0]->[3] ) {
		@cookies = split(',', $site->[0]->[3]);
	}
	$site{'cookies'} = [@cookies];

	$query = qq~
	SELECT bsr.spider_rule, bsrt.spider_rule_type_key
	FROM spiderrdx_spider_rules bsr, spiderrdx_spider_rule_types bsrt
	WHERE bsr.spider_rule_submitted_site_id = ?
	AND bsr.spider_rule_type_id = bsrt.spider_rule_type_id
	~;
	my $rules = &dbutils::query(
		query => $query,
		param => [$site->[0]->[0]],
	);

	for( my $i = 0; $i < scalar(@{$rules}); $i++ ) {
		if ( $rules->[$i]->[1] eq 'skip_url_rule' && $rules->[$i]->[0] ) {
			#SkipURL rules.
			$site{'skip_rule'} = $rules->[$i]->[0];
		} elsif( $rules->[$i]->[1] eq 'base_url_rule' && $rules->[$i]->[0] ) {
			$site{'base_rule'} = $rules->[$i]->[0];
		}
	}
	push @{ $param{'servers_ref'} }, \%site;
};

###########################################################################
#test_url - lets you check a URL before requesting the document from the server. return false to skip the link
#FORMAT: test_url( $uri, $server )
###########################################################################
sub test_url {
	my ( $uri, $server ) = @_;
	# return 1;  # Ok to index/spider
	# return 0;  # No, don't index or spider

	# ignore any common image files
	return 0 if $uri->path =~ /\.(gif|jpg|jpeg|png|doc|xls|pdf|ps|Z|zip|exe)?$/;

	#BaseURL rule.
	if ( $server->{'base_rule'} ) {
		return 0 if $uri->path_query !~ m[^$server->{base_rule}];
	}

	#SkipURL rules.
	if ( $server->{'skip_rule'} ) {
		return 0 if $uri->path_query =~ m[($server->{skip_rule})];
	    }
	return 1;
};

###########################################################################
#output_sub - analyses a retrieved uri and updates db accordingly
# PARAM:
# server =>
# content =>
# uri =>
# response =>
# bytecount =>
# path =>
###########################################################################
sub output_sub {
	my %param = @_;
	my ($lastmod, $caption);
	my $charset = getCharset( $param{'response'} );
	my $file_id;

	if ( !$param{'path'} || !${$param{'content'}} ) {
		return 0;
	}

	my $spider_cache_dir = $spiderrdx_config->{'spider_cache_location'};

	if ( $charset ) {
		${$param{'content'}} = Encode::decode( $charset, ${$param{'content'}} );
	}

	if ( $param{'response'}->last_modified ) {
		$lastmod = $param{'response'}->last_modified;
	} else {
		$lastmod = "";
	}

	if ( $param{'response'}->content_type =~ m[^text/html$] ) {
		#EXTRACT TITLE OF DOCUMENT#
		$caption = &spiderrdx_parse::get_title(${$param{'content'}});
		#REMOVE ALL HTML TAGS#
		${$param{'content'}} = &spiderrdx_parse::get_text(${$param{'content'}});
	}

	#CHECK FOR DOCUMENTS FOR SAME CONTENT
	my $query = qq~
	SELECT indexed_url, indexed_url_content_md5
	FROM spiderrdx_indexed_urls
	WHERE indexed_url_content_md5 LIKE MD5(?)
	~;
	my $dupchk_res = &dbutils::query(
		query => $query,
		param => [${$param{'content'}}]
	);
	if ( scalar( @{$dupchk_res} ) > 0 ) {
		return 0;
	}

	#IF TITLE WAS EMPTY, EXTRACT, FIRST 60 WORDS FROM ${$param{'content'}}#
	if ( !$caption ) {
		$caption = substr(${$param{'content'}}, 0, 70);
		$caption =~ s/(\w+)$//;
		$caption .= "...";
	}

	#CREATE/UPDATE RECORD FOR THIS url, md5(url), md5(content)###
	$query = qq~
	SELECT indexed_url_id
	FROM spiderrdx_indexed_urls
	WHERE indexed_url_md5 LIKE MD5(?);
	~;
	my $urlid_res = &dbutils::query(
		query => $query,
		param => [$param{'path'}]
		);
	if ( $urlid_res->[0]->[0] ) {

		$query = qq~
		UPDATE spiderrdx_indexed_urls
		SET indexed_url_content_md5 = MD5(?)
		WHERE indexed_url_id = ?;
		~;
		my $res;
		eval {
			$res = &dbutils::query(
				query => $query,
				param => [${$param{'content'}}, $urlid_res->[0]->[0]]
				);
		};
		if ( $@ ) {
			print STDERR $@, " : ", $param{'path'}, "\n";
			return 0;
		}

		$file_id = $urlid_res->[0]->[0];

	} else {
		$query = qq~
		INSERT INTO spiderrdx_indexed_urls(indexed_url,indexed_url_md5,indexed_url_content_md5)
		VALUES (?, MD5(?), MD5(?))
		~;
		my $res;
		eval {
			$res = &dbutils::query(
				query => $query,
				param => [$param{'path'}, $param{'path'}, ${$param{'content'}}]
				);
		};
		if ( $@ ) {
			print STDERR $@, " : ", $param{'path'}, "\n";
			return 0;
		}

		#GET THE ID OF THE RECORD INSERTED ABOVE.#
		$query = qq~
		SELECT LAST_INSERT_ID()
		~;
		$res = &dbutils::query(
			query => $query,
			param => [],
			);
		$file_id = $res->[0]->[0];
	}
	#############################################################

	open (FILE, ">:utf8", "$spider_cache_dir/$file_id");
	print FILE ${$param{'content'}};
	close FILE;

	return 1;
};

###########################################################################
## Here's an example of a "test_response" callback.  You would
# add it to your config like:
#
#   test_response => \&test_response_sub,
#
# This routine is called when the *first* block of data comes back
# from the server.  If you return false no more content will be read
# from the server.  $response is a HTTP::Response object.
# It's useful for checking the content type of documents.
#
# For example, say we have a lot of audio files linked our our site that we
# do not want to index.  But we also have a lot of image files that we want
# to index the path name only.
###########################################################################
sub test_response_sub {
	my ( $uri, $server, $response ) = @_;

	return if $response->content_type =~ m[^audio/];

	# In this example set the "no_contents" flag for 
	$server->{no_contents}++ unless $response->content_type =~ m[^image/];
	return 1;  # ok to index and spider
};

#########################################
# dump_spider_state()
# PARAM:
# moved_visited_todb -> value of $moved_visited_todb
# db_visited - ref to %db_visited
# visited - ref to %visited
#########################################
sub dump_spider_state {
	my %param = @_;

	unless ( $param{'moved_visited_todb'} ) {
		%{ $param{'db_visited'} } = %{ $param{'visited'} };
	}
}

#########################################
# process_server()
#
# This processes a single server config (part of @servers)
# It validates and cleans up the config and then starts spidering
# for each URL listed in base_url
#
#########################################
sub process_server {
	my $server = shift;

	my %DEBUG_MAP = (
		errors      => DEBUG_ERRORS,
		url         => DEBUG_URL,
		headers     => DEBUG_HEADERS,
		failed      => DEBUG_FAILED,
		skipped     => DEBUG_SKIPPED,
		info        => DEBUG_INFO,
		links       => DEBUG_LINKS,
		redirect    => DEBUG_REDIRECT,
	);

	# set defaults

	# Set debug options.
	$server->{debug} =
		defined $ENV{SPIDER_DEBUG}
		? $ENV{SPIDER_DEBUG}
		: ($server->{debug} || 0);

	# Convert to number
	if ( $server->{debug} !~ /^\d+$/ ) {
		my $debug = 0;
		$debug |= (exists $DEBUG_MAP{lc $_} 
			? $DEBUG_MAP{lc $_} 
			: die "Bad debug setting passed in "
				. (defined $ENV{SPIDER_DEBUG} ? 'SPIDER_DEBUG environment' : q['debug' config option])
				. " '$_'\nOptions are: " 
				. join( ', ', sort keys %DEBUG_MAP) ."\n")
			for split /\s*,\s*/, $server->{debug};
		$server->{debug} = $debug;
	}

	$server->{quiet} ||= $ENV{SPIDER_QUIET} || 0;

	# Lame Microsoft
	$URI::ABS_REMOTE_LEADING_DOTS = $server->{remove_leading_dots} ? 1 : 0;

	$server->{max_size} = MAX_SIZE unless defined $server->{max_size};
	die "max_size parameter '$server->{max_size}' must be a number\n" unless $server->{max_size} =~ /^\d+$/;


	$server->{max_wait_time} ||= MAX_WAIT_TIME;
	die "max_wait_time parameter '$server->{max_wait_time}' must be a number\n" if $server->{max_wait_time} !~ /^\d+$/;

	# Can be zero or undef or a number.
	$server->{credential_timeout} = 30 unless exists $server->{credential_timeout};
	die "credential_timeout '$server->{credential_timeout}' must be a number\n" if defined $server->{credential_timeout} && $server->{credential_timeout} !~ /^\d+$/;

	$server->{link_tags} = ['a'] unless ref $server->{link_tags} eq 'ARRAY';
	$server->{link_tags_lookup} = { map { lc, 1 } @{$server->{link_tags}} };

	die "max_depth parameter '$server->{max_depth}' must be a number\n" if defined $server->{max_depth} && $server->{max_depth} !~ /^\d+/;


	for ( qw/ test_url test_response filter_content/ ) {
		next unless $server->{$_};
		$server->{$_} = [ $server->{$_} ] unless ref $server->{$_} eq 'ARRAY';
		my $n;
		for my $sub ( @{$server->{$_}} ) {
			$n++;
			die "Entry number $n in $_ is not a code reference\n" unless ref $sub eq 'CODE';
		}
	}

	my $start = time;

	if ( $server->{skip} ) {
		print STDERR "Skipping Server Config: $server->{base_url}\n" unless $server->{quiet};
		return;
	}

	require "HTTP/Cookies.pm" if $server->{use_cookies};
	require "Digest/MD5.pm" if $server->{use_md5};

	# set starting URL, and remove any specified fragment
	my $uri = URI->new( $server->{base_url} );
	$uri->fragment(undef);

	if ( $uri->userinfo ) {
		die "Can't specify parameter 'credentials' because base_url defines them\n" if $server->{credentials};
		$server->{credentials} = $uri->userinfo;
		$uri->userinfo( undef );
	}

	print STDERR "\n -- Starting to spider: $uri --\n" if $server->{debug};
	# set the starting server name (including port) -- will only spider on server:port

	# All URLs will end up with this host:port
	$server->{authority} = $uri->canonical->authority;

	# All URLs must match this scheme ( Jan 22, 2002 - spot by Darryl Friesen )
	$server->{scheme} = $uri->scheme;

	# Now, set the OK host:port names
	$server->{same} = [ $uri->canonical->authority || '' ];

	push @{$server->{same}}, @{$server->{same_hosts}} if ref $server->{same_hosts};

	$server->{same_host_lookup} = { map { $_, 1 } @{$server->{same}} };

	# set time to end
	$server->{max_time} = $server->{max_time} * 60 + time if $server->{max_time};

	# set default agent for log files
	$server->{agent} ||= 'swish-e spider 2.2 http://swish-e.org/';

	# get a user agent object
	my $ua;

	# set the delay
	unless ( defined $server->{delay_sec} ) {
		if ( defined $server->{delay_min} && $server->{delay_min} =~ /^\d+\.?\d*$/ ) {
			# change if ever move to Time::HiRes
			$server->{delay_sec} = int ($server->{delay_min} * 60);
		}

		$server->{delay_sec} = 5 unless defined $server->{delay_sec};
	}
	$server->{delay_sec} = 5 unless $server->{delay_sec} =~ /^\d+$/;

	if ( $server->{ignore_robots_file} ) {
		$ua = LWP::UserAgent->new;
		return unless $ua;
		$ua->agent( $server->{agent} );
		$ua->from( $server->{email} );
	} else {
		$ua = LWP::RobotUA->new( $server->{agent}, $server->{email} );
		return unless $ua;
		$ua->delay( 0 );  # handle delay locally.
	}

	# If ignore robots files also ignore meta ignore <meta name="robots">
	$ua->parse_head( 0 ) if $server->{ignore_robots_file} || $server->{ignore_robots_headers};

	# Set the timeout - used to only for windows and used alarm, but this
	# did not always works correctly.  Hopefully $ua->timeout works better in
	# current versions of LWP (before DNS could block forever)

	$ua->timeout( $server->{max_wait_time} );

	$server->{ua} = $ua;  # save it for fun.
	# $ua->parse_head(0);   # Don't parse the content

	$ua->cookie_jar( HTTP::Cookies->new ) if $server->{use_cookies};

	if ( $server->{keep_alive} ) {
		if ( $ua->can( 'conn_cache' ) ) {
			my $keep_alive = $server->{keep_alive} =~ /^\d+$/ ? $server->{keep_alive} : 1;
			$ua->conn_cache( { total_capacity => $keep_alive } );

		} else {
			delete $server->{keep_alive};
			warn "Can't use keep-alive: conn_cache method not available\n";
		}
	}

	# Disable HEAD requests if there's no reason to use them
	# Keep_alives is questionable because even without keep alives
	# it might be faster to do a HEAD than a partial GET.
	if (
		$server->{use_head_requests} && !$server->{keep_alive} ||
		!( $server->{test_response} || $server->{max_size} ) 
	) {
		warn 'Option "use_head_requests" was disabled.\nNeed keep_alive and either test_response or max_size options\n';
		delete $server->{use_head_requests};
	}

	# uri, parent, depth
	eval { spider( $server, $uri ) };
	print STDERR $@ if $@;

	# provide a way to call a function in the config file when all done
	check_user_function( 'spider_done', undef, $server );

	delete $server->{ua};  # Free up LWP to avoid CLOSE_WAITs hanging around when using a lot of @servers.

	return if $server->{quiet};

	$start = time - $start;
	$start++ unless $start;

	my $max_width = 0;
	my $max_num = 0;
	for ( keys %{$server->{counts}} ) {
		$max_width = length if length > $max_width;
		my $val = commify( $server->{counts}{$_} );
		$max_num = length $val if length $val > $max_num;
	}

	print STDERR "\nSummary for: $server->{base_url}\n";

	for ( sort keys %{$server->{counts}} ) {
		printf STDERR "%${max_width}s: %${max_num}s  (%0.1f/sec)\n",
		$_,
		commify( $server->{counts}{$_} ),
		$server->{counts}{$_}/$start;
	}
}


#########################################
# Deal with Basic Authen
#########################################
sub get_basic_credentials {
	my($uri, $server, $realm ) = @_;

	# Exists but undefined means don't ask.
	return if exists $server->{credential_timeout} && !defined $server->{credential_timeout};

	# Exists but undefined means don't ask.
	my $netloc = $uri->canonical->host_port;

	my ($user, $password);

	eval {
		local $SIG{ALRM} = sub { die "timed out\n" };

		# a zero timeout means don't time out
		alarm( $server->{credential_timeout} ) unless $^O =~ /Win32/i;

		if (  $uri->userinfo ) {
			print STDERR "\nSorry: invalid username/password\n";
			$uri->userinfo( undef );
		}

		print STDERR "Need Authentication for $uri at realm '$realm'\n(<Enter> skips)\nUsername: ";
		$user = <STDIN>;
		chomp($user) if $user;
		die "No Username specified\n" unless length $user;

		alarm( $server->{credential_timeout} ) unless $^O =~ /Win32/i;

		print STDERR "Password: ";
		system("stty -echo");
		$password = <STDIN>;
		system("stty echo");
		print STDERR "\n";  # because we disabled echo
		chomp($password);

		alarm( 0 ) unless $^O =~ /Win32/i;
	};

	return if $@;
	return join ':', $user, $password;
}


#########################################
#Non recursive spidering
# Had problems with some versions of LWP where memory was not freed
# after the URI objects went out of scope, so instead just maintain
# a list of URI.
# Should move this to a DBM or database.
#########################################
sub spider {
	my ( $server, $uri ) = @_;

	# Validate the first link, just in case
	return unless check_link( $uri, $server, '', '(Base URL)' );

	my @link_array = [ $uri, '', 0 ];

	while ( @link_array ) {
		die $server->{abort} if $abort || $server->{abort};

		my ( $uri, $parent, $depth ) = @{shift @link_array};

		delay_request( $server );

		# Delete any per-request data
		delete $server->{_request};

		my $new_links = process_link( $server, $uri, $parent, $depth );

		push @link_array, map { [ $_, $uri, $depth+1 ] } @$new_links if $new_links;

	}
}

#########################################
#Delay a request based on the delay time
#########################################
sub delay_request {
	my ( $server ) = @_;

	# Here's a place to log the type of connection
	if ( $server->{keep_alive_connection} ) {
		$server->{counts}{'Connection: Keep-Alive'}++;
		# no delay on keep-alives
		return;
	}

	$server->{counts}{'Connection: Close'}++;

	# return if no delay or first request
	return if !$server->{delay_sec} || !$server->{last_response_time};

	my $wait = $server->{delay_sec} - ( time - $server->{last_response_time} );

	return unless $wait > 0;

	print STDERR "sleeping $wait seconds\n" if $server->{debug} & DEBUG_URL;
	sleep( $wait );
}

#########################################
# process_link()  - process a link from the list
#
# Can be called recursively (for auth and redirects)
#
# This does most of the work.
# Pass in:
#   $server -- config hash, plus ugly scratch pad memory
#   $uri    -- uri to fetch and extract links from
#   $parent -- parent uri for better messages
#   $depth  -- for controlling how deep to go into a site, whatever that means
#
# Returns:
#   undef or an array ref of links to add to the list
#
# Makes request, tests response, logs, parsers and extracts links
# Very ugly as this is some of the oldest code
#########################################
sub process_link {
	my ( $server, $uri, $parent, $depth ) = @_;

	$server->{counts}{'Unique URLs'}++;

	die "$0: Max files Reached\n" if $server->{max_files} && $server->{counts}{'Unique URLs'} > $server->{max_files};

	die "$0: Time Limit Exceeded\n" if $server->{max_time} && $server->{max_time} < time;

	# clean up some per-request crap.
	# Really should just subclass the response object!
	$server->{no_contents} = 0;
	$server->{no_index} = 0;
	$server->{no_spider} = 0;

	# Make request object for this URI
	### my $debug_timing_s = Time::HiRes::time;
	my $request = HTTP::Request->new('GET', $uri );
	$request->header('Accept-encoding', 'gzip; deflate');

	my @cookies = ();
	foreach my $cookie ( @{$server->{'cookies'}} ) {
		push @cookies, $cookie;
	}
	$request->header('Cookie' => @cookies);

	# Set basic auth if defined - use URI specific first, then credentials
	# this doesn't track what should have authorization
	my $last_auth;
	if ( $server->{last_auth} ) {
		my $path = $uri->path;
		$path =~ s!/[^/]*$!!;
		$last_auth = $server->{last_auth}{auth} if $server->{last_auth}{path} eq $path;
	}

	if ( my ( $user, $pass ) = split /:/, ( $last_auth || $uri->userinfo || $server->{credentials} || '' ) ) {
		$request->authorization_basic( $user, $pass );
	}

	my $response;

	delete $server->{response_checked};  # to keep from checking more than once

	if ( $server->{use_head_requests} ) {
		$request->method('HEAD');

		# This is ugly in what it can return.  It's can be recursive.
		$response = make_request( $request, $server, $uri, $parent, $depth );

		# returns undef or an array ref if done
		return $response if !$response || ref $response eq 'ARRAY';

		# otherwise, we have a response object.
		$request->method('GET');
	}


	# Now make GET request
	$response = make_request( $request, $server, $uri, $parent, $depth );

	return $response if !$response || ref $response eq 'ARRAY';  # returns undef or an array ref

	# Now we have a $response object with content
	return process_content( $response, $server, $uri, $parent, $depth );
}

#########################################
# make_request -- 
#
# This only can deal with things that happen in a HEAD request.
# Well, unless test for the method
#
# Hacked up function to make either a HEAD or GET request and test the response
# Returns one of three things:
#   undef - stop processing and return
#   and array ref - a list of URLs extracted (via recursive call)
#   a HTTP::Response object
#
#
# Yes it's a mess -- got pulled out of other code when adding HEAD requests
#########################################
sub make_request {
	my ( $request, $server, $uri, $parent, $depth ) = @_;
	my $response;
	my $response_aborted_msg;
	my $killed_connection;

	my $ua = $server->{ua};

	if ( $request->method eq 'GET' ) {

		# When making a GET request this gets called for every chunk returned
		# from the webserver (well, from the OS).  No idea how bit it will be.
		#
		my $total_length = 0;

		my $callback = sub {
			my ( $content, $response ) = @_;

			# First time, check response - this can die()
			check_response( $response, $server, $uri ) unless $server->{response_checked}++;

			# In case didn't return a content-length header
			$total_length += length $content;
			check_too_big( $response, $server, $total_length ) if $server->{max_size};

			$response->add_content( $content );
		};

		## Make Request ##
		# Used to wrap in an eval and use alarm on non-win32 to fix broken $ua->timeout

		$response = $ua->simple_request( $request, $callback, 4096 );

		# Check for callback death:
		# If the LWP callback aborts

		if ( $response->header('client-aborted') ) {
			$response_aborted_msg = $response->header('X-Died') || 'unknown';
			$killed_connection++;  # so we will delay
		}

	} else {

		# Make a HEAD request
		$response = $ua->simple_request( $request );

		# check_response - user callback can call die() so wrap in eval block
		eval {
			check_response( $response, $server, $uri ) unless $server->{response_checked}++;
		};
		$response_aborted_msg = $@ if $@;
	}

	# save the request completion time for delay between requests
	$server->{last_response_time} = time;

	# Ok, did the request abort for some reason?  (response checker called die() )

	if ( $response_aborted_msg ) {
		# Log unless it's the callback (because the callback already logged it)
		if ( $response_aborted_msg !~ /test_response/ ) {
			$server->{counts}{Skipped}++;

			# Not really sure why request aborted.  Let's try and make the error message
			# a bit cleaner.
			print STDERR "Request for '$uri' aborted because: '$response_aborted_msg'\n" if $server->{debug}&DEBUG_SKIPPED;
		}

		# Aborting in the callback breaks the connection (so tested on Apache)
		# even if all the data was transmitted.
		# Might be smart to flag to abort but wait until the next chunk
		# to really abort.  That might make so the connection would not get killed.

		delete $server->{keep_alive_connection} if $killed_connection;
		return;
	}

	# Look for connection.  Assume it's a keep-alive unless we get a Connection: close
	# header.  Some server errors (on Apache) will close the connection, but they
	# report it.
	# Have to assume the connection is open (without asking LWP) since the first 
	# connection we normally do not see (robots.txt) and then following keep-alive
	# connections do not have Connection: header.

	my $connection = $response->header('Connection') || 'Keep-alive';  # assume keep-alive
	$server->{keep_alive_connection} =  !$killed_connection && $server->{keep_alive} && $connection !~ /close/i;

	# Did a callback return abort?
	return if $server->{abort};

	# Clean up the URI so passwords don't leak

	$response->request->uri->userinfo( undef ) if $response->request;
	$uri->userinfo( undef );

	# A little debugging
	print STDERR "\nvvvvvvvvvvvvvvvv HEADERS for $uri vvvvvvvvvvvvvvvvvvvvv\n\n---- Request ------\n",
		$response->request->as_string,
		"\n---- Response ---\nStatus: ", $response->status_line,"\n",
		$response->headers_as_string,
		"\n^^^^^^^^^^^^^^^ END HEADERS ^^^^^^^^^^^^^^^^^^^^^^^^^^\n\n"
	if $server->{debug} & DEBUG_HEADERS;

	# Deal with failed responses

	return failed_response( $response, $server, $uri, $parent, $depth ) unless $response->is_success;

	# Don't log HEAD requests
	return $request if $request->method eq 'HEAD';

	# Log if requested

	log_response( $response, $server, $uri, $parent, $depth ) if $server->{debug} & DEBUG_URL;

	# Check for meta refresh
	# requires that $ua->parse_head() is enabled (the default)

	return redirect_response( $response, $server, $uri, $parent, $depth, $1, 'meta refresh' )
	if $response->header('refresh') && $response->header('refresh') =~ /URL\s*=\s*(.+)/;

	return $response;
}

#########################################
# check_response -- after resonse comes back from server
#
# Failure here should die() because check_user_function can die()
#
#########################################
sub check_response {
	my ( $response, $server, $uri ) = @_;

	return unless $response->is_success;  # 2xx response.

	# Cache user/pass if entered from the keyboard or callback function (as indicated by the realm)
	# do here so we know it is correct

	if ( $server->{cur_realm} && $uri->userinfo ) {
		my $key = $uri->canonical->host_port . ':' . $server->{cur_realm};
		$server->{auth_cache}{$key} =  $uri->userinfo;

		# not too sure of the best logic here
		my $path = $uri->path;
		$path =~ s!/[^/]*$!!;
		$server->{last_auth} = {
			path => $path,
			auth => $uri->userinfo,
		};
	}

	# check for document too big.
	check_too_big( $response, $server ) if $server->{max_size};

	die "test_response" if !check_user_function( 'test_response', $uri, $server, $response );
}

#########################################
# check_too_big -- see if document is too big
# Die if it is too big.
#########################################
sub check_too_big {
	my ( $response, $server, $length ) = @_;

	$length ||= $response->content_length || 0;
	return unless $length && $length =~ /^\d+$/;

	die "Document exceeded $server->{max_size} bytes (Content-Length: $length) Method: " . $response->request->method . "\n"
        if $length > $server->{max_size};
}

#########################################
# failed_response -- deal with a non 2xx response
#
#########################################
sub failed_response {
	my ( $response, $server, $uri, $parent, $depth ) = @_;
	my $links;

	# Do we need to authorize?
	if ( $response->code == 401 ) {
		# This will log the error
		$links = authorize( $response, $server, $uri, $parent, $depth );
		return $links if ref $links or !$links;
	}


	# Are we rejected because of robots.txt?

	if ( $response->status_line =~ 'robots.txt' ) {
		print STDERR "-Skipped $depth $uri: ", $response->status_line,"\n" if $server->{debug}&DEBUG_SKIPPED;
		$server->{counts}{'robots.txt'}++;
		return;
	}


	# Look for redirect
	return redirect_response( $response, $server, $uri, $parent, $depth ) if $response->is_redirect;

	# Report bad links (excluding those skipped by robots.txt)
	# Not so sure about this being here for these links...
	validate_link( $server, $uri, $parent, $response ) if $server->{validate_links};

	# Otherwise, log if needed and then return.
	log_response( $response, $server, $uri, $parent, $depth ) if $server->{debug} & DEBUG_FAILED;

	return;
}

#########################################
# redirect_response -- deal with a 3xx redirect
#
# Returns link to follow
#########################################
sub redirect_response {
	my ( $response, $server, $uri, $parent, $depth, $location, $description ) = @_;

	$location ||= $response->header('location');
	unless ( $location ) {
		print STDERR "Warning: $uri returned a redirect without a Location: header\n";
		return;
	}
	$description ||= 'Location';

	# This should NOT be needed, but some servers are broken
	# and don't return absolute links.
	# and this may even break things
	my $u = URI->new_abs( $location, $response->base );
	##$u = URI->new( rem_sidvar_fromurl( url => $u->as_string ) );

	if ( $u->canonical eq $uri->canonical ) {
		print STDERR "Warning: $uri redirects to itself!.\n";
		return;
	}

	# make sure it's ok:
	return unless check_link( $u, $server, $response->base, '(redirect)', $description  );

	# make recursive request
	# This will not happen because the check_link records that the link has been seen.
	# But leave here just in case

	if ( $server->{_request}{redirects}++ > MAX_REDIRECTS ) {
		warn "Exceeded redirect limit: perhaps a redirect loop: $uri on parent page: $parent\n";
		return;
	}

	print STDERR "--Redirect: $description $uri -> $u. Parent: $parent\n" if $server->{debug} & DEBUG_REDIRECT;

	$server->{counts}{"$description Redirects"}++;
	my $links = process_link( $server, $u, $parent, $depth );
	$server->{_request}{redirects}-- if  $server->{_request}{redirects};
	return $links;

}

#########################################
# Do we need to authorize?  If so, ask for password and request again.
# First we try using any cached value
# Then we try using the get_password callback
# Then we ask.
#########################################
sub authorize {
	my ( $response, $server, $uri, $parent, $depth ) = @_;

	delete $server->{last_auth};  # since we know that doesn't work

	if ( $response->header('WWW-Authenticate') && $response->header('WWW-Authenticate') =~ /realm="([^"]+)"/i ) {
		my $realm = $1;
		my $user_pass;

		# Do we have a cached user/pass for this realm?
		unless ( $server->{_request}{auth}{$uri}++ ) { # only each URI only once
			my $key = $uri->canonical->host_port . ':' . $realm;

			if ( $user_pass = $server->{auth_cache}{$key} ) {

				# If we didn't just try it, try again
				unless( $uri->userinfo && $user_pass eq $uri->userinfo ) {

					# add the user/pass to the URI
					$uri->userinfo( $user_pass );
					return process_link( $server, $uri, $parent, $depth );
				}
			}
		}

		# now check for a callback password (if $user_pass not set)
		unless ( $user_pass || $server->{_request}{auth}{callback}++ ) {

			# Check for a callback function
			if ( ref($server->{get_password}) eq 'CODE' ) {
				$user_pass = $server->{get_password}->( $uri, $server, $response, $realm );
			}
		}

		# otherwise, prompt (over and over)

		if ( !$user_pass ) {
			$user_pass = get_basic_credentials( $uri, $server, $realm );
		}


		if ( $user_pass ) {
			$uri->userinfo( $user_pass );
			$server->{cur_realm} = $realm;  # save so we can cache if it's valid
			my $links = process_link( $server, $uri, $parent, $depth );
			delete $server->{cur_realm};
			return $links;
		}
	}

	log_response( $response, $server, $uri, $parent, $depth ) if $server->{debug} & DEBUG_FAILED;

	return;  # Give up
}

#########################################
# Log a response
#########################################
sub log_response {
	my ( $response, $server, $uri, $parent, $depth ) = @_;

	# Log the response
	print STDERR '>> ',
		join( ' ',
			( $response->is_success ? '+Fetched' : '-Failed' ),
			$depth,
			"Cnt: $server->{counts}{'Unique URLs'}",
			$response->request->method,
			" $uri ",
			( $response->status_line || $response->status || 'unknown status' ),
			( $response->content_type || 'Unknown content type'),
			( $response->content_length || '???' ),
			"parent:$parent",
			"depth:$depth",
		),"\n";
}

#########################################
# Calls a user-defined function
#########################################
sub check_user_function {
	my ( $fn, $uri, $server ) = ( shift, shift, shift );

	return 1 unless $server->{$fn};
	my $tests = ref $server->{$fn} eq 'ARRAY' ? $server->{$fn} : [ $server->{$fn} ];
	my $cnt;

	for my $sub ( @$tests ) {
		$cnt++;
		print STDERR "?Testing '$fn' user supplied function #$cnt '$uri'\n" if $server->{debug} & DEBUG_INFO;

		my $ret;

		eval { $ret = $sub->( $uri, $server, @_ ) };

		if ( $@ ) {
			if ( $server->{debug} & DEBUG_SKIPPED ) {
				print STDERR "-Skipped $uri due to '$fn' user supplied function #$cnt death '$@'\n";
			}
			$server->{counts}{Skipped}++;
			return;
		}

		next if $ret;

		print STDERR "-Skipped $uri due to '$fn' user supplied function #$cnt\n" if $server->{debug} & DEBUG_SKIPPED;
		$server->{counts}{Skipped}++;
		return;
	}
	print STDERR "+Passed all $cnt tests for '$fn' user supplied function\n" if $server->{debug} & DEBUG_INFO;
	return 1;
}

#########################################
# process_content -- deals with a response object.  Kinda
#
# returns an array ref of new links to follow
#########################################
sub process_content {
	my ( $response, $server, $uri, $parent, $depth ) = @_;
	my $content = $response->content;

	# Check for meta robots tag
	# -- should probably be done in request sub to avoid fetching docs that are not needed
	# -- also, this will not not work with compression $$$ check this

	unless ( $server->{ignore_robots_file}  || $server->{ignore_robots_headers} ) {
		if ( my $directives = $response->header('X-Meta-ROBOTS') ) {
			my %settings = map { lc $_, 1 } split /\s*,\s*/, $directives;
			$server->{no_contents}++ if exists $settings{nocontents};  # an extension for swish
			$server->{no_index}++    if exists $settings{noindex};
			$server->{no_spider}++   if exists $settings{nofollow};
		}
	}

	# Uncompress content
	if ( (my $encoding = $response->header('Content-Encoding') )  ) {
		$content = Compress::Zlib::memGunzip($content) if $encoding =~ /gzip/i;
		$content = Compress::Zlib::uncompress($content) if $encoding =~ /deflate/i;
	}

	## Call preparse_content to run admin specified code on the content
	##my %preparse_ret = preparse_content(content => \$content, url => $uri->as_string);
	##if ( $preparse_ret{'skip'} ) {
	##	print STDERR "-Skipped $uri\n" if $server->{debug} & DEBUG_SKIPPED;
	##	$server->{counts}{Skipped}++;
	##	$server->{counts}{'MD5 Duplicates'}++;
	##	return;
	##}

	# make sure content is unique - probably better to chunk into an MD5 object above
	if ( $server->{use_md5} ) {
		my $digest =  $response->header('Content-MD5') || Digest::MD5::md5_hex($content);
		my $digest_url = &get_visited_url( $digest );

		if ( $digest_url ) {

			# $uri is being skipped becuase its content was already
			# indexed at another URL

			print STDERR "-Skipped $uri has same digest as $digest_url\n" if $server->{debug} & DEBUG_SKIPPED;

			$server->{counts}{Skipped}++;
			$server->{counts}{'MD5 Duplicates'}++;
			return;
		}
		&set_visited_url_digest($digest, $uri);
	}

	## return if Link's content has not changed since last time it was spidered
	unless ( content_modified( uri => $uri->as_string, response => $response, content => $content ) ) {
		print STDERR "-Skipped $uri has same digest as as before\n"; ## if $server->{debug} & DEBUG_SKIPPED;
		return;
	}

	# Extract out links (if not too deep)
	my $links_extracted = extract_links( $server, \$content, $response )
	unless defined $server->{max_depth} && $depth >= $server->{max_depth};

	# Index the file
	if ( $server->{no_index} ) {
		$server->{counts}{Skipped}++;
		print STDERR "-Skipped indexing $uri some callback set 'no_index' flag\n" if $server->{debug}&DEBUG_SKIPPED;

	} else {
		return $links_extracted unless check_user_function( 'filter_content', $uri, $server, $response, \$content );
		output_content( $server, \$content, $uri, $response ) unless $server->{no_index};
	}

	return $links_extracted;
}

#########################################
#  Extract links from a text/html page
#   Call with:
#       $server - server object
#       $content - ref to content
#       $response - response object
#########################################
sub extract_links {
	my ( $server, $content, $response ) = @_;

	return unless $response->header('content-type') && $response->header('content-type') =~ m[^text/html];

	# allow skipping.
	if ( $server->{no_spider} ) {
		if ( $server->{debug}&DEBUG_SKIPPED ) {
			print STDERR '-Links not extracted:', $response->request->uri->canonical, " some callback set 'no_spider' flag\n";
		}
		return;
	}

	$server->{Spidered}++;

	my @links;
	my $base = $response->base;
	&incr_visited_hash($base); # $$$ come back and fix this (see 4/20/03 lwp post)

	print STDERR "\nExtracting links from ", $response->request->uri, ":\n" if $server->{debug} & DEBUG_LINKS;

	my $p = HTML::LinkExtor->new;
	Encode::encode_utf8( $$content );
	$p->parse( $$content );

	my %skipped_tags;

	for ( $p->links ) {
		my ( $tag, %attr ) = @$_;

		# which tags to use ( not reported in debug )
		my $attr = join ' ', map { qq[$_="$attr{$_}"] } keys %attr;

		print STDERR "\nLooking at extracted tag '<$tag $attr>'\n" if $server->{debug} & DEBUG_LINKS;
		unless ( $server->{link_tags_lookup}{$tag} ) {

			# each tag is reported only once per page
			print STDERR
			"   <$tag> skipped because not one of (",
			join( ',', @{$server->{link_tags}} ),
			")\n" if $server->{debug} & DEBUG_LINKS && !$skipped_tags{$tag}++;

			if ( $server->{validate_links} && $tag eq 'img' && $attr{src} ) {
				my $img = URI->new_abs( $attr{src}, $base );
				validate_link( $server, $img, $base );
			}

			next;
		}

		# Grab which attribute(s) which might contain links for this tag
		my $links = $HTML::Tagset::linkElements{$tag};
		$links = [$links] unless ref $links;

		my $found;

		# Now, check each attribut to see if a link exists
		for my $attribute ( @$links ) {
			if ( $attr{ $attribute } ) {  # ok tag

				# Create a URI object
				my $u = URI->new_abs( $attr{$attribute},$base );

				next unless check_link( $u, $server, $base, $tag, $attribute );

				##$u = URI->new( rem_sidvar_fromurl( url => $u->as_string ) );
				unless( url_indexed( url => $u->as_string ) ) {
					push @links, $u;
					print STDERR qq[   $attribute="$u" Added to list of links to follow\n] if $server->{debug} & DEBUG_LINKS;
					$found++;
				}
			}
		}

		if ( !$found && $server->{debug} & DEBUG_LINKS ) {
			print STDERR "  tag did not include any links to follow or is a duplicate\n";
		}

	}

	print STDERR "! Found ", scalar @links, " links in ", $response->base, "\n\n" if $server->{debug} & DEBUG_INFO;
	return \@links;
}

#########################################
# This function check's if a link should be added to the list to spider
#
#   Pass:
#       $u - URI object
#       $server - the server hash
#       $base - the base or parent of the link
#
#   Returns true if a valid link
#
#   Calls the user function "test_url".  Link rewriting before spider
#   can be done here.
#########################################
sub check_link {
	my ( $u, $server, $base, $tag, $attribute ) = @_;

	$tag ||= '';
	$attribute ||= '';

	# Kill the fragment
	$u->fragment( undef );

	# Here we make sure we are looking at a link pointing to the correct (or equivalent) host
	unless ( $server->{scheme} eq $u->scheme && $server->{same_host_lookup}{$u->canonical->authority||''} ) {

		print STDERR qq[ ?? <$tag $attribute="$u"> skipped because different host\n] if $server->{debug} & DEBUG_LINKS;
		$server->{counts}{'Off-site links'}++;
		validate_link( $server, $u, $base ) if $server->{validate_links};
		return;
	}

	$u->host_port( $server->{authority} );  # Force all the same host name

	# Allow rejection of this URL by user function
	return unless check_user_function( 'test_url', $u, $server );

	# Don't add the link if already seen  - these are so common that we don't report
	# Might be better to do something like $visited{ $u->path } or $visited{$u->host_port}{$u->path};

	if ( &incr_visited_hash($u->canonical) ) {
		#$server->{counts}{Skipped}++;
		$server->{counts}{Duplicates}++;

		# Just so it's reported for all pages
		if ( $server->{validate_links} && $validated{$u->canonical} ) {
			push @{$bad_links{ $base->canonical }}, $u->canonical;
		}

		return;
	}

	return 1;
}

#########################################
# This function is used to validate links that are off-site.
#
#   It's just a very basic link check routine that lets you validate the
#   off-site links at the same time as indexing.  Just because we can.
#########################################
sub validate_link {
	my ($server, $uri, $base, $response ) = @_;

	$base = URI->new( $base ) unless ref $base;
	$uri = URI->new_abs($uri, $base) unless ref $uri;


	# Already checked?
	if ( exists $validated{ $uri->canonical } ) {
		# Add it to the list of bad links on that page if it's a bad link.
		push @{$bad_links{ $base->canonical }}, $uri->canonical if $validated{ $uri->canonical };
		return;
	}

	$validated{ $uri->canonical } = 0;  # mark as checked and ok.

	unless ( $response ) {
		my $ua = LWP::UserAgent->new(timeout =>  $server->{max_wait_time} );
		my $request = HTTP::Request->new('HEAD', $uri->canonical );
		$response = $ua->simple_request( $request );
	}

	return if $response->is_success;
	my $error = $response->status_line || $response->status || 'unknown status';

	$error .= ' ' . URI->new_abs( $response->header('location'), $response->base )->canonical
        if $response->is_redirect && $response->header('location');

	$validated{ $uri->canonical } = $error;
	push @{$bad_links{ $base->canonical }}, $uri->canonical;
}

#########################################
# output_content -- formats content for swish-e
# PARAM
# 
#########################################
sub output_content {
	my ( $server, $content, $uri, $response ) = @_;

	$server->{indexed}++;

	unless ( length $$content ) {
		print STDERR "Warning: document '", $response->request->uri, "' has no content\n";
		$$content = ' ';
	}

	$server->{counts}{'Total Bytes'} += length $$content;
	$server->{counts}{'Total Docs'}++;

	# ugly and maybe expensive, but perhaps more portable than "use bytes"
	my $bytecount = length pack 'C0a*', $$content;

	# Decode the URL
	my $path = $uri;
	$path =~ s/%([0-9a-fA-F]{2})/chr hex($1)/ge;

	# For Josh
	if ( my $fn = $server->{output_function} ) {
		eval {
			$fn->(
				server => $server,
				content => $content,
				uri => $uri,
				response => $response,
				bytecount => $bytecount,
				path => $path,
			); 
		};
		die "output_function died for $uri: $@\n" if $@;
		return;
	}


	my $headers = join "\n",
        'Path-Name: ' .  $path,
        'Content-Length: ' . $bytecount,
        '';

	$headers .= 'Last-Mtime: ' . $response->last_modified . "\n" if $response->last_modified;

	# Set the parser type if specified by filtering
	if ( my $type = delete $server->{parser_type} ) {
		$headers .= "Document-Type: $type\n";

	} elsif ( $response->content_type =~ m!^text/(html|xml|plain)! ) {
		$type = $1 eq 'plain' ? 'txt' : $1;
		$headers .= "Document-Type: $type*\n";
	}

	$headers .= "No-Contents: 1\n" if $server->{no_contents};

	#print "$headers\n$$content";
	die "$0: Max indexed files Reached\n" if $server->{max_indexed} && $server->{counts}{'Total Docs'} >= $server->{max_indexed};
}

#########################################
# BEGIN SUBROUTINES TO MANAGE %visited HASH
#########################################

#########################################
# transfer_visited_to_db - Subroutines to transfer %visited which
# is locate in memory to the database via the Tied hash %db_visited.
# PARAM: None
# OUTPUT: None
#########################################
sub transfer_visited_to_db {

	# If size of $visited is more then $spiderrdx_config{'max_visited_size'}
	# transfer to db and clear %visited
	if ( $visited_size >= $spiderrdx_config->{'max_visited_size'} ) {

		# Transfer %visited to %db_visited
		foreach my $vh_key (keys(%visited) ) {
			$db_visited{$vh_key} = $visited{$vh_key};
		}

		# Clear %visited
		%visited = ();
		$visited_size = 0;
		$moved_visited_todb = 1;

	} elsif ( $visited_size < $spiderrdx_config->{'max_visited_size'} ) {
		# Get the latest size of the %visited hash.
		$visited_size = Devel::Size::total_size(\%visited);
	}
}

#########################################
# incr_visited_hash - Increment the number of times
# a URL was ecountered while spider by 1.
# There can be three possibilites:
# 1. The URL was encountered and is located in %visited
# 2. The URL was encountered and is located in %db_visited
# 3. The URL was not encountered at all
# PARAM:
# $url -> The url that was encoutner during spidering
# OUTPUT:
# $output -> The number of times the URL was encountered
# before it was incremented. (this output is used to locate
# URLS that were encountered for the first time)
#########################################
sub incr_visited_hash {
	my $url = shift;
	my $output;

	if ( exists( $visited{ $url } ) ) {

		# post increment
		$output = $visited{ $url }++;

		# If %db_visited is valid, make it consistent with %visited
		if ( $moved_visited_todb ) {
			$db_visited{ $url }++;
		}

	} else {

		if ( $moved_visited_todb ) {
			$output = $db_visited{ $url }++;
			$visited{ $url } = $output + 1;
		} else {
			$output = $visited{ $url }++;
		}
	}

	## &transfer_visited_to_db();

	return $output;
}

#########################################
# get_visited_url - Returns the URL that has
# has the a digest matching the input value
# PARAM:
# $digest - The digest of an URL that was
# encountered by the spider
# OUTPUT:
# $output - The URL that matched the digest 
#########################################
sub get_visited_url {
	my $digest = shift;
	my $output;

	$output = $visited{ $digest };
	unless ( $output ) {
		$output = $db_visited{ $digest } if ( $moved_visited_todb );
	}

	return $output;
}

#########################################
# set_visited_url_digest - Stores the URL
# and the Digest of the URL into visited hash
# of visited URLs.
# PARAM:
# $digest - The digest of the URL
# $url - The URL
#########################################
sub set_visited_url_digest {
	my($digest, $uri) = @_;

	unless ( $moved_visited_todb ) {
		$visited{ $digest } = $uri;
	} else {
		$db_visited{ $digest } = $uri;
	}

	## &transfer_visited_to_db();
}
#########################################
# DONE WITH SUBROUTINE TO MANAGE %visited HASH
#########################################

#########################################
# analyze_urls -
#
#
#########################################
sub analyze_urls {
	foreach my $key (keys(%skipped_urls)) {
		my @key_script_url = ($key =~ m/([^\?]*)\?*.*/);
		my $query = qq~
		SELECT COUNT(indexed_url_id)
		FROM spiderrdx_indexed_urls
		WHERE indexed_url LIKE ?;
		~;
		my $res = &dbutils::query(
			'query' => $query,
			'param' => [ "$key_script_url[0]%" ],
			);
		# If only one instance of $key's script_url was indexed
		# then dont analyze this $key, it is most probably covered
		# by SPIDER-EXTENSION 4
		if ( scalar( @{$res} ) < 1 ) {
			next;
		}

		# Get URLs that had the same content as this URL
		$query = qq~
		SELECT indexed_url
		FROM spiderrdx_indexed_urls
		WHERE indexed_url_content_md5=?
		~;
		my $dup_res = &dbutils::query(
			'query' => $query,
			'param' => [$skipped_urls{$key}]
			);
		$dup_res->[scalar(@{$dup_res})]->[0] = $key;

		my @candidate_vars = ();

		foreach my $url (@{$dup_res}) {

			# get list of key/value pairs of http vars
			my @var_pairs = ($url->[0] =~ m/[^\?]+\?(.*)/);
			@var_pairs = split(/&/, $var_pairs[0]) if ( scalar(@var_pairs) );

			if ( scalar( @var_pairs ) == 1 ) {
				# If there is only one var_pair the it means this var_pair
				# uniquely identifies this content. That makes it a potential
				# candidate.
				my @candidate_var = ( $var_pairs[0] =~ m/(\w+)=\w+/ );
				@candidate_vars = ($candidate_var[0]);

			} elsif ( scalar( @var_pairs ) > 1 ) {
				# If there are more than one var_pairs then one of these pairs
				# is more crtical to indentify this content than the other pairs

				#ASSUMPTION: The most critical http_var might be the one which
				# is the shortest. Among multiple such occurences, we choose the
				# one that occurs the first(when paring from left to right)

				my $min_var_len = 0;
				foreach my $var_pair (@var_pairs) {

					my @candidate_var = ( $var_pairs[0] =~ m/(\w+)=\w+/ );
					if ( $min_var_len == 0 ) {
						$min_var_len = length($candidate_var[0]);
					} elsif ( length($candidate_var[0]) < $min_var_len ) {
						$min_var_len = length($candidate_var[0]);
					}
				}

				# All http vars of $min_var_len length are potential candidates
				foreach my $var_pair (@var_pairs) {
					my @candidate_var = ( $var_pair =~ m/(\w+)=\w+/ );
					if ( scalar(@candidate_var) > 0 && length($candidate_var[0]) == $min_var_len ) {
						push(@candidate_vars, ($candidate_var[0]));
					}
				}
			}
		}

		# for URLs that are share the same prefix like $key, we would want to spider
		# only urls that have http vars like $candidate_vars[0]
		# Add rule to skip_rules hash

		if ( !exists( $skip_url_patterns{$key_script_url[0]} ) && scalar(@candidate_vars) > 0 ) {
			#print "\n***** Analyzing URLS spidered but not indexed *****\n";
			my $pattern = "$key_script_url[0]?$candidate_vars[0]=";
			# Escape all regexp metachars
			$pattern =~ s/(\?|\+|\*|\.|\^|\\|\||\[|\{|\(|\))/\\$1/g;
			$pattern = "^$pattern";
			#print "ONLY SPIDER patterns : ", $pattern, "\n";
			$skip_url_patterns{$key_script_url[0]} = $pattern;
			#print "***** DONE Analyzing URLS spidered but not indexed *****\n";
		}
	}
}

#########################################
# commify
#########################################
sub commify {
	local $_  = shift;
	1 while s/^([-+]?\d+)(\d{3})/$1,$2/;
	return $_;
}

#########################################
# default_urls
#########################################
sub default_urls {
	my $validate = 0;
	if ( @ARGV && $ARGV[0] eq 'validate' ) {
		shift @ARGV;
		$validate = 1;
	}

	die "$0: Must list URLs when using 'default'\n" unless @ARGV;

	my $config = default_config();

	$config->{base_url} = [ @ARGV ];

	$config->{validate}++ if $validate;

	return $config;
}

#########################################
# Returns a default config hash
#########################################
sub default_config {
	## See if we have any filters
	my ($filter_sub, $response_sub, $filter);

	return {
		email               => 'swish@user.failed.to.set.email.invalid',
		link_tags           => [qw/ a frame /],
		keep_alive          => 1,
		test_url            => sub {  $_[0]->path !~ /\.(?:gif|jpeg|png)$/i },
		test_response       => $response_sub,
		use_head_requests   => 1,  # Due to the response sub
		filter_content      => $filter_sub,
		filter_object       => $filter,
	};
}

#########################################
# content_modified: returns true if $param{uri}
# wasnt spidered before or was spidered but with different content   
# return false otherwise
# PARAM:
# uri -> uri of the link spidered
# content -> ref to content form the uri 
# response -> the response obj for the uri
#########################################
sub content_modified {
	my %param = @_;
	my ($query, $res);

	my $charset = getCharset( $param{'response'} );

	if ( $charset ) {
		$param{'content'} = Encode::decode( $charset, $param{'content'} );
	}
	$param{'content'} = &spiderrdx_parse::get_text($param{'content'});

	$query = qq~
	SELECT MD5(?)=indexed_url_content_md5
	FROM spiderrdx_indexed_urls
	WHERE indexed_url = ?
	~;
	$res = &dbutils::query(
		query => $query,
		param => [$param{'content'}, $param{'uri'}],
		);

	if( $res && $res->[0]->[0] ) {
		return 0;
	} else {
		return 1;
	}
}

#########################################
# url_indexed: returns true if $param{uri}
# wasnt spidered before. Returns false otherwise
# PARAM:
# url -> uri of the link
#########################################
sub url_indexed {
	my %param = @_;
	my ($query, $res);

	$query = qq~
	SELECT COUNT(*)
	FROM spiderrdx_indexed_urls
	WHERE indexed_url = ?
	~;
	$res = &dbutils::query(
		query => $query,
		param => [$param{'url'}],
		);

	if( $res && $res->[0]->[0] ) {
		return 1;
	} else {
		return 0;
	}
}

1;
