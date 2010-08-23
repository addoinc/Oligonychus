#!/usr/bin/perl
use strict;
use warnings;

# This is set to where Swish-e's "make install" installed the helper modules.
# $Id: spider.pl.in,v 1.14 2004/10/05 18:32:13 whmoseley Exp $
#
# "prog" document source for spidering web servers
#
# For documentation, type:
#
#       perldoc spider.pl
#
#    Copyright (C) 2001-2003 Bill Moseley swishscript@hank.org
#
#    This program is free software; you can redistribute it and/or
#    modify it under the terms of the GNU General Public License
#    as published by the Free Software Foundation; either version
#    2 of the License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    The above lines must remain at the top of this program
#----------------------------------------------------------------------------------
BEGIN {
	$| = 1;

        if ( -e $ENV{OLIGONYCHUS_HOME} && -d $ENV{OLIGONYCHUS_HOME} ) {
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/lib/engine/");
		unshift(@INC, "$ENV{OLIGONYCHUS_HOME}/conf/engine/");
	} else {
		print "Error(1): Environment variable OLIGONYCHUS_HOME incorrect/not set.\n";
		exit 1;
	}
};

$HTTP::URI_CLASS = "URI";   # prevent loading default URI::URL
                            # so we don't store long list of base items
                            # and eat up memory with >= URI 1.13
use LWP::RobotUA;
use HTML::LinkExtor;
use HTML::Tagset;
use HTML::TokeParser;
use Compress::Zlib;
use dbutils qw($dbh);
use spiderrdx_vars;
use spiderrdx_spider;
use spiderrdx_parse;
use spiderrdx_dbhash;
use spiderrdx_config qw( $spiderrdx_config );
use Devel::Size qw(size total_size);
use Encode;
use Time::HiRes;

use vars qw($dbh);
use vars '$VERSION';
$VERSION = sprintf '%d.%02d', q$Revision: 1.14 $ =~ /: (\d+)\.(\d+)/;

# Valid config file options
my @config_options = qw(
	site_id
	agent
	base_url
	cookies
	credentials
	credential_timeout
	debug
	delay_min  (deprecated)
	delay_sec
	email
	filter_content
	get_password
	ignore_robots_file
	keep_alive
	link_tags
	max_depth
	max_files
	max_indexed
	max_size
	max_time
	max_wait_time
	quiet
	remove_leading_dots
	same_hosts
	skip
	spider_done
	test_response
	test_url
	output_function
	use_cookies
	use_default_config
	use_head_requests
	use_md5
	validate_links
	filter_object
	incremental_update
	base_rule
	skip_rule
);
my %valid_config_options = map { $_ => 1 } @config_options;

#Can't locate object method "host" via package "URI::mailto" at ../prog-bin/spider.pl line 473.
#sub URI::mailto::host { return '' };

# This is not the right way to do this.
sub UNIVERSAL::host { '' };
sub UNIVERSAL::port { '' };
sub UNIVERSAL::host_port { '' };
sub UNIVERSAL::userinfo { '' };

setpriority 0,0, 19;

#OPEN DB CONNECTION
&dbutils::connect;
##########

my @servers;
my %site_ids = ();  ## Map of process_id => site_id
my $chld_count = 0; ## Count of number of child process forked by parent process
my $exited_count = 0; ## Count if number of child processes that exited

my $site_ids = [[1]];

AGAIN: {
	## Get the site_id that the child process being forked will work on
	my $child_site_id = $site_ids->[$chld_count]->[0];

	## Fork and store the return value
	my $pid = fork;

	## If process is child
	if ($pid == 0) {
		&dbutils::connect;

		open(STDERR,">$spiderrdx_config->{'log_location'}spider_" . $child_site_id . "_log");
		open(STDOUT,">&STDERR");

		my $start_time = time();

		## Call subroutine to setup @servers
		spiderrdx_spider::get_site_hash(
			servers_ref => \@servers,
			site_id => $child_site_id,
			);

		unless ( @servers ) {
			die "$0: failed to set \@servers array. There might be no sites with spidering enabled.\n";
		}
		die "$0: \@servers array does not contain a hash.\n" unless ref $servers[0] eq 'HASH';

		# Check config options
		for my $server ( @servers ) {
			for ( keys %$server ) {
				unless ( $valid_config_options{$_} ) {
					warn "$0: ** Warning: config option [$_] is unknown.  Perhaps misspelled?\n";
				}
			}
		}

		local $SIG{HUP} = sub {
			warn "Caught SIGHUP\n"; $abort++;
			&spiderrdx_spider::dump_spider_state(
				moved_visited_todb => $moved_visited_todb,
				db_visited => %db_visited,
				visited => %visited,
				);
		} unless $^O =~ /Win32/i;

		# Tie hash to store content-digest and uri that were not indexed/spidered.
		tie %skipped_urls, "spiderrdx_dbhash", { 'table' => 'spiderrdx_skipped_urls' };

		# Tie hash to store repeating script_urls.
		tie %script_url_counter, "spiderrdx_dbhash", { 'table' => 'spiderrdx_scripturl_counter' };

		# Tie hash to store skip rules
		tie %skip_url_patterns, "spiderrdx_dbhash", { 'table' => 'spiderrdx_skipurl_patterns' };

		my $moved_visited_todb = 0;
		my $visited_size = 0;
		# Tie %db_visited to the database
		tie %db_visited, "spiderrdx_dbhash", { 'table' => 'spiderrdx_spider_visited_urls' };
		# If there are URL's from a previous run remove them
		%db_visited = ();

		tie %validated, "spiderrdx_dbhash", { 'table' => 'spiderrdx_validated' };
		tie %bad_links, "spiderrdx_dbhash", { 'table' => 'spiderrdx_bad_links' };

		for my $s ( @servers ) {
			if ( !$s->{base_url} ) {
				die "You must specify 'base_url' in your spider config settings\n";
			}

			# Merge in default config?
			$s = { %{ default_config() }, %$s } if $s->{use_default_config};

			# Now, process each URL listed
			my @urls = ref $s->{base_url} eq 'ARRAY' ? @{$s->{base_url}} :( $s->{base_url});
			for my $url ( @urls ) {
				# purge config options -- used when base_url is an array
				$valid_config_options{$_} ||  delete $s->{$_} for keys %$s;

				$s->{base_url} = $url;
				spiderrdx_spider::process_server( $s );
			}
		}

		if ( %bad_links ) {
			print STDERR "\nBad Links:\n\n";
			foreach my $page ( sort keys %bad_links ) {
				print STDERR "On page: $page\n";
				printf(STDERR " %-40s  %s\n", $_, $validated{$_} ) for @{$bad_links{$page}};
				print STDERR "\n";
			}
		}

		my $end_time = time();
		my $spider_run_time = $end_time - $start_time;
		print STDERR $spider_run_time, " Seconds\n";

		close(STDOUT);
		close(STDERR);
	} else {
		## If process is parent

		$chld_count++; ## Increment number of child processes created
		$site_ids{$child_site_id} = $pid; ## Store a mapping between $pid and $child_site_id

		## Create another child process if needed
		redo AGAIN if($chld_count < 0);

		while( $chld_count < scalar(@{$site_ids}) ) {
			### print "Waiting \n";
			my $exited_pid = wait;
			### print "Done waiting \n";
			if ( $exited_pid > 0 ) {
				$exited_count++;
				redo AGAIN if ($chld_count < scalar(@{$site_ids}) );
			}
		}

		while( $exited_count < $chld_count ) {
			my $exited_pid = wait;
			if ( $exited_pid > 0 ) {
				$exited_count++;
				### print "Done: ", $exited_pid, "\n";
			}
		}
	}
}

