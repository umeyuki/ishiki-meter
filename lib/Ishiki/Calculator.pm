package Ishiki::Calculator;
use strict;
use warnings;
use Carp;
use URI;
use LWP::UserAgent;
use XML::Simple;
use Encode;
use utf8;
use YAML::Tiny::Color;

our $VERSION = '0.01';


sub new {
    my ( $class , %args ) = @_;
    my $self = {
        ua       => LWP::UserAgent->new,
        keywords => $args{keywords},
        config   => do '../../config.pl'
    };
    return bless $self,$class;
}

sub calc {
    my ( $self,$sentenses,$keywords ) = @_;

    my $ishiki = 0;
    my @processeds = ();
    my %populars = ();
    my %used = ();
    for my $sentense ( @$sentenses ){
        for my $keyword ( keys %{$keywords} ) {
            if ( $sentense =~ /$keyword/i ) {
                my $id    = $keywords->{$keyword}->{id};
                my $value = $keywords->{$keyword}->{value};
                $used{$keyword} = $value;
                $populars{$id}++;
                $ishiki += $value;
            }
        }
    }
    return $ishiki,\%used,\%populars;
}

1;
