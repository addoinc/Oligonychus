package AzParser::ParsePogo;

use strict;
use warnings;

our $VERSION = '0.01';

use base qw(Exporter);

use Date::Handler;
use Date::Handler::Delta;

sub new {
  my $type = shift;
  my %param = @_;
  $param{'args'} ||= [];

  my $self = new HTML::Parser;
  $self->{'pogoparser_flag'} = 0;
  $self->{'pogoparser_tag'} = '';
  open(SCHED_FH, ">$param{'schedules_csv'}");
  $self->{'SCHED_FH'} = *SCHED_FH{IO};
  $param{'args'}->[0] ||= 'HBO';
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
  $self->{'pogoparser_flag'} ||= 0;
  $attr->{'class'} ||= '';
  $attr->{'bgcolor'} ||='';

  if ( $tag eq 'tr' && $attr->{'bgcolor'} eq '#993333' ) {
    $self->{'pogoparser_flag'} = 1;
    return;
  }

  if( $self->{'pogoparser_flag'} == 1 && $tag eq 'span' && $attr->{'class'} eq 'timetext' ) {
    $self->{'pogoparser_tag'} = 'time';
    $self->{'csv_line'} = '';
    return;
  }

  if( $self->{'pogoparser_flag'} == 1 && $tag eq 'span' && $attr->{'class'} eq 'showcell' ) {
    $self->{'pogoparser_tag'} = 'title';
    $self->{'pogoparser_flag'} = 2;
  }


};

sub end {
  my($self,$tag,$origtext) = @_;

  if ( $self->{'pogoparser_flag'} == 1 && $tag eq 'span' && $self->{'pogoparser_tag'} eq 'time' ) {
    $self->{'pogoparser_tag'} = '/time';
    print {$self->{'SCHED_FH'}} $self->{'date'}, ',', $self->{'csv_line'};
  }
  if ( $self->{'pogoparser_flag'} == 2 && $tag eq 'span' && $self->{'pogoparser_tag'} eq 'title') {
    $self->{'pogoparser_tag'} ='/title';
  }
};


sub text {
  my($self, $text) = @_;
  $self->{'pogoparser_flag'} ||= 0;
  $self->{'pogoparser_tag'} ||= '';
  $text =~ s/\^s+//g; $text =~ s/\s+$//g;

  if( $self->{'pogoparser_flag'} == 1 ) {
    if ( $self->{'pogoparser_tag'} eq 'time' ) {
      print $text."\n";
      $self->{'csv_line'} .= "$text ";
      return;

    } elsif ( $self->{'pogoparser_tag'} eq '/time' ) {
      $self->{'csv_line'} =~ s/\s+$//g;
      $self->{'csv_line'} .= ",";
      $self->{'pogoparser_tag'} = '';
      return;
    }
  } elsif ( $self->{'pogoparser_flag'} == 2 ) {
    if ( $self->{'pogoparser_tag'} eq 'title' ) {
      $text =~ s/,/\\,/g;
      print $text."\n";
      $self->{'csv_line'} .= "$text ";
      return;
    } elsif ( $self->{'pogoparser_tag'} eq '/title' ) {
      $self->{'csv_line'} =~ s/\s+$//g;
      #append record seperator, newline in our case
      $self->{'csv_line'} .= "\n";
      print {$self->{'SCHED_FH'}} "$self->{'csv_line'}";
      $self->{'csv_line'} =~ s/([^,]+,).+/$1/g;
      $self->{'csv_line'} =~ s/\s+$//g;
      $self->{'pogoparser_tag'} = '';
      return;
    }
  }
};

1;
