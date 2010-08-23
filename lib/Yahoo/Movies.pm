package Yahoo::Movies;

use strict;
use warnings;

use vars qw($VERSION $AUTOLOAD %FIELDS);

use fields qw(
        id
        title
        cover
        year
        mpaa_rating
        distributor
        release_date
        runtime
        genres
        plot_summary
        people
        matched
        error
        error_msg
        _proxy
        _timeout
        _user_agent
        _page
        _parser
        _search
        _server_url
        _search_uri
        _movie_uri
);

BEGIN {
        $VERSION = '0.01d';
}

use LWP::Simple qw(get $ua);
use HTML::TokeParser;
use Carp;

use Data::Dumper;

{
        my $_class_def = {
                error           => 0,
                error_msg       => '',
                mpaa_rating     => [],
                _timeout        => 10,
                _user_agent     => 'Mozilla/5.0',
                _server_url     => 'http://movies.yahoo.com',
                _movie_uri      => '/shop?d=hv&cf=info&id=',
                _search_uri     => '/mv/search?type=feature&p=',
        };

        sub _class_def { $_class_def }
        sub _get_default_val {
                my $self = shift;
                my $attr = shift;

                return $_class_def->{$attr};
        }
}


sub new {
        my $class = shift;
        my $self = {};
        bless $self, $class;
        $self->_init(@_);
        return $self;
}

sub _init {
        my $self = shift;
        my %params = @_;

        for my $prop(keys %FIELDS) {
                my $attr = $prop;
                $attr =~ s/^_//;
                $self->{$prop} = exists $params{$attr} ? $params{$attr}
                  : $self->_get_default_val($prop);
        }

        if($self->proxy) { $ua->proxy(['http'], $self->proxy) }
        else { $ua->env_proxy }

        $ua->agent($self->user_agent);
        $ua->timeout($self->timeout);

        $self->_get_page();
        return if $self->error;

        $self->parse_page();
}

sub _get_page {
        my $self = shift;

        croak "Wrong paramter!" if $self->id !~ /^\d+$/ && $self->_search;

        my $url = $self->_server_url.($self->id =~ /^\d+$/ && length($self->id) > 4 ? $self->_movie_uri : $self->_search_uri).$self->id;

        $self->{_page} = get($url) || die "Cannot connect to the Yahoo: $!!";

        unless($self->id =~ /^\d+$/ && length($self->id) > 4) {
                $self->_process_page();
                $self->_search(1);
        }
}

sub _process_page {
        my $self = shift;

        if($self->_page =~ /no\s+matches\s+were\s+found/i) {
                $self->error_msg("Nothing found!");
                $self->error(1);
                return;
        }

        my $parser = $self->_parser;

        my($tag, $text);
        while($tag = $parser->get_tag('b')) {
                $text = $parser->get_text();
                last if $text =~ /top\s+matching\s+movie\s+titles/i;
        }

        $parser->get_tag('table');

        while($tag = $parser->get_tag) {

                if($tag->[0] eq 'a' && $tag->[1]{href} =~ m#/(\d+)/info#) {
                        $text = $parser->get_trimmed_text('a', 'br');
                        my $id = $1;
                        $self->matched($id, $text);
                }

                last if $tag->[0] eq '/table';
        }

        if($self->matched) {
                $self->id($self->matched->[0]{id});
                $self->_get_page();
        } else {
                $self->error_msg("Nothing matched!");
                $self->error(1);
                return;
        }
}

sub matched {
        my $self = shift;
        if(@_) {
                my($id, $title) = @_;
                push @{ $self->{matched} }, {id => $id, title => $title};
        }

        return $self->{matched};
}

sub proxy {
        my $self = shift;
        if(@_) { $self->{_proxy} = shift }
        return $self->{_proxy};
}

sub timeout {
        my $self = shift;
        if(@_) { $self->{_timeout} = shift }
        return $self->{_timeout}
}

sub user_agent {
        my $self = shift;
        if(@_) { $self->{_user_agent} = shift }
        return $self->{_user_agent}
}

sub parse_page {
        my $self = shift;

        $self->_parse_title();
        $self->_parse_details();
        $self->_parse_cover();
        $self->_parse_trailer();
        $self->_parse_plot();
}

sub cover_file {
        my $self = shift;
        if($self->cover) {
                my($file_name) = $self->cover =~ /(?:.+)\/(.+)$/;
                return $file_name;
        }
}

sub mpaa_rating {
        my $self = shift;

        if($_[0] && ref($_[0]) eq 'ARRAY') { $self->{mpaa_rating} = shift }

        return wantarray ? @{ $self->{mpaa_rating} } : $self->{mpaa_rating}[0];
}