&dbutils::disconnect;

__END__

=head1 NAME

spider.pl - Example Perl program to spider web servers

=head1 SYNOPSIS

    spider.pl [<spider config file>] [<URL> ...]

    # Spider using some common defaults and capture the output
    # into a file

    ./spider.pl default http://myserver.com/ > output.txt


    # or using a config file

    spider.config:
    @servers = (
        {
            base_url    => 'http://myserver.com/',
            email       => 'me@myself.com',
            # other spider settings described below
        },
    );

    ./spider.pl spider.config > output.txt


    # or using the default config file spider_output_mgt.pl
    ./spider.pl > output.txt

    # using with swish-e

    ./spider.pl spider.config | swish-e -c swish.config -S prog -i stdin

    # or in two steps
    ./spider.pl spider.config > output.txt
    swish-e -c swish.config -S prog -i stdin < output.txt

    # or with compression
    ./spider.pl spider.config | gzip > output.gz
    gzip -dc output.gz | swish-e -c swish.config -S prog -i stdin

    # or having swish-e call the spider directly using the
    # spider config file spider_output_mgt.pl:
    swish-e -c swish.config -S prog -i spider.pl


    # or the above but passing passing a parameter to the spider:
    echo "SwishProgParameters  spider.config" >> swish.config
    echo "IndexDir spider.pl" >> swish.config
    swish-e -c swish.config -S prog


    Note: When running on some versions of Windows (e.g. Win ME and Win 98 SE)
    you may need to tell Perl to run the spider directly:

        perl spider.pl | swish-e -S prog -c swish.conf -i stdin

    This pipes the output of the spider directly into swish.


=head1 DESCRIPTION

F<spider.pl> is a program for fetching documnts from a web server,
and outputs the documents to STDOUT in a special format designed
to be read by Swish-e.

The spider can index non-text documents such as PDF and MS Word by use of
filter (helper) programs.  These programs are not part of the Swish-e
distribution and must be installed separately.  See the section on filtering
below.

A configuration file is noramlly used to control what documents are fetched
from the web server(s).  The configuration file and its options are described
below.  The is also a "default" config suitable for spidering.

The spider is designed to spider web pages and fetch documents from one
host at a time -- offsite links are not followed.  But, you can configure
the spider to spider multiple sites in a single run.

F<spider.pl> is distributed with Swish-e and is installed in the swish-e
library directory at installation time.  This directory (libexedir) can
be seen by running the command:

    swish-e -h

Typically on unix-type systems the spider is installed at:

    /usr/local/lib/swish-e/spider.pl

This spider stores all links in memory while processing and does not do
parallel requests.

=head2 Running the spider

The output from F<spider.pl> can be captured to a temporary file which is then
fed into swish-e:

    ./spider.pl > docs.txt
    swish-e -c config -S prog -i stdin < docs.txt

or the output can be passed to swish-e via a pipe:

   ./spider.pl | swish-e -c config -S prog -i stdin

or the swish-e can run the spider directly:

   swish-e -c config -S prog -i spider.pl

One advantage of having Swish-e run F<spider.pl> is that Swish-e knows
where to locate the program (based on libexecdir compiled into swish-e).

When running the spider I<without> any parameters it looks for a configuration file
called F<spider_output_mgt.pl> in the current directory.  The spider will abort
with an error if this file is not found.

A configuration file can be specified as the first parameter to the spider:

    ./spider.pl spider.config > output.txt

