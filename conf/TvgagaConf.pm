#!/usr/bin/perl
package TvgagaConf;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

our @EXPORT = qw($config $bot_conf);

use DBI;
use Date::Handler;
use Date::Handler::Delta;

our $config = {
        'HBO' => {
                schedules_url =>'http://www.hbosouthasia.com/southasia/print_schedule_thisweek',
                metainfo_url => '',
                schedules_csv => 'hbo_schedules.csv',
        },

        'Star' => {
                schedules_url => 'http://www.startv.com/schedules/IN',
                metainfo_url  => '',
                schedules_csv => '_schedules.csv',

                # Subroutine builds and returns list of query strings
                # to append to schedules_url, and their corresponding output files
                get_params => sub {
                        # $output is an array of hashes. Each hash has the key/values pairs
                        # qstr => query string appened to url
                        # outf => string prepend to output file (to make it uniq)
                        # args => array ref, which will be passed to parser for this entry
                        my $output = [];

                        my $dbh = DBI->connect(
                                "dbi:mysql:tvgaga_dev2:localhost",
                                'tvgaga',
                                'azrihyd',
                        );
                        my $getdate = $dbh->prepare(qq~
                                select ifnull(max(date_format(date_add(
                                sched_date, interval 1 day), '%d-%m-%Y')
                                ),
                                date_format(now(), '%d-%m-%Y'))
                                from channels c, schedules s
                                where c.name = 'Star One' and s.channel_id =c.id;
                        ~);
                        $getdate->execute;
                        my($last_date) = $getdate->fetchrow_array;
                        $last_date = '2007-12-01';

                        my $channels = [
                                { 'Star Plus' => 'f9e31b765218af69a96237fa5c45fa73', },
                                { 'Star Gold' => 'a95e7ddf929536c953f9537a485e9886', },
                                { 'Star One' => 'afdc9aac9b21f5791446e3eb423c9a8d', },
                                { 'Channel V' => '6ef1e98d846dc6c431a59afffc59a1ee', },
                                { 'Star Utsav' => 'ab44d52dea9e732ba6090da1dbb55bd5', },
                                { 'Star World' => '80d2cfa53741be232ced72165733a46d', },
                                { 'Star Movies' => 'adda1c01ba1be2ba1643c69ad2872532', },
                                { 'History Channel' => '92350bebafaa5f4d2a3ea75f563dcdb8', },
                                { 'National Geographic' => 'd24b074b160d61e75d9794c900490149',},
                                { 'NAT GEO Adventure' => '00843ddd30fb4ad570a4da6e713955a0', },
                        ];
                        foreach my $chan ( @{$channels} ) {

                                my $dstr = $last_date;
                                $dstr =~ s~\-~/~g;

                                my ($name, $code) = %{$chan};

                                my $set = {};
                                $set->{'qstr'} = '/' . $code . '/' . $dstr;
                                if ( $set->{'qstr'} =~ m~/\d$~ ) {
                                        $set->{'qstr'} =~ s~^(.*)/(\d+/\d+)/(\d)$~$1/$2/0$3~g;
                                }
                                my $today = join( '/', reverse( split( /\-/ ,$last_date) ));
                                $set->{'outf'} = $name . '_' . $last_date;
                                $set->{'outf'} =~ s/\s/_/g;
                                $set->{'args'} = [ $name, $today ];

                                push @{$output}, $set;

                                my @last_date = split /\-/, $last_date;
                                my $date = new Date::Handler({
                                        date => [
                                                $last_date[0], $last_date[1], $last_date[2],
                                                0, 0, 0
                                        ],
                                        locale => 'en_IN',
                                });
                                my $one_day = new Date::Handler::Delta([0, 0, 1, 0, 0, 0]);
                                $date = $date + $one_day;

                                while ( $date->Month() == $last_date[1] ) {
                                        $dstr= $date->Year() .'/'. $date->Month() .'/'. $date->Day();
                                        my $set2 = {};
                                        $set2->{'qstr'} = '/' . $code . '/' . $dstr;

                                        # add zero to single digit day
                                        if ( $set2->{'qstr'} =~ m~/\d$~ ) {
                                                $set2->{'qstr'} =~ s~^(.*)/(\d+/\d+)/(\d)$~$1/$2/0$3~g;
                                        }

                                        $today = $date->Day() . '/' . $date->Month() . '/' . $date->Year();
                                        my $f_prefix = $today;
                                        $f_prefix =~ s~/~-~g;
                                        $set2->{'outf'} = $name . '_' . $f_prefix;
                                        $set2->{'outf'} =~ s/\s/_/g;
                                        $set2->{'args'} = [ $name, $today ];

                                        push @{$output}, $set2;
                                        $date = $date + $one_day;
                                }

                        }
                        return $output;
                },
        },
	'ndtv' => {
		schedules_url => 'http://www.ndtv.com/convergence/ndtv/schedule.aspx',
                metainfo_url  => '',
                schedules_csv => '_schedules.csv',

                # Subroutine builds and returns list of query strings
                # to append to schedules_url, and their corresponding output files
                get_params => sub {
                        # $output is an array of hashes. Each hash has the key/values pairs
                        # qstr => query string appened to url
                        # outf => string prepend to output file (to make it uniq)
                        # args => array ref, which will be passed to parser for this entry
                        my $output = [];

			my $channels = [
                                { 'NDTV 24x7' => '?progcat=english&today=', },
                                { 'NDTV India' => '?progcat=hindi&today=', },
                                { 'NDTV Profit' => '?progcat=business&today=', },
                        ];
			my @days = qw( '', '', '' 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday');
                        foreach my $chan ( @{$channels} ) {
				
			}
		},
	},
};

our $bot_conf = {
        name => 'Azri Oligonychus beta.',
        email => 'ror@azri.biz',
        delay => 0,
};

1;