sub directors {
        my $self = shift;
        return $self->{'people'}->{'directors'} if $self->{'people'};
}

sub producers {
        my $self = shift;
        return $self->{'people'}->{'producers'} if $self->{'people'};
}

sub cast {
        my $self = shift;
        return $self->{'people'}->{'cast'} if $self->{'people'};
}

sub _parser {
        my $self = shift;
        $self->{_parser} = new HTML::TokeParser(\$self->_page());
        return $self->{_parser};
}

sub _parse_title {
        my $self = shift;

        ($self->{title}, $self->{year}) =
                        $self->_page =~ m#<h1><strong>(.+)\s+\((\d+)\)</strong></h1>#mi;
}

sub _parse_details {
        my $self = shift;
        my $p = $self->_parser();
        while($p->get_tag('b')) {
                my $t;
                my $caption = $p->get_text;

                SWITCH: for($caption) {
                        /^Genres/ && do {
                                $t = $p->get_trimmed_text('/tr');
                                $self->genres([split m#/#, $t]);
                                last SWITCH; };
                        /^Running Time/ && do {
                                $t = $p->get_trimmed_text('/tr');
                                $self->runtime($self->_parse_runtime($t));
                                last SWITCH; };
                        /^Release Date/ && do {
                                $t = $p->get_trimmed_text('b');
                                my($mon, $day, $year) = $t =~ /(.+?)\s+(\d+)(?:th|sd|st)?,\s+(\d+)\s?(?:[.(])?/;
                                my $date = "$day $mon $year";
                                $self->release_date($date);
                                last SWITCH; };
                        /^MPAA Rating/ && do {
                                $t = $p->get_trimmed_text('/tr');
                                my($code, $descr) = $t =~ /(.+?)\s+(.+)/;
                                $self->mpaa_rating([$code, $descr]);
                                last SWITCH; };
                        /^Distributor/ && do {
                                $t = $p->get_trimmed_text('/tr');
                                my($distr) = $t =~ /(.*)\./;
                                $self->distributor($distr);
                                last SWITCH; };
                        /^Cast and Credits$/ && do {
                                $self->_parse_people($p);
                                last SWITCH; };
                };
        }
}

sub _parse_cover {
        my $self = shift;
        my $p = $self->_parser();

        while(my $tag = $p->get_tag('img')) {
                if($tag->[1]{alt} && $tag->[1]{alt} =~ /^$self->{title}/i) {
                        $self->{cover} = $tag->[1]{src};
                        last;
                }
        }
}

sub _parse_trailer {
        my $self = shift;
        my $p = $self->_parser();

        while(my $tag = $p->get_tag('a')) {
                if($tag->[1]{href} =~ /videoWin/i) {
                        $self->{trailer} = $tag->[1]{href};
                        last;
                }
        }
}

sub _parse_plot {
        my $self = shift;
        my $p = $self->_parser();

        while(my $tag = $p->get_token()) {
                if($tag->[0] eq 'C') {
                        last if $tag->[1] =~ /another vertical spacer/;
                }
        }

        $p->get_tag('font');
        $self->{plot_summary} = $p->get_trimmed_text('font', 'table');
}

sub _parse_runtime {
        my($self, $time_str) = @_;
        my $time = '';

        if($time_str) {
                my($hours, $min) =
                  $time_str =~ m#(\d{0,2})(?:\s+hr\w?\.?)(?:\s+?)(\d{1,2})\s+min\.?#;
                $time = $hours*60 + $min;
        }

        return $time;
}

sub _parse_people {
  my($self, $p) = @_;
  my $key;
  while(my $tag = $p->get_token) {
    if($tag->[1] eq 'font') {
      my $text = $p->get_text();
      if($text eq 'Starring:') { $key = 'cast' }
      elsif($text eq 'Directed by:') { $key = 'directors' }
      elsif($text eq 'Produced by:') { $key = 'producers' }
    }
    if($tag->[0] eq 'S' && $tag->[1] eq 'a') {
      if($tag->[2]{href} =~ /\/movie\/contributor\/\d+/ && $key) {
        push @{ $self->{'people'}->{$key} }, [$1, $p->get_text];
      }
    }
  }
}

sub AUTOLOAD {
  my $self = shift;
  my($class, $attr) = $AUTOLOAD =~ /(.*)::(.*)/;
  my($pack, $file, $line) = caller;
  if(exists $FIELDS{$attr}) {
    $self->{$attr} = shift() if @_;
    return $self->{$attr};
  } else {
    carp "Method [$attr] not found in the class [$class]!\n Called from $pack at line $line";
  }
}

sub DESTROY {
  my $self = shift;
}

1;