If running the spider via Swish-e (i.e. Swish-e runs the spider) then use
the Swish-e config option L<SwishProgParameters|SWISH-CONFIG/"item_SwishProgParameters">
to specify the config file:

In swish.config:

    # Use spider.pl as the external program:
    IndexDir spider.pl
    # And pass the name of the spider config file to the spider:
    SwishProgParameters spider.config

And then run Swish-e like this:

    swish-e -c swish.config -S prog

Finally, by using the special word "default" on the command line the spider will
use a default configuration that is useful for indexing most sites.  It's a good
way to get started with the spider:

    ./spider.pl default http://my_server.com/index.html > output.txt

There's no "best" way to run the spider.  I like to capture to a file
and then feed that into Swish-e.

The spider does require Perl's LWP library and a few other reasonably common
modules.  Most well maintained systems should have these modules installed.
See  L<REQUIREMENTS> below for more information.  It's a good idea to check
that you are running a current version of these modules.

Note: the "prog" document source in Swish-e bypasses many Swish-e configuration
settings.  For example, you cannot use the
L<IndexOnly|SWISH-CONFIG/"item_SwishProgParameters"> directive with the "prog"
document source.  This is by design to limit the overhead when using an
external program for providing documents to swish; after all, with "prog", if
you don't want to index a file, then don't give it to swish to index in the
first place.

So, for spidering, if you do not wish to index images, for example, you will
need to either filter by the URL or by the content-type returned from the web
server.  See L</"CALLBACK FUNCTIONS"> below for more information.


=head2 Robots Exclusion Rules and being nice

By default, this script will not spider files blocked by F<robots.txt>.  In addition,
The script will check for <meta name="robots"..> tags, which allows finer
control over what files are indexed and/or spidered.
See http://www.robotstxt.org/wc/exclusion.html for details.

This spider provides an extension to the <meta> tag exclusion, by adding a
B<NOCONTENTS> attribute.  This attribute turns on the C<no_contents> setting, which
asks swish-e to only index the document's title (or file name if not title is found).

For example:

      <META NAME="ROBOTS" CONTENT="NOCONTENTS, NOFOLLOW">

says to just index the document's title, but don't index its contents, and don't follow
any links within the document.  Granted, it's unlikely that this feature will ever be used...

If you are indexing your own site, and know what you are doing, you can disable robot
exclusion by the C<ignore_robots_file> configuration parameter, described below.  This
disables both F<robots.txt> and the meta tag parsing.  You may disable just the meta tag
parsing by using C<ignore_robots_headers>.

This script only spiders one file at a time, so load on the web server is not that great.
And with libwww-perl-5.53_91 HTTP/1.1 keep alive requests can reduce the load on
the server even more (and potentially reduce spidering time considerably).

Still, discuss spidering with a site's administrator before beginning.
Use the C<delay_sec> to adjust how fast the spider fetches documents.
Consider running a second web server with a limited number of children if you really
want to fine tune the resources used by spidering.

=head2 Duplicate Documents

The spider program keeps track of URLs visited, so a document is only indexed
one time.

The Digest::MD5 module can be used to create a "fingerprint" of every page
indexed and this fingerprint is used in a hash to find duplicate pages.
For example, MD5 will prevent indexing these as two different documents:

    http://localhost/path/to/some/index.html
    http://localhost/path/to/some/

But note that this may have side effects you don't want.  If you want this
file indexed under this URL:

    http://localhost/important.html

But the spider happens to find the exact content in this file first:

    http://localhost/developement/test/todo/maybeimportant.html

Then only that URL will be indexed.

=head2 Broken relative links

Sometimes web page authors use too many C</../> segments in relative URLs which reference
documents above the document root.  Some web servers such as Apache will return a
400 Bad Request when requesting a document above the root.  Other web servers such as
Micorsoft IIS/5.0 will try and "correct" these errors.  This correction will lead to
loops when spidering.

The spider can fix these above-root links by placing the following in your spider config:

    remove_leading_dots => 1,

It is not on by default so that the spider can report the broken links (as 400 errors on
sane webservers).

=head2 Compression

If The Perl module Compress::Zlib is installed the spider will send the

   Accept-Encoding: gzip

header and uncompress the document if the server returns the header

   Content-Encoding: gzip

MD5 checksomes are done on the compressed data.

