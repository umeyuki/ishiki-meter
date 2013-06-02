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
        keywords => $args{keywords}
    };
    return bless $self,$class;
}

sub calc {
    my ( $self,$sentenses,$keywords ) = @_;

    my $ishiki = 0;
    my @processeds = ();
    for my $sentense ( @$sentenses ){
        for my $keyword ( keys %{$keywords} ) {
            if ( $sentense =~ /$keyword/ ) {
                my $value = $keywords->{$keyword};
                $ishiki += $value;
                
                my $font_size = $value * 20;
                $sentense =~ s|$keyword|<span style=\"font-size:${font_size}px;color:red\">$keyword</span>|;
            }
        }
        push @processeds, $sentense;        
    }
    return $ishiki,\@processeds;
}

1;