MD5 may slow down indexing a tiny bit, so test with and without if speed is an
issue (which it probably isn't since you are spidering in the first place).
This feature will also use more memory.

=head1 REQUIREMENTS

Perl 5 (hopefully at least 5.00503) or later.

You must have the LWP Bundle on your computer.  Load the LWP::Bundle via the CPAN.pm shell,
or download libwww-perl-x.xx from CPAN (or via ActiveState's ppm utility).
Also required is the the HTML-Parser-x.xx bundle of modules also from CPAN
(and from ActiveState for Windows).

    http://search.cpan.org/search?dist=libwww-perl
    http://search.cpan.org/search?dist=HTML-Parser

You will also need Digest::MD5 if you wish to use the MD5 feature.
HTML::Tagset is also required.
Other modules may be required (for example, the pod2xml.pm module
has its own requirementes -- see perldoc pod2xml for info).

The spider.pl script, like everyone else, expects perl to live in /usr/local/bin.
If this is not the case then either add a symlink at /usr/local/bin/perl
to point to where perl is installed
or modify the shebang (#!) line at the top of the spider.pl program.

Note that the libwww-perl package does not support SSL (Secure Sockets Layer) (https)
by default.  See F<README.SSL> included in the libwww-perl package for information on
installing SSL support.

=head1 CONFIGURATION FILE

The spider configuration file is a read by the script as Perl code.
This makes the configuration a bit more complex than simple text config
files, but allows the spider to be configured programmatically.

For example, the config file can contain logic for testing URLs against regular
expressions or even against a database lookup while running.

The configuration file sets an array called C<@servers>.  This array can contain
one or more hash structures of parameters.  Each hash structure is a configuration for
a single server.

Here's an example:

    my %main_site = (
        base_url   => 'http://example.com',
        same_hosts => 'www.example.com',
        email      => 'admin@example.com',
    );

    my %news_site = (
        base_url   => 'http://news.example.com',
        email      => 'admin@example.com',
    );

    @servers = ( \%main_site, \%news_site );
    1;

The above defines two Perl hashes (%main_site and %news_site) and then places
a *reference* (the backslash before the name of the hash) to each of those
hashes in the @servers array.  The "1;" at the end is required at the end
of the file (Perl must see a true value at the end of the file).

The C<config file path> is the first parameter passed to the spider script.

    ./spider.pl F<config>

If you do not specify a config file then the spider will look for the file
F<spider_output_mgt.pl> in the current directory.

The Swish-e distribution includes a F<spider_output_mgt.pl> file with a few
example configurations.  This example file is installed in the F<prog-bin/>
documentation directory (on unix often this is
/usr/local/share/swish-e/prog-bin).

When the special config file name "default" is used:

    SwishProgParameters default http://www.mysite/index.html [<URL>] [...]

Then a default set of parameters are used with the spider.  This is a good way to start
using the spider before attempting to create a configuration file.

The default settings skip any urls that look like images (well, .gif .jpeg
.png), and attempts to filter PDF and MS Word documents IF you have the
required filter programs installed (which are not part of the Swish-e
distribution).  The spider will follow "a" and "frame" type of links only.

Note that if you do use a spider configuration file that the default configuration will NOT
be used (unless you set the "use_default_config" option in your config file).


=head1 CONFIGURATION OPTIONS

This describes the required and optional keys in the server configuration hash, in random order...

=over 4

=item base_url

This required setting is the starting URL for spidering.

This sets the first URL the spider will fetch.  It does NOT limit spidering
to URLs at or below the level of the directory specified in this setting.
For that feature you need to use the C<test_url> callback function.



Typically, you will just list one URL for the base_url.  You may specify more
than one URL as a reference to a list and each will be spidered:

    base_url => [qw! http://swish-e.org/ http://othersite.org/other/index.html !],

but each site will use the same config opions.  If you want to index two separate
sites you will likely rather add an additional configuration to the
@servers array.

You may specify a username and password:

    base_url => 'http://user:pass@swish-e.org/index.html',

If a URL is protected by Basic Authentication you will be prompted for a
username and password.  The parameter C<max_wait_time> controls how long to
wait for user entry before skipping the current URL.  See also C<credentials>
below.


=item same_hosts

This optional key sets equivalent B<authority> name(s) for the site you are spidering.
For example, if your site is C<www.mysite.edu> but also can be reached by
C<mysite.edu> (with or without C<www>) and also C<web.mysite.edu> then:


Example:

    $serverA{base_url} = 'http://www.mysite.edu/index.html';
    $serverA{same_hosts} = ['mysite.edu', 'web.mysite.edu'];

Now, if a link is found while spidering of:

    http://web.mysite.edu/path/to/file.html

it will be considered on the same site, and will actually spidered and indexed
as:

    http://www.mysite.edu/path/to/file.html

Note: This should probably be called B<same_host_port> because it compares the URI C<host:port>
against the list of host names in C<same_hosts>.  So, if you specify a port name in you will
want to specify the port name in the the list of hosts in C<same_hosts>:

    my %serverA = (
        base_url    => 'http://sunsite.berkeley.edu:4444/',
        same_hosts  => [ qw/www.sunsite.berkeley.edu:4444/ ],
        email       => 'my@email.address',
    );


=item email

This required key sets the email address for the spider.  Set this to
your email address.

=item agent

This optional key sets the name of the spider.

=item link_tags

This optional tag is a reference to an array of tags.  Only links found in these tags will be extracted.
The default is to only extract links from E<gt>aE<lt> tags.

For example, to extract tags from C<a> tags and from C<frame> tags:

    my %serverA = (
        base_url    => 'http://sunsite.berkeley.edu:4444/',
        same_hosts  => [ qw/www.sunsite.berkeley.edu:4444/ ],
        email       => 'my@email.address',
        link_tags   => [qw/ a frame /],
    );

=item use_default_config

This option is new for Swish-e 2.4.3.

The spider has a hard-coded default configuration that's available when the spider
is run with the configuration file listed as "default":

    ./spider.pl default <url>

This default configuration skips urls that match the regular expression:

    /\.(?:gif|jpeg|png)$/i

and the spider will attempt to use the SWISH::Filter module for filtering non-text
documents.  (You still need to install programs to do the actual filtering, though).

Here's the basic config for the "default" mode:

    @servers = (
    {
        email               => 'swish@user.failed.to.set.email.invalid',
        link_tags           => [qw/ a frame /],
        keep_alive          => 1,
        test_url            => sub {  $_[0]->path !~ /\.(?:gif|jpeg|png)$/i },
        test_response       => $response_sub,
        use_head_requests   => 1,  # Due to the response sub
        filter_content      => $filter_sub,
    } );

The filter_content callback will be used if SWISH::Filter was loaded and ready to use.
This doesn't mean that filtering will work automatically -- you will likely need to install
aditional programs for filtering (like Xpdf or Catdoc).

The test_response callback will be set to test if a given content type can be filtered
by SWISH::Filter (if SWISH::Filter was loaded), otherwise, it will check for 
content-type of text/* -- any text type of document.


Normally, if you specify your own config file:

    ./spider.pl my_own_spider.config

then you must setup those features available in the default setting in your own config
file.  But, if you wish to build upon the "default" config file then set this option.

For example, to use the default config but specify your own email address:

    @servers = (
        {
            email               => my@email.address,
            use_default_config  => 1,
            delay_sec           => 0,
        },
    );
    1;

What this does is "merge" your config file with the default config file.

=item delay_sec

This optional key sets the delay in seconds to wait between requests.  See the
LWP::RobotUA man page for more information.  The default is 5 seconds.
Set to zero for no delay.

When using the keep_alive feature (recommended) the delay will be used only
where the previous request returned a "Connection: closed" header.


=item delay_min  (deprecated)

Set the delay to wait between requests in minutes.  If both delay_sec and
delay_min are defined, delay_sec will be used.


=item max_wait_time

This setting is the number of seconds to wait for data to be returned from
the request.  Data is returned in chunks to the spider, and the timer is
reset each time a new chunk is reported.  Therefore, documents (requests)
that take longer than this setting should not be aborted as long as some
data is received every max_wait_time seconds. The default it 30 seconds.

NOTE: This option has no effect on Windows.

=item max_time

This optional key will set the max minutes to spider.   Spidering
for this host will stop after C<max_time> minutes, and move on to the
next server, if any.  The default is to not limit by time.

=item max_files

This optional key sets the max number of files to spider before aborting.
The default is to not limit by number of files.  This is the number of requests
made to the remote server, not the total number of files to index (see C<max_indexed>).
This count is displayted at the end of indexing as C<Unique URLs>.

This feature can (and perhaps should) be use when spidering a web site where dynamic
content may generate unique URLs to prevent run-away spidering.

=item max_indexed

This optional key sets the max number of files that will be indexed.
The default is to not limit.  This is the number of files sent to
swish for indexing (and is reported by C<Total Docs> when spidering ends).

=item max_size

This optional key sets the max size of a file read from the web server.
This B<defaults> to 5,000,000 bytes.  If the size is exceeded the resource is
skipped and a message is written to STDERR if the DEBUG_SKIPPED debug flag is set.

Set max_size to zero for unlimited size.  If the server returns a Content-Length
header then that will be used.  Otherwise, the document will be checked for
size limitation as it arrives.  That's a good reason to have your server send
Content-Length headers.

See also C<use_head_requests> below.

=item keep_alive

This optional parameter will enable keep alive requests.  This can dramatically speed
up spidering and reduce the load on server being spidered.  The default is to not use
keep alives, although enabling it will probably be the right thing to do.

To get the most out of keep alives, you may want to set up your web server to
allow a lot of requests per single connection (i.e MaxKeepAliveRequests on Apache).
Apache's default is 100, which should be good.

When a connection is not closed the spider does not wait the "delay_sec"
time when making the next request.  In other words, there is no delay in
requesting documents while the connection is open.

Note: try to filter as many documents as possible B<before> making the request to the server.  In
other words, use C<test_url> to look for files ending in C<.html> instead of using C<test_response> to look
for a content type of C<text/html> if possible.
Do note that aborting a request from C<test_response> will break the
current keep alive connection.

Note: you must have at least libwww-perl-5.53_90 installed to use this feature.

=item use_head_requests

This option is new as of swish-e 2.4.3 and can effect the speed of spidering and the
load of the web server.

To understand this you will likely need to read about the L</"CALLBACK FUNCTIONS">
below -- specifically about the C<test_response> callback function.  This option is
also only used when C<keep_alive> is also enabled (although it could be debated that
it's useful without keep alives).

This option tells the spider to use http HEAD requests before each request.

Normally, the spider simply does a GET request and after receiving the first
chunk of data back from the web server calls the C<test_response> callback
function (if one is defined in your config file).  The C<test_response>
callback function is a good place to test the content-type header returned from
the server and reject types that you do not want to index.

Now, *if* you are using the C<keep_alive> feature then rejecting a document 
will often (always?) break the keep alive connection.

So, what the C<use_head_requests> option does is issue a HEAD request for every
document, checks for a Content-Length header (to check if the document is larger than
C<max_size>, and then calls your C<test_response> callback function.  If your callback
function returns true then a GET request is used to fetch the document.

The idea is that by using HEAD requests instead of GET request a false return from 
your C<test_response> callback function (i.e. rejecting the document) will not
break the keep alive connection.

Now, don't get too excited about this.  Before using this think about the ratio of
rejected documents to accepted documents.  If you reject no documents then using this feature
will double the number of requests to the web server -- which will also double the number of
connections to the web server.  But, if you reject a large percentage of documents then
this feature will help maximize the number of keep alive requests to the server (i.e.
reduce the number of separate connections needed).

There's also another problem with using HEAD requests.  Some broken servers
may not respond correctly to HEAD requests (some issues a 500 error), but respond
fine to a normal GET request.  This is something to watch out for.

Finally, if you do not have a C<test_response> callback AND C<max_size> is set to zero
then setting C<use_head_requests> will have no effect.

And, with all other factors involved you might find this option has no effect at all.


=item skip

This optional key can be used to skip the current server.  It's only purpose
is to make it easy to disable a specific server hash in a configuration file.

=item debug

Set this item to a comma-separated list of debugging options.

Options are currently:

    errors, failed, headers, info, links, redirect, skipped, url

Here are basically the levels:

    errors      =>   general program errors (not used at this time)
    url         =>   print out every URL processes
    headers     =>   prints the response headers
    failed      =>   failed to return a 200
    skipped     =>   didn't index for some reason
    info        =>   a little more verbose
    links       =>   prints links as they are extracted
    redirect    =>   prints out redirected URLs

Debugging can be also be set by an environment variable SPIDER_DEBUG when running F<spider.pl>.
You can specify any of the above debugging options, separated by a comma.

For example with Bourne type shell:

    SPIDER_DEBUG=url,links spider.pl [....]

Before Swish-e 2.4.3 you had to use the internal debugging constants or'ed together
like so:

    debug => DEBUG_URL | DEBUG_FAILED | DEBUG_SKIPPED,

You can still do this, but the string version is easier.  In fact, if you want
to turn on debugging dynamically (for example in a test_url() callback
function) then you currently *must* use the DEBUG_* constants.  The string is
converted to a number only at the start of spiderig -- after that the C<debug>
parameter is converted to a number.


=item quiet

If this is true then normal, non-error messages will be supressed.  Quiet mode can also
be set by setting the environment variable SPIDER_QUIET to any true value.

    SPIDER_QUIET=1

=item max_depth

The C<max_depth> parameter can be used to limit how deeply to recurse a web site.
The depth is just a count of levels of web pages decended, and not related to
the number of path elements in a URL.

A max_depth of zero says to only spider the page listed as the C<base_url>.  A max_depth of one will
spider the C<base_url> page, plus all links on that page, and no more.  The default is to spider all
pages.


=item ignore_robots_file

If this is set to true then the robots.txt file will not be checked when spidering
this server.  Don't use this option unless you know what you are doing.

=item use_cookies

If this is set then a "cookie jar" will be maintained while spidering.  Some
(poorly written ;) sites require cookies to be enabled on clients.

This requires the HTTP::Cookies module.

=item use_md5

If this setting is true, then a MD5 digest "fingerprint" will be made from the content of every
spidered document.  This digest number will be used as a hash key to prevent
indexing the same content more than once.  This is helpful if different URLs
generate the same content.

Obvious example is these two documents will only be indexed one time:

    http://localhost/path/to/index.html
    http://localhost/path/to/

This option requires the Digest::MD5 module.  Spidering with this option might
be a tiny bit slower.

=item validate_links

Just a hack.  If you set this true the spider will do HEAD requests all links (e.g. off-site links), just
to make sure that all your links work.

=item credentials

You may specify a username and password to be used automatically when spidering:

    credentials => 'username:password',

A username and password supplied in a URL will override this setting.
This username and password will be used for every request.

See also the C<get_password> callback function below.  C<get_password>, if defined,
will be called when a page requires authorization.

=item credential_timeout

Sets the number of seconds to wait for user input when prompted for a username or password.
The default is 30 seconds.

Set this to zero to wait forever.  Probably not a good idea.

Set to undef to disable asking for a password.

    credential_timeout => undef,


=item remove_leading_dots

Removes leading dots from URLs that might reference documents above the document root.
The default is to not remove the dots.

=back

=head1 CALLBACK FUNCTIONS

Callback functions can be defined in your parameter hash.
These optional settings are I<callback> subroutines that are called while
processing URLs.

A little perl discussion is in order:

In perl, a scalar variable can contain a reference to a subroutine.  The config example above shows
that the configuration parameters are stored in a perl I<hash>.

    my %serverA = (
        base_url    => 'http://sunsite.berkeley.edu:4444/',
        same_hosts  => [ qw/www.sunsite.berkeley.edu:4444/ ],
        email       => 'my@email.address',
        link_tags   => [qw/ a frame /],
    );

There's two ways to add a reference to a subroutine to this hash:

sub foo {
    return 1;
}

    my %serverA = (
        base_url    => 'http://sunsite.berkeley.edu:4444/',
        same_hosts  => [ qw/www.sunsite.berkeley.edu:4444/ ],
        email       => 'my@email.address',
        link_tags   => [qw/ a frame /],
        test_url    => \&foo,  # a reference to a named subroutine
    );

Or the subroutine can be coded right in place:

    my %serverA = (
        base_url    => 'http://sunsite.berkeley.edu:4444/',
        same_hosts  => [ qw/www.sunsite.berkeley.edu:4444/ ],
        email       => 'my@email.address',
        link_tags   => [qw/ a frame /],
        test_url    => sub { reutrn 1; },
    );

The above example is not very useful as it just creates a user callback function that
always returns a true value (the number 1).  But, it's just an example.

The function calls are wrapped in an eval, so calling die (or doing something that dies) will just cause
that URL to be skipped.  If you really want to stop processing you need to set $server->{abort} in your
subroutine (or send a kill -HUP to the spider).

The first two parameters passed are a URI object (to have access to the current URL), and
a reference to the current server hash.  The C<server> hash is just a global hash for holding data, and
useful for setting flags as described below.

Other parameters may be also passed in depending the the callback function,
as described below. In perl parameters are passed in an array called "@_".
The first element (first parameter) of that array is $_[0], and the second
is $_[1], and so on.  Depending on how complicated your function is you may
wish to shift your parameters off of the @_ list to make working with them
easier.  See the examples below.


To make use of these routines you need to understand when they are called, and what changes
you can make in your routines.  Each routine deals with a given step, and returning false from
your routine will stop processing for the current URL.

=over 4

=item test_url

C<test_url> allows you to skip processing of urls based on the url before the request
to the server is made.  This function is called for the C<base_url> links (links you define in
the spider configuration file) and for every link extracted from a fetched web page.

This function is a good place to skip links that you are not interested in following.  For example,
if you know there's no point in requesting images then you can exclude them like:

    test_url => sub {
        my $uri = shift;
        return 0 if $uri->path =~ /\.(gif|jpeg|png)$/;
        return 1;
    },

Or to write it another way:

    test_url => sub { $_[0]->path !~ /\.(gif|jpeg|png)$/ },

Another feature would be if you were using a web server where path names are
NOT case sensitive (e.g. Windows).  You can normalize all links in this situation
using something like

    test_url => sub {
        my $uri = shift;
        return 0 if $uri->path =~ /\.(gif|jpeg|png)$/;

        $uri->path( lc $uri->path ); # make all path names lowercase
        return 1;
    },

The important thing about C<test_url> (compared to the other callback functions) is that
it is called while I<extracting> links, not while actually fetching that page from the web
server.  Returning false from C<test_url> simple says to not add the URL to the list of links to
spider.

You may set a flag in the server hash (second parameter) to tell the spider to abort processing.

    test_url => sub {
        my $server = $_[1];
        $server->{abort}++ if $_[0]->path =~ /foo\.html/;
        return 1;
    },

You cannot use the server flags:

    no_contents
    no_index
    no_spider


This is discussed below.

=item test_response

This function allows you to filter based on the response from the remote server
(such as by content-type).

Web servers use a Content-Type: header to define the type of data returned from the server.
On a web server you could have a .jpeg file be a web page -- file extensions may not always
indicate the type of the file.

If you enable C<use_head_requests> then this function is called after the
spider makes a HEAD request.  Otherwise, this function is called while the web
pages is being fetched from the remote server, typically after just enought
data has been returned to read the response from the web server.

The test_response callback function is called with the following parameters:

    ( $uri, $server, $response, $content_chunk )

The $response variable is a HTTP::Response object and provies methods of examining
the server's response.  The $content_chunk is the first chunk of data returned from
the server (if not a HEAD request).

When not using C<use_head_requests> the spider requests a document in "chunks"
of 4096 bytes.  4096 is only a suggestion of how many bytes to return in each
chunk.  The C<test_response> routine is called when the first chunk is received
only.  This allows ignoring (aborting) reading of a very large file, for
example, without having to read the entire file.  Although not much use, a
reference to this chunk is passed as the forth parameter.

If you are spidering a site with many different types of content that you do
not wish to index (and cannot use a test_url callback to determine what docs to skip)
then you will see better performance using both the C<use_head_requests> and C<keep_alive>
features.  (Aborting a GET request kills the keep-alive session.)

For example, to only index true HTML (text/html) pages:

    test_response => sub {
        my $content_type = $_[2]->content_type;
        return $content_type =~ m!text/html!;
    },

You can also set flags in the server hash (the second parameter) to control indexing:

    no_contents -- index only the title (or file name), and not the contents
    no_index    -- do not index this file, but continue to spider if HTML
    no_spider   -- index, but do not spider this file for links to follow
    abort       -- stop spidering any more files

For example, to avoid index the contents of "private.html", yet still follow any links
in that file:

    test_response => sub {
        my $server = $_[1];
        $server->{no_index}++ if $_[0]->path =~ /private\.html$/;
        return 1;
    },

Note: Do not modify the URI object in this call back function.


=item filter_content

This callback function is called right before sending the content to swish.
Like the other callback function, returning false will cause the URL to be skipped.
Setting the C<abort> server flag and returning false will abort spidering.

You can also set the C<no_contents> flag.

This callback function is passed four parameters.
The URI object, server hash, the HTTP::Response object,
and a reference to the content.

You can modify the content as needed.  For example you might not like upper case:

    filter_content => sub {
        my $content_ref = $_[3];

        $$content_ref = lc $$content_ref;
        return 1;
    },

I more reasonable example would be converting PDF or MS Word documents for
parsing by swish. Examples of this are provided in the F<prog-bin> directory
of the swish-e distribution.

You may also modify the URI object to change the path name passed to swish for indexing.

    filter_content => sub {
        my $uri = $_[0];
        $uri->host('www.other.host') ;
        return 1;
    },

Swish-e's ReplaceRules feature can also be used for modifying the path name indexed.

Note: Swish-e now includes a method of filtering based on the SWISH::Filter
Perl modules.  See the spider_output_mgt.pl file for an example how to use
SWISH::Filter in a filter_content callback function.

If you use the "default" configuration (i.e. pass "default" as the first parameter
to the spider) then SWISH::Filter is used automatically.  This only adds code for
calling the programs to filter your content -- you still need to install applications
that do the hard work (like xpdf for pdf conversion and catdoc for MS Word conversion).


The a function included in the F<spider.pl> for calling SWISH::Filter when using the "default"
config can also be used in your config file.  There's a function called 
swish_filter() that returns a list of two subroutines.  So in your config you could
do:

    my ($filter_sub, $response_sub ) = swish_filter();

    @server = ( {
        test_response   => $response_sub,
        filter_content  => $filter_sub,
        [...],
    } );

The $response_sub is not required, but is useful if using HEAD requests (C<use_head_requests>):
It tests the content type from the server to see if there's any filters that can handle
the document.  The $filter_sub does all the work of filtering a document.

Make sense?  If not, then that's what the Swish-e list is for.


=item spider_done

This callback is called after processing a server (after each server listed
in the @servers array if more than one).

This allows your config file to do any cleanup work after processing.
For example, if you were keeping counts during, say, a test_response() callback
function you could use the spider_done() callback to print the results.


=item output_function

If defined, this callback function is called instead of printing the content
and header to STDOUT.  This can be used if you want to store the output of the
spider before indexing.

The output_function is called with the following parameters:

   ($server, $content, $uri, $response, $bytecount, $path);

Here is an example that simply shows two of the params passed:

    output_function => sub {
        my ($server, $content, $uri, $response, $bytecount, $path) = @_;
        print STDERR  "passed: uri $uri, bytecount $bytecount...\n";
        # no output to STDOUT for swish-e
    }

You can do almost the same thing with a filter_content callback.


=item get_password

This callback is called when a HTTP password is needed (i.e. after the server
returns a 401 error).  The function can test the URI and Realm and then return
a username and password separated by a colon:

    get_password => sub {
        my ( $uri, $server, $response, $realm ) = @_;
        if ( $uri->path =~ m!^/path/to/protected! && $realm eq 'private' ) {
            return 'joe:secret931password';
        }
        return;  # sorry, I don't know the password.
    },

Use the C<credentials> setting if you know the username and password and they will
be the same for every request.  That is, for a site-wide password.


=back

Note that you can create your own counters to display in the summary list when spidering
is finished by adding a value to the hash pointed to by C<$server->{counts}>.

    test_url => sub {
        my $server = $_[1];
        $server->{no_index}++ if $_[0]->path =~ /private\.html$/;
        $server->{counts}{'Private Files'}++;
        return 1;
    },


Each callback function B<must> return true to continue processing the URL.  Returning false will
cause processing of I<the current> URL to be skipped.

=head2 More on setting flags

Swish (not this spider) has a configuration directive C<NoContents> that will instruct swish to
index only the title (or file name), and not the contents.  This is often used when
indexing binary files such as image files, but can also be used with html
files to index only the document titles.

As shown above, you can turn this feature on for specific documents by setting a flag in
the server hash passed into the C<test_response> or C<filter_content> subroutines.
For example, in your configuration file you might have the C<test_response> callback set
as:

    test_response => sub {
        my ( $uri, $server, $response ) = @_;
        # tell swish not to index the contents if this is of type image
        $server->{no_contents} = $response->content_type =~ m[^image/];
        return 1;  # ok to index and spider this document
    }

The entire contents of the resource is still read from the web server, and passed
on to swish, but swish will also be passed a C<No-Contents> header which tells
swish to enable the NoContents feature for this document only.

Note: Swish will index the path name only when C<NoContents> is set, unless the document's
type (as set by the swish configuration settings C<IndexContents> or C<DefaultContents>) is
HTML I<and> a title is found in the html document.

Note: In most cases you probably would not want to send a large binary file to swish, just
to be ignored.  Therefore, it would be smart to use a C<filter_content> callback routine to
replace the contents with single character (you cannot use the empty string at this time).

A similar flag may be set to prevent indexing a document at all, but still allow spidering.
In general, if you want completely skip spidering a file you return false from one of the
callback routines (C<test_url>, C<test_response>, or C<filter_content>).  Returning false from any of those
three callbacks will stop processing of that file, and the file will B<not> be spidered.

But there may be some cases where you still want to spider (extract links) yet, not index the file.  An example
might be where you wish to index only PDF files, but you still need to spider all HTML files to find
the links to the PDF files.

    $server{test_response} = sub {
        my ( $uri, $server, $response ) = @_;
        $server->{no_index} = $response->content_type ne 'application/pdf';
        return 1;  # ok to spider, but don't index
    }

So, the difference between C<no_contents> and C<no_index> is that C<no_contents> will still index the file
name, just not the contents.  C<no_index> will still spider the file (if it's C<text/html>) but the
file will not be processed by swish at all.

B<Note:> If C<no_index> is set in a C<test_response> callback function then
the document I<will not be filtered>.  That is, your C<filter_content>
callback function will not be called.

The C<no_spider> flag can be set to avoid spiderering an HTML file.  The file will still be indexed unless
C<no_index> is also set.  But if you do not want to index and spider, then simply return false from one of the three
callback funtions.


=head1 SIGNALS

Sending a SIGHUP to the running spider will cause it to stop spidering.  This is a good way to abort spidering, but
let swish index the documents retrieved so far.

=head1 CHANGES

List of some of the changes

=head2 Thu Sep 30 2004 - changes for Swish-e 2.4.3


Code reorganization and a few new featues.  Updated docs a little tiny bit.
Introduced a few spelling mistakes.

=over 4

=item Config opiton: use_default_config

It used to be that you could run the spider like:

    spider.pl default <some url>

and the spider would use its own internal config.  But if you used your own
config file then the defaults were not used.  This options allows you to merge
your config with the default config.  Makes making small changes to the default
easy.

=item Config option: use_head_requests

Tells the spider to make a HEAD request before GET'ing the document from the web server.
Useful if you use keep_alive and have a test_response() callback that rejects many documents
(which breaks the connection).

=item Config option: spider_done

Callback to tell you (or tell your config as it may be) that the spider is done.
Useful if you need to do some extra processing when done spidering -- like record
counts to a file.

=item Config option: get_password

This callback is called when a document returns a 401 error needing a username 
and password.  Useful if spidering a site proteced with multiple passwords.

=item Config option: output_function

If defined spider.pl calls this instead of sending ouptut to STDOUT.

=item Config option: debug

Now you can use the words instead of or'ing the DEBUG_* constants together.

=back

=head1 TODO

Add a "get_document" callback that is called right before making the "GET" request.
This would make it easier to use cached documents.  You can do that now in a test_url
callback or in a test_response when using HEAD request.

Save state of the spider on SIGHUP so spidering could be restored at a later date.



=head1 COPYRIGHT

Copyright 2001 Bill Moseley

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SUPPORT

Send all questions to the The SWISH-E discussion list.

See http://sunsite.berkeley.edu/SWISH-E.

=cut

